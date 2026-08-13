/*----------------------------------------------------------
 *
 *        foreign-data wrapper for ODBC
 *
 * Copyright (c) 2011, PostgreSQL Global Development Group
 * Copyright (c) 2026, Softinent
 *
 * This software is released under the PostgreSQL Licence.
 *
 * Author: Zheng Yang <zhengyang4k@gmail.com>
 * Updated to 9.2+ by Gunnar "Nick" Bluth <nick@pro-open.de>
 *   based on tds_fdw code from Geoff Montee
 *
 * IDENTIFICATION
 *      odbc_fdw/odbc_fdw.c
 *
 *----------------------------------------------------------
 */

/* Debug mode flag */
/* #define DEBUG */

#include "postgres.h"
#include <string.h>

#include "funcapi.h"
#include "access/reloptions.h"
#include "catalog/pg_foreign_server.h"
#include "catalog/pg_foreign_table.h"
#include "catalog/pg_user_mapping.h"
#include "catalog/pg_type.h"
#include "commands/defrem.h"
#include "commands/explain.h"
#if PG_VERSION_NUM >= 180000
#include "commands/explain_format.h"
#include "commands/explain_state.h"
#endif
#include "foreign/fdwapi.h"
#include "foreign/foreign.h"
#include "utils/memutils.h"
#include "utils/builtins.h"
#include "utils/relcache.h"
#include "storage/lock.h"
#include "miscadmin.h"
#include "mb/pg_wchar.h"
#include "optimizer/cost.h"
#include "storage/fd.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/rel.h"
#include "nodes/nodes.h"
#include "nodes/makefuncs.h"
#include "nodes/pg_list.h"

#include "optimizer/pathnode.h"
#include "optimizer/restrictinfo.h"
#include "optimizer/planmain.h"

#include "access/tupdesc.h"

#if PG_VERSION_NUM < 120000
#include "access/heapam.h"
#define table_open heap_open
#define table_close heap_close
#else
#include "access/table.h"
#endif

#if defined(_WIN32)
#define strcasecmp _stricmp
#endif

/* TupleDescAttr was backported into 9.5.9 and 9.6.5 but we support any 9.5.X.
 * On PG18+, TupleDescAttr is a real (non-macro) inline function and
 * TupleDescData no longer has an "attrs" member, so #ifndef TupleDescAttr
 * is not a safe guard any more - gate on PG_VERSION_NUM instead. */
#if PG_VERSION_NUM < 90605
#ifndef TupleDescAttr
#define TupleDescAttr(tupdesc, i) ((tupdesc)->attrs[(i)])
#endif
#endif

#include "executor/spi.h"

#include <stdio.h>
#include <sql.h>
#include <sqlext.h>

PG_MODULE_MAGIC;

/* Macro to make conditional DEBUG more terse */
#ifdef DEBUG
#define elog_debug(...) elog(DEBUG1, __VA_ARGS__)
#else
#define elog_debug(...) ((void) 0)
#endif

#define PROCID_TEXTEQ 67
#define PROCID_TEXTCONST 25

/* Provisional limit to name lengths in characters */
#define MAXIMUM_CATALOG_NAME_LEN 255
#define MAXIMUM_SCHEMA_NAME_LEN 255
#define MAXIMUM_TABLE_NAME_LEN 255
#define MAXIMUM_COLUMN_NAME_LEN 255

/* Maximum GetData buffer size */
#define MAXIMUM_BUFFER_SIZE 8192

/*
 * Numbers of the columns returned by SQLTables:
 * 1: TABLE_CAT (ODBC 3.0) TABLE_QUALIFIER (ODBC 2.0) -- database name
 * 2: TABLE_SCHEM (ODBC 3.0) TABLE_OWNER (ODBC 2.0)   -- schema name
 * 3: TABLE_NAME
 * 4: TABLE_TYPE
 * 5: REMARKS
 */
#define SQLTABLES_SCHEMA_COLUMN 2
#define SQLTABLES_NAME_COLUMN 3

#define ODBC_SQLSTATE_FRACTIONAL_TRUNCATION "01S07"
#define ODBC_SQLSTATE_STRING_TRUNCATION "01004"
#define ODBC_SQLSTATE_BQ_TRUNCATION "01000"
#define ODBC_SQLSTATE_LENGTH 5
typedef enum { NO_TRUNCATION, FRACTIONAL_TRUNCATION, STRING_TRUNCATION } GetDataTruncation;

typedef struct odbcFdwOptions
{
	char  *schema;     /* Foreign schema name */
	char  *table;      /* Foreign table */
	char  *prefix;     /* Prefix for imported foreign table names */
	char  *sql_query;  /* SQL query (overrides table) */
	char  *sql_count;  /* SQL query for counting results */
	char  *encoding;   /* Character encoding name */

	/*
	 * Resource ceilings. 0 means unlimited, which is the default, so a server
	 * or table that sets neither behaves exactly as before.
	 *
	 * These are NOT named with an odbc_ prefix on purpose: any option so
	 * prefixed is passed straight through to the ODBC connection string as a
	 * driver attribute (see is_odbc_attribute), so an odbc_-prefixed name here
	 * would be handed to the driver instead of being read by this extension.
	 */
	int64 max_field_size;  /* refuse a single field value larger than this, bytes */
	int64 max_row_count;   /* refuse a scan that returns more rows than this */
	int64 max_result_size; /* refuse a scan retrieving more than this in total, bytes */

	List *connection_list; /* ODBC connection attributes */

	List  *mapping_list; /* Column name mapping */
} odbcFdwOptions;

typedef struct odbcFdwExecutionState
{
	AttInMetadata   *attinmeta;
	odbcFdwOptions  options;
	SQLHENV         env;
	SQLHDBC         dbc;
	SQLHSTMT        stmt;
	int             num_of_result_cols;
	int             num_of_table_cols;
	StringInfoData  *table_columns;
	bool            first_iteration;
	int64           row_count;   /* rows returned so far, for max_row_count */
	int64           result_bytes; /* field bytes retrieved so far, for max_result_size */
	/*
	 * The remote query text, kept so that ReScanForeignScan can re-execute it.
	 * It is the StringInfo odbcBeginForeignScan built, which was allocated in
	 * the same memory context as this struct and therefore has the same
	 * lifetime; no copy is needed. Safe to re-execute verbatim because nothing
	 * in it varies per rescan -- odbcGetQual pushes down only Var = Const, so
	 * a parameterised qual is never baked into this string.
	 */
	char            *query;
	List            *col_position_mask;
	List            *col_size_array;
	List            *col_conversion_array;
	char            *sql_count;
	int             encoding;
} odbcFdwExecutionState;

struct odbcFdwOption
{
	const char   *optname;
	Oid     optcontext; /* Oid of catalog in which option may appear */
};

/*
 * Array of valid options
 * In addition to this, any option with a name prefixed
 * by odbc_ is accepted as an ODBC connection attribute
 * and can be defined in foreign servier, user mapping or
 * table statements.
 * Note that dsn and driver can be defined by
 * prefixed or non-prefixed options.
 */
static struct odbcFdwOption valid_options[] =
{
	/* Foreign server options */
	{ "dsn",        ForeignServerRelationId },
	{ "driver",     ForeignServerRelationId },
	{ "encoding",   ForeignServerRelationId },

	/* Foreign table options */
	{ "schema",     ForeignTableRelationId },
	{ "table",      ForeignTableRelationId },
	{ "prefix",     ForeignTableRelationId },
	{ "sql_query",  ForeignTableRelationId },
	{ "sql_count",  ForeignTableRelationId },

	/*
	 * Resource ceilings, valid on a server and on a table. Listed for both
	 * contexts so the errhint the validator builds names them in both, and so
	 * extract_odbcFdwOptions can claim them before the column-mapping
	 * fallthrough -- a table option this table did not list would otherwise be
	 * taken for the name of a remote column.
	 */
	{ "max_field_size",  ForeignServerRelationId },
	{ "max_field_size",  ForeignTableRelationId },
	{ "max_row_count",   ForeignServerRelationId },
	{ "max_row_count",   ForeignTableRelationId },
	{ "max_result_size", ForeignServerRelationId },
	{ "max_result_size", ForeignTableRelationId },

	/* Sentinel */
	{ NULL,       InvalidOid}
};

typedef enum { TEXT_CONVERSION, BIN_CONVERSION, BOOL_CONVERSION } ColumnConversion;

static GetDataTruncation
result_truncation(SQLRETURN ret, SQLHSTMT stmt)
{
	SQLCHAR sqlstate[ODBC_SQLSTATE_LENGTH + 1];
	GetDataTruncation truncation = NO_TRUNCATION;
	if (ret == SQL_SUCCESS_WITH_INFO)
	{
		SQLGetDiagRec(SQL_HANDLE_STMT, stmt, 1, sqlstate, NULL, NULL, 0, NULL);
		if (strncmp((char*)sqlstate, ODBC_SQLSTATE_STRING_TRUNCATION, ODBC_SQLSTATE_LENGTH) == 0 || strncmp((char*)sqlstate, ODBC_SQLSTATE_BQ_TRUNCATION, ODBC_SQLSTATE_LENGTH) == 0)
		{
			truncation = STRING_TRUNCATION;
		}
		else if (strncmp((char*)sqlstate, ODBC_SQLSTATE_FRACTIONAL_TRUNCATION, ODBC_SQLSTATE_LENGTH) == 0)
		{
			truncation = FRACTIONAL_TRUNCATION;
		}
	}
	return truncation;
}

/*
 * Enforce max_result_size: the total field bytes one scan may retrieve.
 *
 * max_field_size bounds ONE value and max_row_count bounds the number of rows,
 * and a result set can sit comfortably inside both while being unbounded in
 * aggregate -- 200 columns of 1KB across 10,000,000 rows violates neither. This
 * is the ceiling on the product.
 *
 * done_bytes is what completed fields have already cost, field_bytes is the
 * current field, and the comparison is written as a SUBTRACTION rather than as
 * `done + field > max` deliberately: max_result_size is any non-negative int64
 * an operator cares to type, and the invariant this function maintains is
 * done_bytes <= max_result_size, so `max - done` is non-negative and the sum on
 * the other side of the inequality is the one that could overflow.
 *
 * Called from two places for the same reason max_field_size is: once inside the
 * chunk loop, where field_bytes is what has been assembled so far, so a runaway
 * scan is refused while its last field is still being read rather than after;
 * and once when a field's real length is known, which is the exact test. The
 * message is the same in both, and says "at least", because in the first case
 * the amount is a lower bound.
 */
static void
check_result_size(int64 max_result_size, int64 done_bytes, int field_bytes)
{
	if (max_result_size > 0 && (int64) field_bytes > max_result_size - done_bytes)
		ereport(ERROR,
		        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
		         errmsg("odbc_fdw: scan has retrieved at least " INT64_FORMAT " bytes, exceeding max_result_size of " INT64_FORMAT,
		                done_bytes + (int64) field_bytes, max_result_size),
		         errhint("Raise or remove the \"max_result_size\" option on the foreign table or server.")));
}

/*
 * used_size + chunk_size, refusing any extent that cannot be a valid buffer.
 *
 * The addition itself is the hazard. used_buffer_size and chunk_size are both
 * int, and chunk_size is recomputed from a driver-supplied SQLLEN on every
 * truncation, so a sufficiently large or simply wrong value made the sum wrap
 * NEGATIVE. resize_buffer then compared a negative required_size against the
 * current size, found nothing to do, and returned without growing anything --
 * after which SQLGetData was handed `buffer + used_buffer_size` and told it
 * had chunk_size bytes to write into an allocation that had never been
 * extended. That is a heap overflow reached from a value the remote controls.
 *
 * Checked rather than clamped on purpose: a wrapped extent means the length
 * arithmetic has already gone wrong, and silently reading a different amount
 * than the driver was asked for would turn a detectable fault into a wrong
 * answer. See also MAXIMUM_FIELD_EXTENT below for the ceiling on the result.
 */
static int
checked_buffer_extent(int used_size, int chunk_size)
{
	if (chunk_size <= 0)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("odbc_fdw: invalid read chunk size %d", chunk_size),
		         errdetail("The ODBC driver reported a length that produced a non-positive chunk size.")));
	if (used_size < 0)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("odbc_fdw: invalid accumulated field size %d", used_size)));
	if (used_size > PG_INT32_MAX - chunk_size)
		ereport(ERROR,
		        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
		         errmsg("odbc_fdw: field value too large to buffer"),
		         errdetail("Reading %d more bytes onto %d already buffered would overflow the buffer extent.",
		                   chunk_size, used_size)));
	return used_size + chunk_size;
}

static void
resize_buffer(char ** buffer, int *size, int used_size, int required_size)
{
	/*
	 * Refuse impossible geometry instead of allocating from it. Every caller
	 * computes required_size from a driver-reported length, and this function
	 * used to trust it completely: a required_size <= 0 silently did nothing
	 * (leaving the caller to write into a buffer it believed had been grown),
	 * and a used_size larger than required_size would memmove more bytes than
	 * the new allocation can hold.
	 */
	if (used_size < 0 || required_size <= 0 || used_size > required_size)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("odbc_fdw: invalid buffer geometry"),
		         errdetail("used_size=%d required_size=%d", used_size, required_size)));

	if (required_size > *size)
	{
		int new_size = required_size; // TODO: use min increment size, maybe in relation to current size
		char * new_buffer = (char *) palloc(new_size);
		// TODO: out of memory error if !new_buffer
		if (used_size > 0)
		{
			memmove(new_buffer, *buffer, used_size);
			pfree(*buffer);
		}
		*buffer = new_buffer;
		*size = new_size;
	}
}

static const char * HEX_DIGITS = "0123456789ABCDEF";

static char * binary_to_hex(char * buffer, int buffer_size)
{
	int i;
	int hex_size;
	char * hex;

	/*
	 * buffer_size*2 is an int multiplication on a length that came from the
	 * driver, so anything above INT_MAX/2 wrapped negative and palloc was
	 * called with a negative size. Refused rather than clamped: half a value
	 * is not a value.
	 */
	if (buffer_size < 0 || buffer_size > (PG_INT32_MAX - 1) / 2)
		ereport(ERROR,
		        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
		         errmsg("odbc_fdw: binary value of %d bytes is too large to hex-encode", buffer_size)));

	hex_size = buffer_size*2;
	hex = (char *) palloc(hex_size + 1);
	hex[hex_size] = 0;
	for (i=0; i<buffer_size; i++)
	{
		unsigned char byte = buffer[i];
		hex[i*2] = HEX_DIGITS[(byte >> 4)];
		hex[i*2+1] = HEX_DIGITS[(byte & 0xF)];
	}
	return hex;
}

/*
 * SQL functions
 */
PGDLLEXPORT Datum odbc_fdw_handler(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum odbc_fdw_validator(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum odbc_tables_list(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum odbc_table_size(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum odbc_query_size(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(odbc_fdw_handler);
PG_FUNCTION_INFO_V1(odbc_fdw_validator);
PG_FUNCTION_INFO_V1(odbc_tables_list);
PG_FUNCTION_INFO_V1(odbc_table_size);
PG_FUNCTION_INFO_V1(odbc_query_size);

/*
 * FDW callback routines
 */
static void odbcExplainForeignScan(ForeignScanState *node, ExplainState *es);
static void odbcBeginForeignScan(ForeignScanState *node, int eflags);
static TupleTableSlot *odbcIterateForeignScan(ForeignScanState *node);
static void odbcReScanForeignScan(ForeignScanState *node);
static void odbcEndForeignScan(ForeignScanState *node);
static void odbcGetForeignRelSize(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid);
static void odbcEstimateCosts(PlannerInfo *root, RelOptInfo *baserel, Cost *startup_cost, Cost *total_cost, Oid foreigntableid);
static void odbcGetForeignPaths(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid);
static bool odbcAnalyzeForeignTable(Relation relation, AcquireSampleRowsFunc *func, BlockNumber *totalpages);
static ForeignScan* odbcGetForeignPlan(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid, ForeignPath *best_path, List *tlist, List *scan_clauses, Plan *outer_plan);
List* odbcImportForeignSchema(ImportForeignSchemaStmt *stmt, Oid serverOid);

/*
 * helper functions
 */
static bool odbcIsValidOption(const char *option, Oid context);
static void check_return(SQLRETURN ret, char *msg, SQLHANDLE handle, SQLSMALLINT type);
static const char* empty_string_if_null(char *string);
static void extract_odbcFdwOptions(List *options_list, odbcFdwOptions *extracted_options);
static void init_odbcFdwOptions(odbcFdwOptions* options);
static void copy_odbcFdwOptions(odbcFdwOptions* to, odbcFdwOptions* from);
static void odbc_connection(odbcFdwOptions* options, SQLHENV *env, SQLHDBC *dbc);
static void odbc_disconnection(SQLHENV *env, SQLHDBC *dbc);
static void sql_data_type(SQLSMALLINT odbc_data_type, SQLULEN column_size, SQLSMALLINT decimal_digits, SQLSMALLINT nullable, StringInfo sql_type);
static void odbcGetOptions(Oid server_oid, List *add_options, odbcFdwOptions *extracted_options);
static void odbcGetTableOptions(Oid foreigntableid, odbcFdwOptions *extracted_options);
static void odbcGetTableSize(odbcFdwOptions* options, unsigned int *size);
static void check_return(SQLRETURN ret, char *msg, SQLHANDLE handle, SQLSMALLINT type);
static void odbcConnStr(StringInfoData *conn_str, odbcFdwOptions* options);
static char* get_schema_name(odbcFdwOptions *options);
static inline bool is_blank_string(const char *s);
static Oid oid_from_server_name(char *serverName);
static char *escape_sql_literal(const char *value);
static char *escape_sql_identifier_part(const char *value, const char *quote_char);

/*
 * Check if string pointer is NULL or points to empty string
 */
static inline bool is_blank_string(const char *s)
{
	return s == NULL || s[0] == '\0';
}

/*
 * Escape a value for safe use inside a single-quoted SQL string literal,
 * by doubling every embedded single-quote character (the standard SQL
 * escaping rule, e.g. "O'Brien" -> "O''Brien"). Returns a freshly palloc'd,
 * NUL-terminated string; safe to call with value == NULL (returns "").
 *
 * This must be used for every value that gets interpolated into a SQL
 * string sent to the remote ODBC data source, to avoid SQL injection.
 */
static char *
escape_sql_literal(const char *value)
{
	StringInfoData buf;
	const char *p;

	initStringInfo(&buf);
	if (value == NULL)
		return buf.data;

	for (p = value; *p; p++)
	{
		if (*p == '\'')
			appendStringInfoChar(&buf, '\'');
		appendStringInfoChar(&buf, *p);
	}
	return buf.data;
}

/*
 * Escape a value for safe use as (part of) a quoted SQL identifier, by
 * doubling every embedded occurrence of the driver-reported quote
 * character (e.g. with quote_char='"', "foo""bar" -> "foo""""bar").
 * quote_char is expected to be a single character (as returned by
 * getQuoteChar()/getNameQualifierChar()); if it's blank, value is
 * returned unescaped since there's no quoting to break out of. Returns a
 * freshly palloc'd, NUL-terminated string; safe to call with value == NULL
 * (returns "").
 *
 * This must be used for every table/schema/column name that gets
 * interpolated into a SQL string sent to the remote ODBC data source, to
 * avoid identifier-injection turning into arbitrary SQL injection.
 */
static char *
escape_sql_identifier_part(const char *value, const char *quote_char)
{
	StringInfoData buf;
	const char *p;
	char qc;

	initStringInfo(&buf);
	if (value == NULL)
		return buf.data;

	qc = (quote_char != NULL && quote_char[0] != '\0') ? quote_char[0] : '\0';

	for (p = value; *p; p++)
	{
		if (qc != '\0' && *p == qc)
			appendStringInfoChar(&buf, qc);
		appendStringInfoChar(&buf, *p);
	}
	return buf.data;
}

Datum
odbc_fdw_handler(PG_FUNCTION_ARGS)
{
	FdwRoutine *fdwroutine = makeNode(FdwRoutine);
	/* FIXME */
	fdwroutine->GetForeignRelSize = odbcGetForeignRelSize;
	fdwroutine->GetForeignPaths = odbcGetForeignPaths;
	fdwroutine->AnalyzeForeignTable = odbcAnalyzeForeignTable;
	fdwroutine->GetForeignPlan = odbcGetForeignPlan;
	fdwroutine->ExplainForeignScan = odbcExplainForeignScan;
	fdwroutine->BeginForeignScan = odbcBeginForeignScan;
	fdwroutine->IterateForeignScan = odbcIterateForeignScan;
	fdwroutine->ReScanForeignScan = odbcReScanForeignScan;
	fdwroutine->EndForeignScan = odbcEndForeignScan;
	fdwroutine->ImportForeignSchema = odbcImportForeignSchema;
	PG_RETURN_POINTER(fdwroutine);
}

static void
init_odbcFdwOptions(odbcFdwOptions* options)
{
	memset(options, 0, sizeof(odbcFdwOptions));
}

static void
copy_odbcFdwOptions(odbcFdwOptions* to, odbcFdwOptions* from)
{
	if (to && from)
	{
		*to = *from;
	}
}

/*
 * Avoid NULL string: return original string, or empty string if NULL
 */
static const char*
empty_string_if_null(char *string)
{
	static const char* empty_string = "";
	return string == NULL ? empty_string : string;
}

static const char   odbc_attribute_prefix[] = "odbc_";
static const size_t odbc_attribute_prefix_len = sizeof(odbc_attribute_prefix) - 1; /*  strlen(odbc_attribute_prefix); */

static bool
is_odbc_attribute(const char* defname)
{
	return (strlen(defname) > odbc_attribute_prefix_len && strncmp(defname, odbc_attribute_prefix, odbc_attribute_prefix_len) == 0);
}

/* These ODBC attributes names are always uppercase */
static const char *normalized_attributes[] = { "DRIVER", "DSN", "UID", "PWD" };
static const char *normalized_attribute(const char* attribute_name)
{
	size_t i;
	for (i=0; i < sizeof(normalized_attributes)/sizeof(normalized_attributes[0]); i++)
	{
		if (strcasecmp(attribute_name, normalized_attributes[i])==0)
		{
			attribute_name = normalized_attributes[i];
			break;
		}
	}
	return 	attribute_name;
}

static const char*
get_odbc_attribute_name(const char* defname)
{
	int offset = is_odbc_attribute(defname) ? odbc_attribute_prefix_len : 0;
	return normalized_attribute(defname + offset);
}

/*
 * Read a resource ceiling and fold it into whatever ceiling is already in
 * force, TIGHTEST WINS.
 *
 * Deliberately not last-wins, which is what odbcGetOptions' list order would
 * otherwise give. That order is table options, then server options, then user
 * mapping options, so the last assignment is the SERVER's -- meaning a plain
 * assignment here would let a server value override a table value, or, with the
 * lists in any other order, let a table raise a ceiling an operator set on the
 * server. For a limit whose purpose is to bound a pathological remote, neither
 * is acceptable: a ceiling that can be raised from the object it constrains is
 * not a ceiling. Folding to the minimum also makes the result independent of
 * that order, so it cannot change if upstream reorders the concatenation.
 *
 * 0 means unlimited and therefore loses to any positive value; it can never
 * loosen a ceiling already set.
 */
static void
apply_limit_option(DefElem *def, int64 *limit)
{
	char   *value = defGetString(def);
	char   *endptr;
	int64   parsed;

	errno = 0;
	parsed = strtoll(value, &endptr, 10);
	if (errno != 0 || endptr == value || *endptr != '\0' || parsed < 0)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_INVALID_ATTRIBUTE_VALUE),
		         errmsg("option \"%s\" requires a non-negative integer, got \"%s\"",
		                def->defname, value),
		         errhint("0 means unlimited, which is the default.")));

	if (parsed > 0 && (*limit == 0 || parsed < *limit))
		*limit = parsed;
}

static void
extract_odbcFdwOptions(List *options_list, odbcFdwOptions *extracted_options)
{
	ListCell        *lc;

	elog_debug("%s", __func__);

	init_odbcFdwOptions(extracted_options);

	/* Loop through the options, and get the foreign table options */
	foreach(lc, options_list)
	{
		DefElem *def = (DefElem *) lfirst(lc);

		if (strcmp(def->defname, "dsn") == 0)
		{
			extracted_options->connection_list = lappend(extracted_options->connection_list, def);
			continue;
		}

		if (strcmp(def->defname, "driver") == 0)
		{
			extracted_options->connection_list = lappend(extracted_options->connection_list, def);
			continue;
		}

		if (strcmp(def->defname, "schema") == 0)
		{
			extracted_options->schema = defGetString(def);
			continue;
		}

		if (strcmp(def->defname, "table") == 0)
		{
			extracted_options->table = defGetString(def);
			continue;
		}

		if (strcmp(def->defname, "prefix") == 0)
		{
			extracted_options->prefix = defGetString(def);
			continue;
		}

		if (strcmp(def->defname, "sql_query") == 0)
		{
			extracted_options->sql_query = defGetString(def);
			continue;
		}

		if (strcmp(def->defname, "sql_count") == 0)
		{
			extracted_options->sql_count = defGetString(def);
			continue;
		}

		if (strcmp(def->defname, "encoding") == 0)
		{
			extracted_options->encoding = defGetString(def);
			continue;
		}

		if (strcmp(def->defname, "max_field_size") == 0)
		{
			apply_limit_option(def, &extracted_options->max_field_size);
			continue;
		}

		if (strcmp(def->defname, "max_row_count") == 0)
		{
			apply_limit_option(def, &extracted_options->max_row_count);
			continue;
		}

		if (strcmp(def->defname, "max_result_size") == 0)
		{
			apply_limit_option(def, &extracted_options->max_result_size);
			continue;
		}

		if (is_odbc_attribute(def->defname))
		{
			extracted_options->connection_list = lappend(extracted_options->connection_list, def);
			continue;
		}

		/* Column mapping goes here */
		/* TODO: is this useful? if so, how can columns names coincident
		   with option names be escaped? */
		extracted_options->mapping_list = lappend(extracted_options->mapping_list, def);
	}
}

/*
 * Get the schema name from the options
 */
static char* get_schema_name(odbcFdwOptions *options)
{
	return options->schema;
}

/*
 * Establish ODBC connection
 */
static void
odbc_connection(odbcFdwOptions* options, SQLHENV *env, SQLHDBC *dbc)
{
	StringInfoData  conn_str;
	SQLCHAR OutConnStr[1024];
	SQLSMALLINT OutConnStrLen;
	SQLRETURN ret;

	odbcConnStr(&conn_str, options);

	/* Allocate an environment handle */
	SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, env);
	/* We want ODBC 3 support */
	SQLSetEnvAttr(*env, SQL_ATTR_ODBC_VERSION, (void *) SQL_OV_ODBC3, 0);

	/* Allocate a connection handle */
	SQLAllocHandle(SQL_HANDLE_DBC, *env, dbc);
	/* Connect to the DSN */
	ret = SQLDriverConnect(*dbc, NULL, (SQLCHAR *) conn_str.data, SQL_NTS,
	                       OutConnStr, 1024, &OutConnStrLen, SQL_DRIVER_COMPLETE);
	check_return(ret, "Connecting to driver", dbc, SQL_HANDLE_DBC);
	elog_debug("Connection opened");
}

/*
 * Close the ODBC connection
 */
static void
odbc_disconnection(SQLHENV *env, SQLHDBC *dbc)
{
	SQLRETURN ret;

	if (*dbc)
	{
		ret = SQLDisconnect(*dbc);
		check_return(ret, "dbc disconnect", *dbc, SQL_HANDLE_DBC);
		ret = SQLFreeHandle(SQL_HANDLE_DBC, *dbc);
		check_return(ret, "dbc free handle", *dbc, SQL_HANDLE_DBC);
		if (*env)
		{
			ret = SQLFreeHandle(SQL_HANDLE_ENV, *env);
			check_return(ret, "env free handle", *env, SQL_HANDLE_ENV);
		}
	}
	elog_debug("Connection closed");
}

/*
 * Validate function
 */
Datum
odbc_fdw_validator(PG_FUNCTION_ARGS)
{
	List  *options_list = untransformRelOptions(PG_GETARG_DATUM(0));
	Oid   catalog = PG_GETARG_OID(1);
	char  *svr_schema   = NULL;
	char  *svr_table    = NULL;
	char  *svr_prefix   = NULL;
	char  *sql_query    = NULL;
	char  *sql_count    = NULL;
	ListCell *cell;

	elog_debug("%s", __func__);

	/*
	 * Check that the necessary options: address, port, database
	 */
	foreach(cell, options_list)
	{
		DefElem    *def = (DefElem *) lfirst(cell);

		/* Complain invalid options */
		if (!odbcIsValidOption(def->defname, catalog))
		{
			struct odbcFdwOption *opt;
			StringInfoData buf;

			/*
			 * Unknown option specified, complain about it. Provide a hint
			 * with list of valid options for the object.
			 */
			initStringInfo(&buf);
			for (opt = valid_options; opt->optname; opt++)
			{
				if (catalog == opt->optcontext)
					appendStringInfo(&buf, "%s%s", (buf.len > 0) ? ", " : "",
					                 opt->optname);
			}

			ereport(ERROR,
			        (errcode(ERRCODE_FDW_INVALID_OPTION_NAME),
			         errmsg("invalid option \"%s\"", def->defname),
			         errhint("Valid options in this context are: %s", buf.len ? buf.data : "<none>")
			        ));
		}

		/*
		 * The ODBC driver manager dlopen()s whatever shared library is
		 * named by the "driver" attribute (and "dsn" indirectly selects
		 * one via odbc.ini) - allowing an arbitrary value here is
		 * equivalent to allowing an arbitrary shared library to be loaded
		 * into the backend process. Restrict these two server-level
		 * options to superusers, the same way core PostgreSQL restricts
		 * comparably powerful FDW options (e.g. file_fdw's "filename").
		 */
		if (catalog == ForeignServerRelationId &&
		    (strcmp(def->defname, "driver") == 0 || strcmp(def->defname, "dsn") == 0) &&
		    !superuser())
		{
			ereport(ERROR,
			        (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
			         errmsg("only superusers can set the \"%s\" option of an odbc_fdw server",
			                def->defname)));
		}

		/*
		 * Validate the VALUE of a resource ceiling here, at DDL time.
		 *
		 * The rest of this validator checks option NAMES only, and the ceilings
		 * are otherwise parsed in extract_odbcFdwOptions, which runs when a
		 * scan starts. That was measured to accept `max_row_count 'lots'`,
		 * `max_field_size '-1'` and `max_field_size '100MB'` at CREATE FOREIGN
		 * TABLE and CREATE SERVER, deferring the complaint to the first query --
		 * so the DDL that contained the mistake reported success and something
		 * unrelated failed later. A ceiling nobody can tell they set wrongly is
		 * worse than no ceiling.
		 *
		 * The sink is per option and discarded: only the parse and the range
		 * matter here, not the tightest-wins folding that extraction performs.
		 */
		if (strcmp(def->defname, "max_field_size") == 0 ||
		    strcmp(def->defname, "max_row_count") == 0 ||
		    strcmp(def->defname, "max_result_size") == 0)
		{
			int64 sink = 0;
			apply_limit_option(def, &sink);
		}

		/* TODO: detect redundant connection attributes and missing required attributs (dsn or driver)
		 * Complain about redundent options
		 */
		if (strcmp(def->defname, "schema") == 0)
		{
			if (!is_blank_string(svr_schema))
				ereport(ERROR,
				        (errcode(ERRCODE_SYNTAX_ERROR),
				         errmsg("conflicting or redundant options: schema (%s)", defGetString(def))
				        ));

			svr_schema = defGetString(def);
		}
		else if (strcmp(def->defname, "table") == 0)
		{
			if (!is_blank_string(svr_table))
				ereport(ERROR,
				        (errcode(ERRCODE_SYNTAX_ERROR),
				         errmsg("conflicting or redundant options: table (%s)", defGetString(def))
				        ));

			svr_table = defGetString(def);
		}
		else if (strcmp(def->defname, "prefix") == 0)
		{
			if (!is_blank_string(svr_prefix))
				ereport(ERROR,
				        (errcode(ERRCODE_SYNTAX_ERROR),
				         errmsg("conflicting or redundant options: prefix (%s)", defGetString(def))
				        ));

			svr_prefix = defGetString(def);
		}
		else if (strcmp(def->defname, "sql_query") == 0)
		{
			if (sql_query)
				ereport(ERROR,
				        (errcode(ERRCODE_SYNTAX_ERROR),
				         errmsg("conflicting or redundant options: sql_query (%s)", defGetString(def))
				        ));

			sql_query = defGetString(def);
		}
		else if (strcmp(def->defname, "sql_count") == 0)
		{
			if (!is_blank_string(sql_count))
				ereport(ERROR,
				        (errcode(ERRCODE_SYNTAX_ERROR),
				         errmsg("conflicting or redundant options: sql_count (%s)", defGetString(def))
				        ));

			sql_count = defGetString(def);
		}
	}

	PG_RETURN_VOID();
}

/*
 * Map ODBC data types to PostgreSQL
 */
static void
sql_data_type(
    SQLSMALLINT odbc_data_type,
    SQLULEN     column_size,
    SQLSMALLINT decimal_digits,
    SQLSMALLINT nullable,
    StringInfo sql_type
)
{
	initStringInfo(sql_type);
	switch(odbc_data_type)
	{
	case SQL_CHAR:
	case SQL_WCHAR :
		appendStringInfo(sql_type, "char(%u)", (unsigned)column_size);
		break;
	case SQL_VARCHAR :
	case SQL_WVARCHAR :
		if (column_size <= 255 && column_size > 0)
		{
			appendStringInfo(sql_type, "varchar(%u)", (unsigned)column_size);
		}
		else
		{
			appendStringInfo(sql_type, "text");
		}
		break;
	case SQL_LONGVARCHAR :
	case SQL_WLONGVARCHAR :
		appendStringInfo(sql_type, "text");
		break;
	case SQL_DECIMAL :
		appendStringInfo(sql_type, "decimal(%u,%d)", (unsigned)column_size, decimal_digits);
		break;
	case SQL_NUMERIC :
		appendStringInfo(sql_type, "numeric(%u,%d)", (unsigned)column_size, decimal_digits);
		break;
	case SQL_INTEGER :
		appendStringInfo(sql_type, "integer");
		break;
	case SQL_REAL :
		appendStringInfo(sql_type, "real");
		break;
	case SQL_FLOAT :
		appendStringInfo(sql_type, "real");
		break;
	case SQL_DOUBLE :
		appendStringInfo(sql_type, "float8");
		break;
	case SQL_BIT :
		/* Use boolean instead of bit(1) because:
		 * * binary types are not yet fully supported
		 * * boolean is more commonly used in PG
		 * * With options BoolsAsChar=0 this allows
		 *   preserving boolean columns from pSQL ODBC.
		 */
		appendStringInfo(sql_type, "boolean");
		break;
	case SQL_SMALLINT :
	case SQL_TINYINT :
		appendStringInfo(sql_type, "smallint");
		break;
	case SQL_BIGINT :
		appendStringInfo(sql_type, "bigint");
		break;
	/*
	 * TODO: Implement these cases properly. See #23
	 *
	case SQL_BINARY :
		appendStringInfo(sql_type, "bit(%u)", (unsigned)column_size);
		break;
	case SQL_VARBINARY :
		appendStringInfo(sql_type, "varbit(%u)", (unsigned)column_size);
		break;
	*/
	case SQL_LONGVARBINARY :
		appendStringInfo(sql_type, "bytea");
		break;
	case SQL_TYPE_DATE :
	case SQL_DATE :
		appendStringInfo(sql_type, "date");
		break;
	case SQL_TYPE_TIME :
	case SQL_TIME :
		appendStringInfo(sql_type, "time");
		break;
	case SQL_TYPE_TIMESTAMP :
	case SQL_TIMESTAMP :
		appendStringInfo(sql_type, "timestamp");
		break;
	case SQL_GUID :
		appendStringInfo(sql_type, "uuid");
		break;
	};
}

static SQLULEN
minimum_buffer_size(SQLSMALLINT odbc_data_type)
{
	switch(odbc_data_type)
	{
	case SQL_DECIMAL :
	case SQL_NUMERIC :
		return 32;
	case SQL_INTEGER :
		return 12;
	case SQL_REAL :
	case SQL_FLOAT :
		return 18;
	case SQL_DOUBLE :
		return 26;
	case SQL_SMALLINT :
	case SQL_TINYINT :
		return 6;
	case SQL_BIGINT :
		return 21;
	case SQL_TYPE_DATE :
	case SQL_DATE :
		return 10;
	case SQL_TYPE_TIME :
	case SQL_TIME :
		return 8;
	case SQL_TYPE_TIMESTAMP :
	case SQL_TIMESTAMP :
		return 20;
	default :
		return 0;
	};
}

/*
 * Fetch the options for a server and options list
 */
static void
odbcGetOptions(Oid server_oid, List *add_options, odbcFdwOptions *extracted_options)
{
	ForeignServer   *server;
	UserMapping     *mapping;
	List            *options;

	elog_debug("%s", __func__);

	server  = GetForeignServer(server_oid);
	mapping = GetUserMapping(GetUserId(), server_oid);

	options = NIL;
	options = list_concat(options, add_options);
	options = list_concat(options, server->options);
	options = list_concat(options, mapping->options);

	extract_odbcFdwOptions(options, extracted_options);
}

/*
 * Fetch the options for a odbc_fdw foreign table.
 */
static void
odbcGetTableOptions(Oid foreigntableid, odbcFdwOptions *extracted_options)
{
	ForeignTable    *table;

	elog_debug("%s", __func__);

	table = GetForeignTable(foreigntableid);
	odbcGetOptions(table->serverid, table->options, extracted_options);
}

#define MAX_ERROR_MSG_LENGTH 512
#define ERROR_MSG_SEP "\n"

static void
check_return(SQLRETURN ret, char *msg, SQLHANDLE handle, SQLSMALLINT type)
{
	SQLINTEGER   i = 0;
	SQLINTEGER   native;
	SQLCHAR  state[ 7 ];
	SQLCHAR  text[256];
	SQLSMALLINT  len;
	SQLRETURN    diag_ret;
	static char error_msg[MAX_ERROR_MSG_LENGTH+1];
	int err_code = ERRCODE_SYSTEM_ERROR;

	strncpy(error_msg, msg, MAX_ERROR_MSG_LENGTH);

	if (!SQL_SUCCEEDED(ret))
	{
		#ifdef DEBUG
		elog(DEBUG1, "Error result (%d): %s", ret, error_msg);
		#endif
		if (handle)
		{
			do
			{
				diag_ret = SQLGetDiagRec(type, handle, ++i, state, &native, text,
				                         sizeof(text), &len );
				if (SQL_SUCCEEDED(diag_ret)) {
					#ifdef DEBUG
					elog(DEBUG1, " %s:%ld:%ld:%s\n", state, (long int) i, (long int) native, text);
					#endif
					strncat(error_msg, ERROR_MSG_SEP, MAX_ERROR_MSG_LENGTH - strlen(ERROR_MSG_SEP));
					strncat(error_msg, (char *)text, MAX_ERROR_MSG_LENGTH - strlen(error_msg));
				}
			}
			while( diag_ret == SQL_SUCCESS );
		}
		ereport(ERROR, (errcode(err_code), errmsg("%s", error_msg)));
	}
}

/*
 * Get name qualifier char
 */
static void
getNameQualifierChar(SQLHDBC dbc, StringInfoData *nq_char)
{
	/*
	 * Zero-initialised: SQLGetInfo leaves this untouched if it fails, and the
	 * blank test below has to be a test of what the driver said rather than of
	 * whatever was on the stack.
	 */
	SQLCHAR name_qualifier_char[2] = {0, 0};

	elog_debug("%s", __func__);

	SQLGetInfo(dbc,
	           SQL_CATALOG_NAME_SEPARATOR,
	           (SQLPOINTER)&name_qualifier_char,
	           2,
	           NULL);
	name_qualifier_char[1] = 0; // some drivers fail to copy the trailing zero

	initStringInfo(nq_char);
	/*
	 * Default a blank separator to ".".
	 *
	 * SQL_CATALOG_NAME_SEPARATOR describes how a CATALOG is joined to the name
	 * that follows it, so a driver for a database with no catalogs may quite
	 * correctly report it as empty -- SAP HANA's namespace is schema-based and
	 * libodbcHDB does exactly that. Every caller here, however, uses this
	 * string to join a SCHEMA to a table. Empty therefore emitted
	 * "SYS""DUMMY", which is ONE identifier containing a doubled (escaped)
	 * quote, resolved against the connecting user's default schema:
	 *   Base table or view not found;259 invalid table name:
	 *   Could not find table/view SYS"DUMMY in schema <CONNECTING USER'S SCHEMA>
	 * Fixing it here rather than at a call site covers both places that build
	 * a qualified name -- odbcGetTableSize and odbcBeginForeignScan -- so the
	 * failure cannot simply move one step later. "." is the only separator SQL
	 * defines between a schema and a table, and a driver that does report one
	 * still gets its own.
	 */
	if (name_qualifier_char[0] == 0)
		appendStringInfoString(nq_char, ".");
	else
		appendStringInfo(nq_char, "%s", (char *) name_qualifier_char);
}

/*
 * Get quote cahr
 */
static void
getQuoteChar(SQLHDBC dbc, StringInfoData *q_char)
{
	SQLCHAR quote_char[2];

	elog_debug("%s", __func__);

	SQLGetInfo(dbc,
	           SQL_IDENTIFIER_QUOTE_CHAR,
	           (SQLPOINTER)&quote_char,
	           2,
	           NULL);
	quote_char[1] = 0; // some drivers fail to copy the trailing zero

	initStringInfo(q_char);
	appendStringInfo(q_char, "%s", (char *) quote_char);
}

static bool appendConnAttribute(bool sep, StringInfoData *conn_str, const char* name, const char* value)
{
	static const char *sep_str = ";";
	if (!is_blank_string(value))
	{
		if (sep)
			appendStringInfoString(conn_str, sep_str);
		appendStringInfo(conn_str, "%s=%s", name, value);
		sep = true;
	}
	return sep;
}

/*
 * Is this ODBC connection attribute name one that typically carries a
 * credential (password, secret/access key, token, etc.)? Used to keep
 * such values out of the debug log - the connection string itself
 * (used for the real SQLDriverConnect() call) is unaffected.
 */
static bool
is_sensitive_connection_attribute(const char *attr_name)
{
	static const char *sensitive_names[] = {
		"pwd", "password", "uid", "user", "accesskey", "secretkey",
		"secret", "token", "apikey", "api_key", NULL
	};
	int i;

	if (attr_name == NULL)
		return false;

	for (i = 0; sensitive_names[i]; i++)
	{
		if (strcasecmp(attr_name, sensitive_names[i]) == 0)
			return true;
	}
	return false;
}

static void odbcConnStr(StringInfoData *conn_str, odbcFdwOptions* options)
{
	bool sep = false;
	bool debug_sep = false;
	ListCell *lc;
	StringInfoData debug_str;

	initStringInfo(conn_str);
	initStringInfo(&debug_str);

	foreach(lc, options->connection_list)
	{
		DefElem *def = (DefElem *) lfirst(lc);
		const char *attr_name = get_odbc_attribute_name(def->defname);
		const char *value = defGetString(def);

		sep = appendConnAttribute(sep, conn_str, attr_name, value);

		/*
		 * Build a separate, redacted copy purely for the debug log, so a
		 * -DDEBUG build never writes credentials to the server log.
		 */
		debug_sep = appendConnAttribute(debug_sep, &debug_str, attr_name,
		                                 is_sensitive_connection_attribute(attr_name) ? "***" : value);
	}
	elog_debug("CONN STR: %s", debug_str.data);
}

/*
 * get table size of a table
 */
static void
odbcGetTableSize(odbcFdwOptions* options, unsigned int *size)
{
	SQLHENV env;
	SQLHDBC dbc;
	SQLHSTMT stmt;
	SQLRETURN ret;

	StringInfoData  sql_str;

	SQLUBIGINT table_size;
	SQLLEN indicator;

	StringInfoData name_qualifier_char;
	StringInfoData quote_char;

	const char* schema_name;

	schema_name = get_schema_name(options);

	odbc_connection(options, &env, &dbc);

	/* Allocate a statement handle */
	SQLAllocHandle(SQL_HANDLE_STMT, dbc, &stmt);

	if (is_blank_string(options->sql_count))
	{
		/* Get quote char */
		getQuoteChar(dbc, &quote_char);

		/* Get name qualifier char */
		getNameQualifierChar(dbc, &name_qualifier_char);

		initStringInfo(&sql_str);
		if (is_blank_string(options->sql_query))
		{
			char *escaped_table = escape_sql_identifier_part(options->table, quote_char.data);

			if (is_blank_string(schema_name))
			{
				appendStringInfo(&sql_str, "SELECT COUNT(*) FROM %s%s%s",
				                 quote_char.data, escaped_table, quote_char.data);
			}
			else
			{
				char *escaped_schema = escape_sql_identifier_part(schema_name, quote_char.data);

				appendStringInfo(&sql_str, "SELECT COUNT(*) FROM %s%s%s%s%s%s%s",
				                 quote_char.data, escaped_schema, quote_char.data,
				                 name_qualifier_char.data,
				                 quote_char.data, escaped_table, quote_char.data);
			}
		}
		else
		{
			if (options->sql_query[strlen(options->sql_query)-1] == ';')
			{
				/* Remove trailing semicolon if present */
				options->sql_query[strlen(options->sql_query)-1] = 0;
			}
			appendStringInfo(&sql_str, "SELECT COUNT(*) FROM (%s) AS _odbc_fwd_count_wrapped", options->sql_query);
		}
	}
	else
	{
		initStringInfo(&sql_str);
		appendStringInfo(&sql_str, "%s", options->sql_count);
	}

	elog_debug("Count query: %s", sql_str.data);

	ret = SQLExecDirect(stmt, (SQLCHAR *) sql_str.data, SQL_NTS);
	check_return(ret, "Executing ODBC query to get table size", stmt, SQL_HANDLE_STMT);
	if (SQL_SUCCEEDED(ret))
	{
		SQLFetch(stmt);
		/* retrieve column data as a big int */
		ret = SQLGetData(stmt, 1, SQL_C_UBIGINT, &table_size, 0, &indicator);
		if (SQL_SUCCEEDED(ret))
		{
			*size = (unsigned int) table_size;
			elog_debug("Count query result: %lu", table_size);
		}
	}
	else
	{
		elog(WARNING, "Error getting the table %s size", options->table);
	}

	/* Free handles, and disconnect */
	if (stmt)
	{
		SQLFreeHandle(SQL_HANDLE_STMT, stmt);
		stmt = NULL;
	}
	odbc_disconnection(&env, &dbc);
}

static int strtoint(const char *nptr, char **endptr, int base)
{
	long val = strtol(nptr, endptr, base);
	return (int) val;
}

static Oid oid_from_server_name(char *serverName)
{
	char *serverOidString;
	char *escaped_name;
	StringInfoData sql;
	int serverOid;
	HeapTuple tuple;
	TupleDesc tupdesc;
	int ret;

	if ((ret = SPI_connect()) < 0) {
		elog(ERROR, "oid_from_server_name: SPI_connect returned %d", ret);
	}

	/*
	 * serverName is an arbitrary, caller-supplied text argument (this
	 * function backs SQL-callable functions such as odbc_tables_list()),
	 * not a bounded identifier - build the query with a StringInfo
	 * (grows as needed, no fixed-size buffer to overflow) and escape it
	 * as a SQL string literal (doubling embedded quotes) to avoid SQL
	 * injection via SPI_execute().
	 */
	escaped_name = escape_sql_literal(serverName);
	initStringInfo(&sql);
	appendStringInfo(&sql, "SELECT oid FROM pg_foreign_server where srvname = '%s'", escaped_name);
	if ((ret = SPI_execute(sql.data, true, 1)) != SPI_OK_SELECT) {
		elog(ERROR, "oid_from_server_name: Get server name from Oid query Failed, SP_exec returned %d.", ret);
	}

	if (SPI_processed > 0 && SPI_tuptable->vals[0] != NULL)
	{
		tupdesc  = SPI_tuptable->tupdesc;
		tuple    = SPI_tuptable->vals[0];

		serverOidString = SPI_getvalue(tuple, tupdesc, 1);
		serverOid = strtoint(serverOidString, NULL, 10);
	} else {
		elog(ERROR, "Foreign server %s doesn't exist", serverName);
	}

	SPI_finish();
	return serverOid;
}

Datum
odbc_table_size(PG_FUNCTION_ARGS)
{
	char *serverName = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char *tableName = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char *defname = "table";
	unsigned int tableSize;
	List *tableOptions = NIL;
	Node *val = (Node *) makeString(tableName);
	Oid serverOid;
	odbcFdwOptions options;
#if PG_VERSION_NUM >= 100000
	DefElem *elem = (DefElem *) makeDefElem(defname, val, -1);
#else
	DefElem *elem = (DefElem *) makeDefElem(defname, val);
#endif

	tableOptions = lappend(tableOptions, elem);
	serverOid = oid_from_server_name(serverName);
	odbcGetOptions(serverOid, tableOptions, &options);
	odbcGetTableSize(&options, &tableSize);

	PG_RETURN_INT32(tableSize);
}

Datum
odbc_query_size(PG_FUNCTION_ARGS)
{
	char *serverName = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char *sqlQuery = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char *defname = "sql_query";
	unsigned int querySize;
	List *queryOptions = NIL;
	Node *val = (Node *) makeString(sqlQuery);
	Oid serverOid;
	odbcFdwOptions options;
#if PG_VERSION_NUM >= 100000
	DefElem *elem = (DefElem *) makeDefElem(defname, val, -1);
#else
	DefElem *elem = (DefElem *) makeDefElem(defname, val);
#endif

	queryOptions = lappend(queryOptions, elem);
	serverOid = oid_from_server_name(serverName);
	odbcGetOptions(serverOid, queryOptions, &options);
	odbcGetTableSize(&options, &querySize);

	PG_RETURN_INT32(querySize);
}

/*
 * Get the list of tables for the current datasource
 */
typedef struct {
	SQLSMALLINT TargetType;
	SQLPOINTER TargetValuePtr;
	SQLINTEGER BufferLength;
	SQLLEN StrLen_or_Ind;
} DataBinding;

typedef struct {
	Oid serverOid;
	DataBinding* tableResult;
	SQLHENV env;
	SQLHDBC dbc;
	SQLHSTMT stmt;
	SQLCHAR schema;
	SQLCHAR name;
	SQLUINTEGER rowLimit;
	SQLUINTEGER currentRow;
} TableDataCtx;


Datum odbc_tables_list(PG_FUNCTION_ARGS)
{
	SQLHENV env;
	SQLHDBC dbc;
	SQLHSTMT stmt;
	SQLUSMALLINT i;
	SQLUSMALLINT numColumns = 5;
	SQLUSMALLINT bufferSize = 1024;
	SQLUINTEGER rowLimit;
	SQLUINTEGER currentRow;
	SQLRETURN retCode;

	FuncCallContext *funcctx;
	TupleDesc tupdesc;
	TableDataCtx *datafctx;
	DataBinding* tableResult;
	AttInMetadata *attinmeta;

	if (SRF_IS_FIRSTCALL()) {
		MemoryContext oldcontext;
		char *serverName;
		int serverOid;
		odbcFdwOptions options;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
		datafctx = (TableDataCtx *) palloc(sizeof(TableDataCtx));
		tableResult = (DataBinding*) palloc( numColumns * sizeof(DataBinding) );

		serverName = text_to_cstring(PG_GETARG_TEXT_PP(0));
		serverOid = oid_from_server_name(serverName);

		rowLimit = PG_GETARG_INT32(1);
		currentRow = 0;

		odbcGetOptions(serverOid, NULL, &options);
		odbc_connection(&options, &env, &dbc);
		SQLAllocHandle(SQL_HANDLE_STMT, dbc, &stmt);

		for ( i = 0 ; i < numColumns ; i++ ) {
			tableResult[i].TargetType = SQL_C_CHAR;
			tableResult[i].BufferLength = (bufferSize + 1);
			tableResult[i].TargetValuePtr = palloc( sizeof(char)*tableResult[i].BufferLength );
		}

		for ( i = 0 ; i < numColumns ; i++ ) {
			retCode = SQLBindCol(stmt, i + 1, tableResult[i].TargetType, tableResult[i].TargetValuePtr, tableResult[i].BufferLength, &(tableResult[i].StrLen_or_Ind));
		}

		if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
			ereport(ERROR,
			        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			         errmsg("function returning record called in context "
			                "that cannot accept type record")));

		attinmeta = TupleDescGetAttInMetadata(tupdesc);

		datafctx->serverOid = serverOid;
		datafctx->tableResult = tableResult;
		datafctx->dbc = dbc;
		datafctx->env = env;
		datafctx->stmt = stmt;
		datafctx->rowLimit = rowLimit;
		datafctx->currentRow = currentRow;
		funcctx->user_fctx = datafctx;
		funcctx->attinmeta = attinmeta;

		MemoryContextSwitchTo(oldcontext);
	}

	funcctx = SRF_PERCALL_SETUP();

	datafctx = funcctx->user_fctx;
	stmt = datafctx->stmt;
	tableResult = datafctx->tableResult;
	rowLimit = datafctx->rowLimit;
	currentRow = datafctx->currentRow;
	attinmeta = funcctx->attinmeta;

	retCode = SQLTables( stmt, NULL, SQL_NTS, NULL, SQL_NTS, NULL, SQL_NTS, (SQLCHAR*)"TABLE", SQL_NTS );
	if (SQL_SUCCEEDED(retCode = SQLFetch(stmt)) && (rowLimit == 0 || currentRow < rowLimit)) {
		char       **values;
		HeapTuple    tuple;
		Datum        result;

		values = (char **) palloc(2 * sizeof(char *));
		values[0] = (char *) palloc(256 * sizeof(char));
		values[1] = (char *) palloc(256 * sizeof(char));
		snprintf(values[0], 256, "%s", (char *)tableResult[SQLTABLES_SCHEMA_COLUMN-1].TargetValuePtr);
		snprintf(values[1], 256, "%s", (char *)tableResult[SQLTABLES_NAME_COLUMN-1].TargetValuePtr);
		tuple = BuildTupleFromCStrings(attinmeta, values);
		result = HeapTupleGetDatum(tuple);
		currentRow++;
		datafctx->currentRow = currentRow;
		SRF_RETURN_NEXT(funcctx, result);
	} else {
		odbc_disconnection(&datafctx->env, &datafctx->dbc);
		SRF_RETURN_DONE(funcctx);
	}
}

/*
 * get quals in the select if there is one
 */
static void
odbcGetQual(Node *node, TupleDesc tupdesc, List *col_mapping_list, char **key, char **value, bool *pushdown)
{
	ListCell *col_mapping;
	*key = NULL;
	*value = NULL;
	*pushdown = false;

	elog_debug("%s", __func__);

	if (!node)
		return;

	if (IsA(node, OpExpr))
	{
		OpExpr  *op = (OpExpr *) node;
		Node    *left, *right;
		Index   varattno;

		if (list_length(op->args) != 2)
			return;

		left = list_nth(op->args, 0);
		if (!IsA(left, Var))

			return;

		varattno = ((Var *) left)->varattno;

		right = list_nth(op->args, 1);

		if (IsA(right, Const))
		{
			StringInfoData  buf;
			initStringInfo(&buf);
			/* And get the column and value... */
			*key = NameStr(TupleDescAttr(tupdesc, varattno - 1)->attname);

			if (((Const *) right)->consttype == PROCID_TEXTCONST)
				*value = TextDatumGetCString(((Const *) right)->constvalue);
			else
			{
				return;
			}

			/* convert qual keys to mapped couchdb attribute name */
			foreach(col_mapping, col_mapping_list)
			{
				DefElem *def = (DefElem *) lfirst(col_mapping);
				if (strcmp(def->defname, *key) == 0)
				{
					*key = defGetString(def);
					break;
				}
			}

			/*
			 * We can push down this qual if:
			 * - The operatory is TEXTEQ
			 * - The qual is on the _id column (in addition, _rev column can be also valid)
			 */

			if (op->opfuncid == PROCID_TEXTEQ)
				*pushdown = true;

			return;
		}
	}
	return;
}

/*
 * Check if the provided option is one of the valid options.
 * context is the Oid of the catalog holding the object the option is for.
 */
static bool
odbcIsValidOption(const char *option, Oid context)
{
	struct odbcFdwOption *opt;

	elog_debug("%s", __func__);

	/* Check if the options presents in the valid option list */
	for (opt = valid_options; opt->optname; opt++)
	{
		if (context == opt->optcontext && strcmp(opt->optname, option) == 0)
			return true;
	}

	/* ODBC attributes are valid in any context */
	if (is_odbc_attribute(option))
	{
		return true;
	}

	/* Foreign table may have anything as a mapping option */
	if (context == ForeignTableRelationId)
		return true;
	else
		return false;
}

static void odbcGetForeignRelSize(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid)
{
	unsigned int table_size   = 0;
	odbcFdwOptions options;

	elog_debug("%s", __func__);

	/* Fetch the foreign table options */
	odbcGetTableOptions(foreigntableid, &options);

	odbcGetTableSize(&options, &table_size);

	baserel->rows = table_size;
	baserel->tuples = baserel->rows;
}

static void odbcEstimateCosts(PlannerInfo *root, RelOptInfo *baserel, Cost *startup_cost, Cost *total_cost, Oid foreigntableid)
{
	unsigned int table_size   = 0;
	odbcFdwOptions options;

	elog_debug("----> starting %s", __func__);

	/* Fetch the foreign table options */
	odbcGetTableOptions(foreigntableid, &options);

	odbcGetTableSize(&options, &table_size);

	*startup_cost = 25;

	*total_cost = baserel->rows + *startup_cost;

	elog_debug("----> finishing %s", __func__);

}

static void odbcGetForeignPaths(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid)
{
	Cost startup_cost;
	Cost total_cost;

	elog_debug("----> starting %s", __func__);

	odbcEstimateCosts(root, baserel, &startup_cost, &total_cost, foreigntableid);

	add_path(baserel,
	         (Path *) create_foreignscan_path(root, baserel,
#if PG_VERSION_NUM >= 90600
	                 NULL, /* PathTarget */
#endif
	                 baserel->rows,
#if PG_VERSION_NUM >= 180000
	                 0, /* disabled_nodes */
#endif
	                 startup_cost,
	                 total_cost,
	                 NIL, /* no pathkeys */
	                 NULL, /* no outer rel either */
	                 NULL, /* no extra plan */
#if PG_VERSION_NUM >= 170000
	                 NIL, /* no fdw_restrictinfo list */
#endif
	                 NIL /* no fdw_private list */));

	elog_debug("----> finishing %s", __func__);
}

static bool odbcAnalyzeForeignTable(Relation relation, AcquireSampleRowsFunc *func, BlockNumber *totalpages)
{
	elog_debug("----> starting %s", __func__);
	elog_debug("----> finishing %s", __func__);

	return false;
}

static ForeignScan* odbcGetForeignPlan(PlannerInfo *root, RelOptInfo *baserel,
                                       Oid foreigntableid, ForeignPath *best_path, List *tlist, List *scan_clauses, Plan *outer_plan)
{
	Index scan_relid = baserel->relid;
	elog_debug("----> starting %s", __func__);

	scan_clauses = extract_actual_clauses(scan_clauses, false);

	elog_debug("----> finishing %s", __func__);

	return make_foreignscan(tlist, scan_clauses,
	                        scan_relid, NIL, NIL,
	                        NIL /* fdw_scan_tlist */, NIL, /* fdw_recheck_quals */
	                        NULL /* outer_plan */ );
}

/*
 * odbcBeginForeignScan
 *
 */
static void
odbcBeginForeignScan(ForeignScanState *node, int eflags)
{
	SQLHENV env;
	SQLHDBC dbc;
	odbcFdwExecutionState   *festate;
	SQLSMALLINT result_columns;
	SQLHSTMT stmt;
	SQLRETURN ret;

#ifdef DEBUG
	char dsn[256];
	char desc[256];
	SQLSMALLINT dsn_ret;
	SQLSMALLINT desc_ret;
	SQLUSMALLINT direction;
#endif

	odbcFdwOptions options;

	Relation rel;
	int num_of_columns;
	StringInfoData *columns;
	int i;
	ListCell *col_mapping;
	StringInfoData sql;
	StringInfoData col_str;
	StringInfoData name_qualifier_char;
	StringInfoData quote_char;

	char *qual_key         = NULL;
	char *qual_value       = NULL;
	bool pushdown          = false;

	const char* schema_name;
	int encoding = -1;

	elog_debug("%s", __func__);

	/* Fetch the foreign table options */
	odbcGetTableOptions(RelationGetRelid(node->ss.ss_currentRelation), &options);

	schema_name = get_schema_name(&options);

	odbc_connection(&options, &env, &dbc);

	/* Get quote char */
	getQuoteChar(dbc, &quote_char);

	/* Get name qualifier char */
	getNameQualifierChar(dbc, &name_qualifier_char);

	if (!is_blank_string(options.encoding))
	{
		encoding = pg_char_to_encoding(options.encoding);
		if (encoding < 0)
		{
			ereport(ERROR,
			        (errcode(ERRCODE_FDW_INVALID_ATTRIBUTE_VALUE),
			         errmsg("invalid encoding name \"%s\"", options.encoding)
			        ));
		}
	}

	/* Fetch the table column info */
	rel = table_open(RelationGetRelid(node->ss.ss_currentRelation), AccessShareLock);
	num_of_columns = rel->rd_att->natts;
	columns = (StringInfoData *) palloc(sizeof(StringInfoData) * num_of_columns);
	initStringInfo(&col_str);
	for (i = 0; i < num_of_columns; i++)
	{
		StringInfoData col;
		StringInfoData mapping;
		bool    mapped;

		/* retrieve the column name */
		initStringInfo(&col);
		appendStringInfo(&col, "%s", NameStr(TupleDescAttr(rel->rd_att,i)->attname));
		mapped = false;

		/* check if the column name is mapping to a different name in remote table */
		foreach(col_mapping, options.mapping_list)
		{
			DefElem *def = (DefElem *) lfirst(col_mapping);
			if (strcmp(def->defname, col.data) == 0)
			{
				initStringInfo(&mapping);
				appendStringInfo(&mapping, "%s", defGetString(def));
				mapped = true;
				break;
			}
		}

		/* decide which name is going to be used */
		if (mapped)
			columns[i] = mapping;
		else
			columns[i] = col;
		appendStringInfo(&col_str, i == 0 ? "%s%s%s" : ",%s%s%s", (char *) quote_char.data, columns[i].data, (char *) quote_char.data);
	}
	table_close(rel, NoLock);

	/* See if we've got a qual we can push down */
	if (node->ss.ps.plan->qual)
	{
#if PG_VERSION_NUM >= 100000
		ExprState  *state = node->ss.ps.qual;
		odbcGetQual((Node *) state->expr, node->ss.ss_currentRelation->rd_att, options.mapping_list, &qual_key, &qual_value, &pushdown);
#else
		ListCell    *lc;
		foreach (lc, node->ss.ps.qual)
		{
			/* Only the first qual can be pushed down to remote DBMS */
			ExprState  *state = lfirst(lc);
			odbcGetQual((Node *) state->expr, node->ss.ss_currentRelation->rd_att, options.mapping_list, &qual_key, &qual_value, &pushdown);
			if (pushdown)
				break;
		}
#endif
	}

	/* Construct the SQL statement used for remote querying */
	initStringInfo(&sql);
	if (!is_blank_string(options.sql_query))
	{
		/* Use custom query if it's available */
		appendStringInfo(&sql, "%s", options.sql_query);
	}
	else
	{
		/* Get options.table */
		char *escaped_table = escape_sql_identifier_part(options.table, quote_char.data);

		if (is_blank_string(schema_name))
		{
			appendStringInfo(&sql, "SELECT %s FROM %s%s%s", col_str.data,
			                 (char *) quote_char.data, escaped_table, (char *) quote_char.data);
		}
		else
		{
			char *escaped_schema = escape_sql_identifier_part(schema_name, quote_char.data);

			appendStringInfo(&sql, "SELECT %s FROM %s%s%s%s%s%s%s", col_str.data,
			                 (char *) quote_char.data, escaped_schema, (char *) quote_char.data,
			                 (char *) name_qualifier_char.data,
			                 (char *) quote_char.data, escaped_table, (char *) quote_char.data);
		}
		if (pushdown)
		{
			char *escaped_key = escape_sql_identifier_part(qual_key, quote_char.data);
			char *escaped_value = escape_sql_literal(qual_value);

			appendStringInfo(&sql, " WHERE %s%s%s = '%s'",
			                 (char *) quote_char.data, escaped_key, (char *) quote_char.data, escaped_value);
		}
	}

	/* Allocate a statement handle */
	SQLAllocHandle(SQL_HANDLE_STMT, dbc, &stmt);

	elog_debug("Executing query: %s", sql.data);

	/* Retrieve a list of rows */
	ret = SQLExecDirect(stmt, (SQLCHAR *) sql.data, SQL_NTS);
	check_return(ret, "Executing ODBC query", stmt, SQL_HANDLE_STMT);
	SQLNumResultCols(stmt, &result_columns);

	festate = (odbcFdwExecutionState *) palloc(sizeof(odbcFdwExecutionState));
	festate->attinmeta = TupleDescGetAttInMetadata(node->ss.ss_currentRelation->rd_att);
	copy_odbcFdwOptions(&(festate->options), &options);
	festate->env = env;
	festate->dbc = dbc;
	festate->stmt = stmt;
	festate->table_columns = columns;
	festate->num_of_table_cols = num_of_columns;
	/* prepare for the first iteration, there will be some precalculation needed in the first iteration*/
	festate->first_iteration = true;
	festate->encoding = encoding;
	/* festate comes from palloc, not palloc0, so this must be set explicitly */
	festate->row_count = 0;
	festate->result_bytes = 0;
	festate->query = sql.data;
	node->fdw_state = (void *) festate;
}

/*
 * odbcIterateForeignScan
 *
 */
static TupleTableSlot *
odbcIterateForeignScan(ForeignScanState *node)
{
	EState *executor_state = node->ss.ps.state;
	MemoryContext prev_context;
	/* ODBC API return status */
	SQLRETURN ret;
	odbcFdwExecutionState *festate = (odbcFdwExecutionState *) node->fdw_state;
	TupleTableSlot *slot = node->ss.ss_ScanTupleSlot;
	SQLSMALLINT columns;
	char    **values;
	HeapTuple   tuple;
	StringInfoData  col_data;
	SQLHSTMT stmt = festate->stmt;
	bool first_iteration = festate->first_iteration;
	int num_of_table_cols = festate->num_of_table_cols;
	int num_of_result_cols;
	StringInfoData  *table_columns = festate->table_columns;
	List *col_position_mask = NIL;
	List *col_size_array = NIL;
	List *col_conversion_array = NIL;

	elog_debug("%s", __func__);

	/*
	 * There is deliberately NO CHECK_FOR_INTERRUPTS() here, at the row
	 * boundary, because PostgreSQL already provides one: ExecScan checks
	 * interrupts once per tuple a scan node returns, and this FDW is only
	 * ever driven from there (odbcAnalyzeForeignTable returns false, so
	 * ANALYZE does not sample, and IterateForeignScan has no other caller).
	 *
	 * Measured with statement_timeout = 5s against a real SAP HANA 2.0
	 * tenant, on a 3,000,000-row remote scan, with no check in this function
	 * at all -- three shapes chosen to put the per-tuple loop in three
	 * different places: COPY of every row (many output tuples), count(*)
	 * (one output tuple), and a non-pushed-down qual matching nothing (zero
	 * output tuples). All three were cancelled at 5s. A check added here
	 * would be redundant, so it is not added.
	 *
	 * The gap is one level down, inside the chunked read; see the loop below.
	 */
	ret = SQLFetch(stmt);

	SQLNumResultCols(stmt, &columns);

	/*
	 * If this is the first iteration,
	 * we need to calculate the mask for column mapping as well as the column size
	 */
	if (first_iteration == true)
	{
		SQLCHAR *ColumnName;
		SQLSMALLINT NameLengthPtr;
		SQLSMALLINT DataTypePtr;
		SQLULEN     ColumnSizePtr;
		SQLSMALLINT DecimalDigitsPtr;
		SQLSMALLINT NullablePtr;
		int i;
		int k;
		bool found;

		StringInfoData sql_type;

		/* Allocate memory for the masks in a memory context that
		   persists between IterateForeignScan calls */
		prev_context = MemoryContextSwitchTo(executor_state->es_query_cxt);
		col_position_mask = NIL;
		col_size_array = NIL;
		col_conversion_array = NIL;
		num_of_result_cols = columns;
		/* Obtain the column information of the first row. */
		for (i = 1; i <= columns; i++)
		{
			ColumnConversion conversion = TEXT_CONVERSION;
			found = false;
			ColumnName = (SQLCHAR *) palloc(sizeof(SQLCHAR) * MAXIMUM_COLUMN_NAME_LEN);
			SQLDescribeCol(stmt,
			               i,                       /* ColumnName */
			               ColumnName,
			               sizeof(SQLCHAR) * MAXIMUM_COLUMN_NAME_LEN, /* BufferLength */
			               &NameLengthPtr,
			               &DataTypePtr,
			               &ColumnSizePtr,
			               &DecimalDigitsPtr,
			               &NullablePtr);

			sql_data_type(DataTypePtr, ColumnSizePtr, DecimalDigitsPtr, NullablePtr, &sql_type);
			if (strcmp("bytea", (char*)sql_type.data) == 0)
			{
				conversion = BIN_CONVERSION;
			}
			if (strcmp("boolean", (char*)sql_type.data) == 0)
			{
				conversion = BOOL_CONVERSION;
			}
			else if (strncmp("bit(",(char*)sql_type.data,4)==0 || strncmp("varbit(",(char*)sql_type.data,7)==0)
			{
				conversion = BIN_CONVERSION;
			}

			/* Get the position of the column in the FDW table */
			for (k=0; k<num_of_table_cols; k++)
			{
				/*
				 * Compare case-INSENSITIVELY, because the two ends fold
				 * identifiers in OPPOSITE directions: PostgreSQL folds an
				 * unquoted name to lower case, while SAP HANA -- like Oracle
				 * and DB2 -- folds to upper. So
				 *   CREATE FOREIGN TABLE t (dummy char(1)) SERVER hana
				 *     OPTIONS (sql_query 'SELECT DUMMY FROM "SYS"."DUMMY"');
				 * compared "dummy" against the result column "DUMMY", never
				 * matched, and dropped the column from the mapping with no
				 * error at all -- leaving mapped_pos == -1, which the loop
				 * below `continue`s over, so that column's values[] slot was
				 * never written. IMPORT FOREIGN SCHEMA escapes this only
				 * because it double-quotes the names it emits, which is why
				 * the failure presented as corrupt VALUES rather than as the
				 * name-mapping bug it is.
				 */
				if (pg_strcasecmp(table_columns[k].data, (char *) ColumnName) == 0)
				{
					SQLULEN min_size = minimum_buffer_size(DataTypePtr);
					SQLULEN max_size = MAXIMUM_BUFFER_SIZE;
					found = true;
					col_position_mask = lappend_int(col_position_mask, k);
					if (ColumnSizePtr < min_size)
						ColumnSizePtr = min_size;
					if (ColumnSizePtr > max_size)
						ColumnSizePtr = max_size;

					col_size_array = lappend_int(col_size_array, (int) ColumnSizePtr);
					col_conversion_array = lappend_int(col_conversion_array, (int) conversion);
					break;
				}
			}
			/* if current column is not used by the foreign table */
			if (!found)
			{
				col_position_mask = lappend_int(col_position_mask, -1);
				col_size_array = lappend_int(col_size_array, -1);
				col_conversion_array = lappend_int(col_conversion_array, 0);
			}
			pfree(ColumnName);
		}
		festate->num_of_result_cols = num_of_result_cols;
		festate->col_position_mask = col_position_mask;
		festate->col_size_array = col_size_array;
		festate->col_conversion_array = col_conversion_array;
		festate->first_iteration = false;

		MemoryContextSwitchTo(prev_context);
	}
	else
	{
		num_of_result_cols = festate->num_of_result_cols;
		col_position_mask = festate->col_position_mask;
		col_size_array = festate->col_size_array;
		col_conversion_array = festate->col_conversion_array;
	}

	ExecClearTuple(slot);
	if (SQL_SUCCEEDED(ret))
	{
		SQLSMALLINT i;

		/*
		 * Enforce max_row_count before doing any work for this row.
		 *
		 * A remote that returns far more rows than expected is otherwise
		 * bounded only by the executor's willingness to keep asking, and every
		 * row costs a palloc'd values[] array and one buffer per column. This
		 * refuses rather than stopping quietly: silently returning the first N
		 * rows of a larger result would be a wrong answer, which is worse than
		 * no answer.
		 */
		festate->row_count++;
		if (festate->options.max_row_count > 0 &&
		    festate->row_count > festate->options.max_row_count)
			ereport(ERROR,
			        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
			         errmsg("odbc_fdw: scan returned more than " INT64_FORMAT " rows",
			                festate->options.max_row_count),
			         errhint("Raise or remove the \"max_row_count\" option on the foreign table or server.")));
		/*
		 * One slot per FOREIGN TABLE column, and ZEROED.
		 *
		 * Was palloc(sizeof(char *) * columns), which is wrong twice over.
		 * It was sized by the number of RESULT columns while every write
		 * below indexes it by mapped_pos, a position in the FOREIGN TABLE,
		 * and BuildTupleFromCStrings reads natts entries regardless -- so a
		 * table with more columns than the query returns overran the
		 * allocation. And palloc does not zero, while a result column that
		 * matches no table column is `continue`d over, leaving that slot
		 * uninitialised for BuildTupleFromCStrings to dereference as a C
		 * string.
		 *
		 * That single read of uninitialised heap is the entire measured
		 * symptom set against HANA: 'ABCDEFGH' arriving empty, SYS.TABLES
		 * schema names arriving as a stray \x03 and as blanks with the row
		 * COUNT still correct, 424242 failing with "invalid input syntax for
		 * integer", and an intermittent SIGSEGV that took the whole instance
		 * into crash recovery and appeared to depend on which HANA client
		 * libraries were installed -- because that changed the heap layout,
		 * not the bug. A zeroed slot is a SQL NULL, which is the honest
		 * answer for a column the remote query did not return.
		 */
		values = (char **) palloc0(sizeof(char *) * num_of_table_cols);

		/* Loop through the columns */
		for (i = 1; i <= columns; i++)
		{
			int mask_index = i - 1;
			int col_size = list_nth_int(col_size_array, mask_index);
			int mapped_pos = list_nth_int(col_position_mask, mask_index);
			ColumnConversion conversion = list_nth_int(col_conversion_array, mask_index);
			SQLSMALLINT target_type = SQL_C_CHAR;
			SQLLEN result_size;
			int chunk_size, effective_chunk_size;
			int buffer_size = 0;
			char * buffer = 0;
			char * hex;
			int used_buffer_size = 0;
			GetDataTruncation truncation;
			bool binary_data = false;
			if (conversion == BIN_CONVERSION)
			{
				target_type	= SQL_C_BINARY;
				binary_data = true;
			}

			if (col_size == 0)
			{
				col_size = 1024;
			}

			chunk_size = binary_data ? col_size : col_size + 1;

			/* Ignore this column if position is marked as invalid */
			if (mapped_pos == -1)
				continue;

			do // Loop for reading the field in chunks
			{
				/*
				 * Make a single enormous field cancellable.
				 *
				 * This loop is the one part of a scan that PostgreSQL's own
				 * per-tuple check cannot reach: a LOB arrives in
				 * MAXIMUM_BUFFER_SIZE chunks, so Iterate is entered ONCE for
				 * the row and stays here for the whole value. Measured against
				 * a real SAP HANA 2.0 tenant on a single row holding one
				 * 60,000,000-character NCLOB, with this check absent: the read
				 * took 9.94s unbounded, and a pg_cancel_backend() issued 2.01s
				 * in did not stop it for a further 11.15s -- that is, not until
				 * the entire field had been read. With the check present the
				 * same scan stops before the read completes.
				 *
				 * Safe HERE specifically. No ODBC call is outstanding at this
				 * point -- SQLGetData has returned and the next one has not
				 * been issued -- so no handle is mid-operation. `buffer` is
				 * palloc'd and the pfree at the tail of this function is
				 * skipped when we throw, but it belongs to the memory context
				 * of the query being cancelled and is released with it. What is
				 * abandoned is a partially-read field on a statement that is
				 * being discarded anyway, which is exactly the state
				 * check_return already leaves behind when the driver errors
				 * mid-field, a few lines below. So this takes an existing
				 * unwind path rather than creating one.
				 *
				 * What it does NOT do is interrupt the driver. A blocking call
				 * inside libodbcHDB has no interrupt callback, so if the driver
				 * materialises a large LOB inside one SQLGetData -- which the
				 * measured cancel latency above indicates it does -- the wait
				 * for that call still cannot be cancelled. This bounds the
				 * LOOP, not the driver, and the honest claim is a scan that
				 * stops early rather than one that stops promptly.
				 */
				CHECK_FOR_INTERRUPTS();
				/*
				 * Enforce max_field_size before growing the buffer again, so a
				 * runaway value is refused while it is still bounded by the
				 * ceiling plus one chunk rather than after the whole thing has
				 * been assembled in memory. used_buffer_size is 0 on the first
				 * pass, so a value that arrives in a single chunk is never
				 * rejected here -- the exact test is after the loop.
				 */
				if (festate->options.max_field_size > 0 &&
				    (int64) used_buffer_size > festate->options.max_field_size)
					ereport(ERROR,
					        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					         errmsg("odbc_fdw: field value exceeds max_field_size of " INT64_FORMAT " bytes",
					                festate->options.max_field_size),
					         errhint("Raise or remove the \"max_field_size\" option on the foreign table or server.")));
				/*
				 * And the same for the scan total, for the same reason: bound
				 * memory while this field is still being assembled rather than
				 * once it exists. result_bytes covers the fields already
				 * completed, used_buffer_size this one so far.
				 */
				check_result_size(festate->options.max_result_size,
				                  festate->result_bytes, used_buffer_size);
				resize_buffer(&buffer, &buffer_size, used_buffer_size,
				              checked_buffer_extent(used_buffer_size, chunk_size));
				ret = SQLGetData(stmt, i, target_type, buffer + used_buffer_size, chunk_size, &result_size);
				if (ret == SQL_NO_DATA)
				{
					/*
					 * The column is exhausted, which is not an error.
					 *
					 * ODBC guarantees that a value can be retrieved across
					 * SEVERAL SQLGetData calls only for character and binary
					 * source types. Any other type rendered to SQL_C_CHAR gets
					 * ONE call: the driver truncates, reports 01004 with the full
					 * length, and then has no continuation to give. Measured
					 * against SAP HANA, CURRENT_TIMESTAMP is exactly that -- a
					 * driver-reported column size of 27 against a 29-byte
					 * rendering:
					 *   chunk=28 ret=1 rsize=29 state=01004   (27 bytes copied)
					 *   chunk=3  ret=100                      (SQL_NO_DATA)
					 * The loop then fell through to check_return, which rejects
					 * SQL_NO_DATA because it is not SQL_SUCCEEDED, and every
					 * timestamp failed with a bare "Reading data" and no driver
					 * diagnostic -- SQL_NO_DATA carries no diagnostic record,
					 * which is what made the message so uninformative.
					 *
					 * What was already copied IS the value, so terminate it and
					 * stop. Terminating explicitly matters because the value is
					 * consumed below as a C string: were SQL_NO_DATA to arrive on
					 * the FIRST call, breaking without this would hand
					 * appendStringInfoString an uninitialised buffer.
					 */
					resize_buffer(&buffer, &buffer_size, used_buffer_size, used_buffer_size + 1);
					buffer[used_buffer_size] = 0;
					ret = SQL_SUCCESS;
					break;
				}
				/*
				 * How much of this chunk is DATA.
				 *
				 * Was:
				 *   effective_chunk_size = chunk_size;
				 *   if (!binary_data && buffer[used_buffer_size + chunk_size - 1] == 0)
				 *           effective_chunk_size--;
				 * which read the chunk's last byte without consulting `ret` and
				 * without regard for how many bytes SQLGetData actually wrote.
				 * For any value shorter than the chunk -- the normal case, and
				 * always so for a column whose declared width exceeds its
				 * contents -- that byte is uninitialised heap, so a control-flow
				 * decision depended on undefined memory.
				 *
				 * The test is also unnecessary. effective_chunk_size is read only
				 * on the truncation arms below, which are reached only when the
				 * driver really did fill the chunk, and SQL_C_CHAR output is
				 * always NUL-terminated -- so a truncated character chunk carries
				 * exactly chunk_size - 1 bytes of data. Binary data is not
				 * terminated and uses the whole chunk.
				 */
				effective_chunk_size = binary_data ? chunk_size : chunk_size - 1;
				truncation = result_truncation(ret, stmt);
				if (truncation == STRING_TRUNCATION)
				{
					if (result_size == SQL_NO_TOTAL)
					{
						// no info about remaining data size; keep reading with same chunk_size
						used_buffer_size += effective_chunk_size;
					}
					else
					{
						// we read chunk_size, but there was result_size pending in total;
						// adjust chunk_size for the remaining, so next wil hopely be the final chunk
						used_buffer_size += effective_chunk_size;
						/*
						 * result_size is a 64-bit SQLLEN and chunk_size is an
						 * int, so this cast could TRUNCATE. A driver reporting a
						 * total of 2^32 + 100 produced (int) 100, which then read
						 * 100 bytes, concluded the value was complete, and
						 * returned a silently truncated field -- and a total whose
						 * low 32 bits happened to be negative fell through to the
						 * extent arithmetic instead. Neither is a length this
						 * extension can honour: a value is built into a
						 * PostgreSQL datum, which cannot exceed 1GB anyway, so
						 * refuse rather than cast.
						 */
						if (result_size > (SQLLEN) PG_INT32_MAX)
							ereport(ERROR,
							        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
							         errmsg("odbc_fdw: field value too large to buffer"),
							         errdetail("The ODBC driver reported a total length of " INT64_FORMAT " bytes.",
							                   (int64) result_size)));
						// note that we need to read result_size - effective_chunk_size more data bytes,
						chunk_size = (int)result_size - effective_chunk_size;
						// wait, maybe we don't need to read, just append a zero!
						if (chunk_size == 0)
						{
							if (!binary_data)
							{
								/*
								 * Writes at used_buffer_size - 1, so it needs at
								 * least one byte already buffered. Guarded because
								 * a driver reporting a total equal to what it had
								 * already delivered while delivering nothing would
								 * otherwise write buffer[-1].
								 */
								if (used_buffer_size < 1)
									ereport(ERROR,
									        (errcode(ERRCODE_FDW_ERROR),
									         errmsg("odbc_fdw: ODBC driver reported a complete value having returned no data")));
								resize_buffer(&buffer, &buffer_size, used_buffer_size, used_buffer_size + 1);
								buffer[used_buffer_size - 1] = 0;
							}
							break;
						}
						if (!binary_data)
						{
							chunk_size += 1;
						}
					}
				}
				else if (truncation == FRACTIONAL_TRUNCATION)
				{
					/* Fractional truncation has occurred;
					* at this point we cannot obtain the lost digits
					*/
					used_buffer_size += effective_chunk_size;
					if (chunk_size == effective_chunk_size)
					{
						/* The driver has omitted the trailing zero */
						resize_buffer(&buffer, &buffer_size, used_buffer_size, used_buffer_size + 1);
						buffer[used_buffer_size] = 0;
					}
					elog_debug("Truncating number: %s", buffer);
				}
				else // NO_TRUNCATION: finish reading
				{
					/*
					 * result_size is an INDICATOR, not always a length:
					 * SQL_NULL_DATA (-1) for a NULL value, SQL_NO_TOTAL (-4)
					 * when the driver will not say. Adding it unchecked drove
					 * used_buffer_size NEGATIVE, and the
					 * strnlen(buffer, used_buffer_size) below then ran with a
					 * (size_t)-1 bound -- an out-of-bounds scan on every NULL
					 * value, which the SQL_NULL_DATA test further down was too
					 * late to prevent. Clamping to chunk_size keeps the total
					 * within what resize_buffer just guaranteed, so a driver
					 * over-reporting a length cannot walk off the end either.
					 */
					if (result_size > 0)
						used_buffer_size += (result_size > chunk_size)
						                    ? chunk_size : (int) result_size;
				}
			} while (truncation == STRING_TRUNCATION && chunk_size > 0);

			if (!binary_data)
			{
				used_buffer_size = strnlen(buffer, used_buffer_size);
			}

			/*
			 * The exact max_field_size test, on the value's real length. The
			 * in-loop check above bounds MEMORY while the value is still being
			 * assembled, but it cannot be exact: it runs before each chunk, so
			 * a value delivered in one chunk never reaches it. Both are needed
			 * -- without this one a max_field_size smaller than a single chunk
			 * would not be enforced at all.
			 */
			if (festate->options.max_field_size > 0 &&
			    (int64) used_buffer_size > festate->options.max_field_size)
				ereport(ERROR,
				        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				         errmsg("odbc_fdw: field value of %d bytes exceeds max_field_size of " INT64_FORMAT,
				                used_buffer_size, festate->options.max_field_size),
				         errhint("Raise or remove the \"max_field_size\" option on the foreign table or server.")));

			/*
			 * The exact max_result_size test, on this field's real length, then
			 * charge it to the scan. Checked BEFORE adding so that the running
			 * total never exceeds the ceiling, which is the invariant
			 * check_result_size' subtraction relies on to be overflow-free.
			 *
			 * used_buffer_size is what this extension retrieved into its own
			 * buffer. It is not the tuple's footprint: a BIN_CONVERSION column
			 * is hex-encoded to twice this, and the StringInfo and the heap
			 * tuple are further copies. So this ceiling bounds the retrieval,
			 * and the backend's actual high-water mark is a multiple of it.
			 */
			check_result_size(festate->options.max_result_size,
			                  festate->result_bytes, used_buffer_size);
			festate->result_bytes += (int64) used_buffer_size;

			if (ret != SQL_SUCCESS_WITH_INFO)
			{
				// TODO: review check_result behaviour for SQL_SUCCESS_WITH_INFO (it should not fail right?)
				check_return(ret, "Reading data", stmt, SQL_HANDLE_STMT);
			}

			if (SQL_SUCCEEDED(ret))
			{
				/* Handle null columns */
				if (result_size == SQL_NULL_DATA)
				{
					// BuildTupleFromCStrings expects NULLs to be NULL pointers
					values[mapped_pos] = NULL;
				}
				else
				{
					if (festate->encoding != -1 && !binary_data)
					{
						/* Convert character encoding */
						buffer = pg_any_to_server(buffer, used_buffer_size, festate->encoding);
					}
					initStringInfo(&col_data);
					switch (conversion)
					{
					case TEXT_CONVERSION :
						appendStringInfoString (&col_data, buffer);
						break;
					case BOOL_CONVERSION :
						if (buffer[0] == 0)
							strcpy(buffer, "F");
						else if (buffer[0] == 1)
							strcpy(buffer, "T");
						appendStringInfoString (&col_data, buffer);
						break;
					case BIN_CONVERSION :
						/* TODO: avoid hex conversion by building the tuple from Datum values instead of using BuildTupleFromCStrings */
						hex = binary_to_hex(buffer, used_buffer_size);
						appendStringInfoString (&col_data, "\\x");
						appendStringInfoString (&col_data, hex);
						pfree(hex);
						break;
					}

					values[mapped_pos] = col_data.data;
				}
			}
			pfree(buffer);
		}

		tuple = BuildTupleFromCStrings(festate->attinmeta, values);
#if PG_VERSION_NUM < 120000
		ExecStoreTuple(tuple, slot, InvalidBuffer, false);
#else
		ExecStoreHeapTuple(tuple, slot, false);
#endif
		pfree(values);
	}

	return slot;
}

/*
 * odbcExplainForeignScan
 *
 */
static void
odbcExplainForeignScan(ForeignScanState *node, ExplainState *es)
{
	odbcFdwExecutionState *festate;
	unsigned int table_size = 0;

	elog_debug("%s", __func__);

	festate = (odbcFdwExecutionState *) node->fdw_state;

	odbcGetTableSize(&(festate->options), &table_size);

	/* Suppress file size if we're not showing cost details */
	if (es->costs)
	{
#if PG_VERSION_NUM >= 110000
		ExplainPropertyInteger("Foreign Table Size", "b", table_size, es);
#else
		ExplainPropertyLong("Foreign Table Size", table_size, es);
#endif
	}
}

/*
 * odbcEndForeignScan
 *      Finish scanning foreign table and dispose objects used for this scan
 */
static void
odbcEndForeignScan(ForeignScanState *node)
{
	odbcFdwExecutionState *festate;

	elog_debug("%s", __func__);

	/* if festate is NULL, we are in EXPLAIN; nothing to do */
	festate = (odbcFdwExecutionState *) node->fdw_state;
	if (festate)
	{
		if (festate->stmt)
		{
			SQLFreeHandle(SQL_HANDLE_STMT, festate->stmt);
			festate->stmt = NULL;
		}
		odbc_disconnection(&festate->env, &festate->dbc);
	}
}

/*
 * odbcReScanForeignScan
 *      Rescan table, possibly with new parameters
 */
static void
odbcReScanForeignScan(ForeignScanState *node)
{
	odbcFdwExecutionState *festate = (odbcFdwExecutionState *) node->fdw_state;
	SQLRETURN ret;

	elog_debug("%s", __func__);

	/*
	 * Actually rescan. This was an empty function, and an empty ReScan is not a
	 * cheap no-op here: the executor's contract is that after this call the scan
	 * starts again from the first row, and nothing else repositions an ODBC
	 * cursor. The cursor was left wherever the previous scan finished --
	 * normally exhausted -- so the second and every later scan returned NO ROWS
	 * and the query got a wrong answer with no error anywhere.
	 *
	 * SQLFreeStmt with SQL_CLOSE rather than SQLCloseCursor, and the difference
	 * matters: SQLCloseCursor returns SQL_ERROR with SQLSTATE 24000 when no
	 * cursor is open, which is a perfectly ordinary state here (a scan whose
	 * result set the executor never opened, or which the driver closed on
	 * exhaustion), so it would either have to be called and its return ignored
	 * -- indistinguishable from a real failure -- or guarded by state this
	 * function does not have. SQL_CLOSE is documented as having no effect when
	 * no cursor is open, and leaves the statement allocated and executable.
	 *
	 * Re-executing the stored text is correct because nothing in it varies per
	 * rescan: odbcGetQual pushes down only `Var = Const` with a text constant
	 * and TEXTEQ, so a Param never reaches the remote query, and a correlated
	 * qual stays a LOCAL filter on the scan node. If a future change pushes a
	 * parameter down, this function must rebuild the query instead of replaying
	 * it, and that is the note to find here.
	 *
	 * first_iteration is deliberately NOT reset. The masks it computes describe
	 * the mapping between the result set and the foreign table, the re-executed
	 * statement is the same statement, so its result metadata is identical and
	 * the masks stay valid. Resetting would recompute them into
	 * es_query_cxt on every rescan, which leaks for the life of the query.
	 */
	SQLFreeStmt(festate->stmt, SQL_CLOSE);
	ret = SQLExecDirect(festate->stmt, (SQLCHAR *) festate->query, SQL_NTS);
	check_return(ret, "Re-executing ODBC query", festate->stmt, SQL_HANDLE_STMT);

	/* The ceilings are per scan, so their counters restart with the scan. */
	festate->row_count = 0;
	festate->result_bytes = 0;
}


static void
appendQuotedString(StringInfo buffer, const char* text)
{
	static const char SINGLE_QUOTE = '\'';
	const char *p;

	appendStringInfoChar(buffer, SINGLE_QUOTE);

	while (*text)
	{
		p = text;
		while (*p && *p != SINGLE_QUOTE)
		{
			p++;
		}
		appendBinaryStringInfo(buffer, text, p - text);
		if (*p == SINGLE_QUOTE)
		{
			appendStringInfoChar(buffer, SINGLE_QUOTE);
			appendStringInfoChar(buffer, SINGLE_QUOTE);
			p++;
		}
		text = p;
	}

	appendStringInfoChar(buffer, SINGLE_QUOTE);
}

static void
appendOption(StringInfo str, bool first, const char* option_name, const char* option_value)
{
	if (!first)
	{
		appendStringInfo(str, ",\n");
	}
	appendStringInfo(str, "\"%s\" ", option_name);
	appendQuotedString(str, option_value);
}

List *
odbcImportForeignSchema(ImportForeignSchemaStmt *stmt, Oid serverOid)
{
	/* TODO: review memory management in this function; any leaks? */
	odbcFdwOptions options;

	List* create_statements = NIL;
	List* tables = NIL;
	List* table_columns = NIL;
	ListCell *tables_cell;
	ListCell *table_columns_cell;
	RangeVar *table_rangevar;

	SQLHENV env;
	SQLHDBC dbc;
	SQLHSTMT query_stmt;
	SQLHSTMT columns_stmt;
	SQLHSTMT tables_stmt;
	SQLRETURN ret;
	SQLSMALLINT result_columns;
	StringInfoData col_str;
	SQLCHAR *ColumnName;
	SQLCHAR *TableName;
	SQLSMALLINT NameLength;
	SQLSMALLINT DataType;
	SQLULEN     ColumnSize;
	SQLSMALLINT DecimalDigits;
	SQLSMALLINT Nullable;
	int i;
	StringInfoData sql_type;
	SQLLEN indicator;
	const char* schema_name;
	bool missing_foreign_schema = false;
	bool first_column = true;

	elog_debug("%s", __func__);

	odbcGetOptions(serverOid, stmt->options, &options);

	schema_name = get_schema_name(&options);
	if (schema_name == NULL)
	{
		schema_name = stmt->remote_schema;
		missing_foreign_schema = true;
	}
	else if (is_blank_string(schema_name))
	{
		// This allows overriding and removing the schema, which is necessary
		// for some schema-less ODBC data sources (e.g. Hive)
		schema_name = NULL;
	}

	if (!is_blank_string(options.sql_query))
	{
		/* Generate foreign table for a query */
		if (is_blank_string(options.table))
		{
			elog(ERROR, "Must provide 'table' option to name the foreign table");
		}

		odbc_connection(&options, &env, &dbc);

		/* Allocate a statement handle */
		SQLAllocHandle(SQL_HANDLE_STMT, dbc, &query_stmt);

		/* Retrieve a list of rows */
		ret = SQLExecDirect(query_stmt, (SQLCHAR *) options.sql_query, SQL_NTS);
		check_return(ret, "Executing ODBC query to get schema", query_stmt, SQL_HANDLE_STMT);

		SQLNumResultCols(query_stmt, &result_columns);

		initStringInfo(&col_str);
		ColumnName = (SQLCHAR *) palloc(sizeof(SQLCHAR) * MAXIMUM_COLUMN_NAME_LEN);

		for (i = 1; i <= result_columns; i++)
		{
			SQLDescribeCol(query_stmt,
			               i,                       /* ColumnName */
			               ColumnName,
			               sizeof(SQLCHAR) * MAXIMUM_COLUMN_NAME_LEN, /* BufferLength */
			               &NameLength,
			               &DataType,
			               &ColumnSize,
			               &DecimalDigits,
			               &Nullable);

			sql_data_type(DataType, ColumnSize, DecimalDigits, Nullable, &sql_type);
			if (is_blank_string(sql_type.data))
			{
				elog(NOTICE, "Data type not supported (%d) for column %s", DataType, ColumnName);
				continue;
			}
			if (!first_column)
			{
				appendStringInfo(&col_str, ", ");
			}
			else
			{
				first_column = false;
			}

			appendStringInfo(&col_str, "\"%s\" %s", ColumnName, (char *) sql_type.data);
		}
		SQLCloseCursor(query_stmt);
		SQLFreeHandle(SQL_HANDLE_STMT, query_stmt);
		odbc_disconnection(&env, &dbc);

		tables        = lappend(tables, (void*)options.table);
		table_columns = lappend(table_columns, (void*)col_str.data);
	}
	else
	{
		/* Reflect one or more foreign tables */
		if (!is_blank_string(options.table))
		{
			tables = lappend(tables, (void*)options.table);
		}
		else if (stmt->list_type == FDW_IMPORT_SCHEMA_ALL || stmt->list_type == FDW_IMPORT_SCHEMA_EXCEPT)
		{
			/* Will obtain the foreign tables with SQLTables() */

			SQLCHAR *table_schema = (SQLCHAR *) palloc(sizeof(SQLCHAR) * MAXIMUM_SCHEMA_NAME_LEN);

			odbc_connection(&options, &env, &dbc);

			/* Allocate a statement handle */
			SQLAllocHandle(SQL_HANDLE_STMT, dbc, &tables_stmt);

			ret = SQLTables(
			          tables_stmt,
			          NULL, 0, /* Catalog: (SQLCHAR*)SQL_ALL_CATALOGS, SQL_NTS would include also tables from internal catalogs */
			          NULL, 0, /* Schema: we avoid filtering by schema here to avoid problems with some drivers */
			          NULL, 0, /* Table */
			          (SQLCHAR*)"TABLE", SQL_NTS /* Type of table (we're not interested in views, temporary tables, etc.) */
			      );
			check_return(ret, "Obtaining ODBC tables", tables_stmt, SQL_HANDLE_STMT);

			initStringInfo(&col_str);
			while (SQL_SUCCESS == ret)
			{
				ret = SQLFetch(tables_stmt);
				if (SQL_SUCCESS == ret)
				{
					int excluded = false;
					SQLRETURN getdata_ret;
					TableName = (SQLCHAR *) palloc(sizeof(SQLCHAR) * MAXIMUM_TABLE_NAME_LEN);
					getdata_ret = SQLGetData(tables_stmt, SQLTABLES_NAME_COLUMN, SQL_C_CHAR, TableName, MAXIMUM_TABLE_NAME_LEN, &indicator);
					check_return(getdata_ret, "Reading table name", tables_stmt, SQL_HANDLE_STMT);

					/* Since we're not filtering the SQLTables call by schema
					   we must exclude here tables that belong to other schemas.
					   For some ODBC drivers tables may not be organized into
					   schemas and the schema of the table will be blank.
					   So we only reject tables for which the schema is not
					   blank and different from the desired schema:
					 */
					getdata_ret = SQLGetData(tables_stmt, SQLTABLES_SCHEMA_COLUMN, SQL_C_CHAR, table_schema, MAXIMUM_SCHEMA_NAME_LEN, &indicator);
					if (SQL_SUCCESS == getdata_ret)
					{
						if (!is_blank_string((char*)table_schema) && strcmp((char*)table_schema, schema_name) )
						{
							excluded = true;
						}
					}
					else
					{
						/* Some drivers don't support schemas and may return an error code here;
						 * in that case we must avoid using an schema to query the table columns.
						 */
						schema_name = NULL;
						missing_foreign_schema = false;
					}

					/* Since we haven't specified SQL_ALL_CATALOGS in the
					   call to SQLTables we shouldn't get tables from special
					   catalogs and only from the regular catalog of the database
					   (the catalog name is usually the name of the database or blank,
					   but depends on the driver and may vary, and can be obtained with:
					     SQLCHAR *table_catalog = (SQLCHAR *) palloc(sizeof(SQLCHAR) * MAXIMUM_CATALOG_NAME_LEN);
					     SQLGetData(tables_stmt, 1, SQL_C_CHAR, table_catalog, MAXIMUM_CATALOG_NAME_LEN, &indicator);
					 */

					/* And now we'll handle tables excluded by an EXCEPT clause */
					if (!excluded && stmt->list_type == FDW_IMPORT_SCHEMA_EXCEPT)
					{
						foreach(tables_cell,  stmt->table_list)
						{
							table_rangevar = (RangeVar*)lfirst(tables_cell);
							if (strcmp((char*)TableName, table_rangevar->relname) == 0)
							{
								excluded = true;
							}
						}
					}

					if (!excluded)
					{
						tables = lappend(tables, (void*)TableName);
					}
				}
			}

			SQLCloseCursor(tables_stmt);

			SQLFreeHandle(SQL_HANDLE_STMT, tables_stmt);
			odbc_disconnection(&env, &dbc);
		}
		else if (stmt->list_type == FDW_IMPORT_SCHEMA_LIMIT_TO)
		{
			foreach(tables_cell, stmt->table_list)
			{
				table_rangevar = (RangeVar*)lfirst(tables_cell);
				tables = lappend(tables, (void*)table_rangevar->relname);
			}
		}
		else
		{
			elog(ERROR,"Unknown list type in IMPORT FOREIGN SCHEMA");
		}

		odbc_connection(&options, &env, &dbc);
		foreach(tables_cell, tables)
		{
			char *table_name = (char*)lfirst(tables_cell);

			/* Allocate a statement handle */
			SQLAllocHandle(SQL_HANDLE_STMT, dbc, &columns_stmt);

			ret = SQLColumns(
			          columns_stmt,
			          NULL, 0,
			          (SQLCHAR*)schema_name, SQL_NTS,
			          (SQLCHAR*)table_name,  SQL_NTS,
			          NULL, 0
			      );
			check_return(ret, "Obtaining ODBC columns", columns_stmt, SQL_HANDLE_STMT);

			i = 0;
			initStringInfo(&col_str);
			ColumnName = (SQLCHAR *) palloc(sizeof(SQLCHAR) * MAXIMUM_COLUMN_NAME_LEN);
			while (SQL_NO_DATA != ret && SQL_SUCCESS_WITH_INFO != ret)
			{
				ret = SQLFetch(columns_stmt);
				if (SQL_SUCCESS == ret)
				{
					ret = SQLGetData(columns_stmt, 4, SQL_C_CHAR, ColumnName, MAXIMUM_COLUMN_NAME_LEN, &indicator);
					// check_return(ret, "Reading column name", columns_stmt, SQL_HANDLE_STMT);
					ret = SQLGetData(columns_stmt, 5, SQL_C_SSHORT, &DataType, MAXIMUM_COLUMN_NAME_LEN, &indicator);
					// check_return(ret, "Reading column type", columns_stmt, SQL_HANDLE_STMT);
					ret = SQLGetData(columns_stmt, 7, SQL_C_SLONG, &ColumnSize, 0, &indicator);
					// check_return(ret, "Reading column size", columns_stmt, SQL_HANDLE_STMT);
					ret = SQLGetData(columns_stmt, 9, SQL_C_SSHORT, &DecimalDigits, 0, &indicator);
					// check_return(ret, "Reading column decimals", columns_stmt, SQL_HANDLE_STMT);
					ret = SQLGetData(columns_stmt, 11, SQL_C_SSHORT, &Nullable, 0, &indicator);
					// check_return(ret, "Reading column nullable", columns_stmt, SQL_HANDLE_STMT);
					sql_data_type(DataType, ColumnSize, DecimalDigits, Nullable, &sql_type);
					if (is_blank_string(sql_type.data))
					{
						elog(NOTICE, "Data type not supported (%d) for column %s", DataType, ColumnName);
						continue;
					}
					if (++i > 1)
					{
						appendStringInfo(&col_str, ", ");
					}
					appendStringInfo(&col_str, "\"%s\" %s", ColumnName, (char *) sql_type.data);
				}
				#ifdef DEBUG
				if (ret == SQL_ERROR || ret == SQL_SUCCESS_WITH_INFO)
				{
					SQLINTEGER   j = 1;
					SQLINTEGER   native;
					SQLCHAR  state[ 7 ];
					SQLCHAR  text[256];
					SQLSMALLINT  len;
					SQLRETURN    diag_ret;
					do
					{
				        diag_ret = SQLGetDiagRec(SQL_HANDLE_STMT, columns_stmt, j++, state, &native, text, sizeof(text), &len);
						if (SQL_SUCCEEDED(diag_ret))
							elog(DEBUG1, "FETCHING %s:%ld:%ld:%s\n", state, (long int) j, (long int) native, text);
					}
					while( diag_ret == SQL_SUCCESS );
				}
				#endif
			}
			SQLCloseCursor(columns_stmt);
			SQLFreeHandle(SQL_HANDLE_STMT, columns_stmt);

			/*
			 * Refuse a table the remote could not describe, instead of
			 * importing a foreign table with NO COLUMNS.
			 *
			 * `i` counts the columns actually emitted above. Zero of them
			 * produced `CREATE FOREIGN TABLE "local"."name" () SERVER ...`,
			 * which PostgreSQL accepts quite happily -- so IMPORT FOREIGN
			 * SCHEMA reported success and left behind an object that can only
			 * ever fail, at some later moment, in somebody else's query.
			 *
			 * The case this exists for is IMPORT FOREIGN SCHEMA ... LIMIT TO.
			 * Those names are NOT checked against the remote: unlike the
			 * enumerated and EXCEPT paths, which build their list from
			 * SQLTables, LIMIT TO takes the names verbatim from the parsed
			 * statement and trusts them. PostgreSQL has already folded any
			 * unquoted identifier to lower case by then, so against a remote
			 * that folds UP -- SAP HANA, Oracle, DB2 -- or one with genuinely
			 * mixed-case names,
			 *   IMPORT FOREIGN SCHEMA "S" LIMIT TO (MixedTbl) ...
			 * asks for "mixedtbl", which does not exist there. Measured: the
			 * import SUCCEEDED and created a zero-column foreign table whose
			 * `table` option named a table the remote has never had.
			 *
			 * This costs no extra remote work. SQLColumns has already been
			 * called and has already answered; the answer was simply being
			 * discarded.
			 *
			 * It only DIAGNOSES. The name is folded before this wrapper is
			 * reached, so nothing here can recover what was meant -- a caller
			 * that generates IMPORT statements must double-quote the
			 * identifiers it emits.
			 */
			if (i == 0)
			{
				if (stmt->list_type == FDW_IMPORT_SCHEMA_LIMIT_TO)
				{
					/*
					 * Only mention identifier folding when folding could
					 * actually be the cause. PostgreSQL folds an unquoted
					 * identifier to LOWER case, so a name arriving here with
					 * any upper-case letter in it was quoted by the caller and
					 * reached us verbatim -- telling them to quote it would be
					 * advice they have already taken. An all-lower-case name
					 * may have been folded or may have been quoted that way,
					 * and the hint is right either way against a remote that
					 * folds up.
					 */
					const char *p;
					bool has_upper = false;

					for (p = table_name; *p; p++)
					{
						if (*p >= 'A' && *p <= 'Z')
						{
							has_upper = true;
							break;
						}
					}

					if (has_upper)
						ereport(ERROR,
						        (errcode(ERRCODE_FDW_TABLE_NOT_FOUND),
						         errmsg("odbc_fdw: remote table \"%s\" was not found, or has no column that can be imported",
						                table_name),
						         errdetail("SQLColumns returned no usable column for schema \"%s\", table \"%s\".",
						                   schema_name ? schema_name : "", table_name),
						         errhint("The name was quoted, so it reached the remote exactly as written. Check that the table exists in that schema and that the connecting user can see its columns.")));
					else
						ereport(ERROR,
						        (errcode(ERRCODE_FDW_TABLE_NOT_FOUND),
						         errmsg("odbc_fdw: remote table \"%s\" was not found, or has no column that can be imported",
						                table_name),
						         errdetail("SQLColumns returned no usable column for schema \"%s\", table \"%s\".",
						                   schema_name ? schema_name : "", table_name),
						         errhint("A LIMIT TO name is parsed by PostgreSQL, which folds an unquoted identifier to LOWER case before this wrapper sees it, so \"%s\" may not be how the remote spells the table. Double-quote the name exactly as the remote spells it.",
						                 table_name)));
				}
				else
					ereport(ERROR,
					        (errcode(ERRCODE_FDW_ERROR),
					         errmsg("odbc_fdw: remote table \"%s\" has no column that can be imported",
					                table_name),
					         errdetail("SQLColumns returned no usable column for schema \"%s\", table \"%s\".",
					                   schema_name ? schema_name : "", table_name),
					         errhint("The driver enumerated this table, so it exists. Either the connecting user cannot see its columns, or every column has a type this wrapper does not map -- each such column is reported as a NOTICE above. Use EXCEPT to skip it.")));
			}

			table_columns = lappend(table_columns, (void*)col_str.data);
		}
		odbc_disconnection(&env, &dbc);
	}

	/* Generate create statements */
	table_columns_cell = list_head(table_columns);
	foreach(tables_cell, tables)
	{
		// temporarily define vars here...
		char *table_name = (char*)lfirst(tables_cell);
		char *columns    = (char*)lfirst(table_columns_cell);
		StringInfoData create_statement;
		ListCell *option;
		int option_count = 0;
		const char *prefix = empty_string_if_null(options.prefix);

#if PG_VERSION_NUM >= 130000
		table_columns_cell = lnext(table_columns, table_columns_cell);
#else
		table_columns_cell = lnext(table_columns_cell);
#endif

		initStringInfo(&create_statement);
		appendStringInfo(&create_statement, "CREATE FOREIGN TABLE \"%s\".\"%s%s\" (", stmt->local_schema, prefix, (char *) table_name);
		appendStringInfo(&create_statement, "%s", columns);
		appendStringInfo(&create_statement, ") SERVER %s\n", stmt->server_name);
		appendStringInfo(&create_statement, "OPTIONS (\n");
		foreach(option, stmt->options)
		{
			DefElem *def = (DefElem *) lfirst(option);
#if PG_VERSION_NUM >= 100000
			// options not in the CREATE FOREIGN TABLE statement will have location == -1
			// we'll ignore them as they are defined by the SERVER or USER MAPPING, and including them here
			// would be functional but could expose sensitive information
			if (def->location != -1) {
				appendOption(&create_statement, ++option_count == 1, def->defname, defGetString(def));
			}
#else
			appendOption(&create_statement, ++option_count == 1, def->defname, defGetString(def));
#endif
		}
		if (is_blank_string(options.table))
		{
			appendOption(&create_statement, ++option_count == 1, "table", table_name);
		}
		if (missing_foreign_schema)
		{
			appendOption(&create_statement, ++option_count == 1, "schema", schema_name);
		}
		appendStringInfo(&create_statement, ");");
		elog(DEBUG1, "CREATE: %s", create_statement.data);
		create_statements = lappend(create_statements, (void*)create_statement.data);
	}

	return create_statements;
}
