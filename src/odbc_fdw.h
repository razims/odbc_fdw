/*----------------------------------------------------------
 *
 *        Internal declarations for the ODBC foreign-data wrapper.
 *
 * Copyright (c) 2011, PostgreSQL Global Development Group
 * Copyright (c) 2026, Softinent
 *
 * This software is released under the PostgreSQL Licence.
 *
 *----------------------------------------------------------
 */

#ifndef ODBC_FDW_H
#define ODBC_FDW_H

#include "postgres.h"

#include <string.h>
#include <stdio.h>
#include <sql.h>
#include <sqlext.h>

#include "funcapi.h"
#include "access/reloptions.h"
#include "access/tupdesc.h"
#if PG_VERSION_NUM < 120000
#include "access/heapam.h"
#define table_open heap_open
#define table_close heap_close
#else
#include "access/table.h"
#endif
#include "access/xact.h"
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
#include "executor/spi.h"
#include "foreign/fdwapi.h"
#include "foreign/foreign.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodes.h"
#include "nodes/pg_list.h"
#include "optimizer/cost.h"
#include "optimizer/pathnode.h"
#include "optimizer/planmain.h"
#include "optimizer/restrictinfo.h"
#include "storage/fd.h"
#include "storage/lock.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/relcache.h"

#if defined(_WIN32)
#define strcasecmp _stricmp
#endif

/* TupleDescAttr was backported into 9.5.9 and 9.6.5 but we support any 9.5.X. */
#if PG_VERSION_NUM < 90605
#ifndef TupleDescAttr
#define TupleDescAttr(tupdesc, i) ((tupdesc)->attrs[(i)])
#endif
#endif

/* unixODBC 2.3.12 does not expose this ODBC 3.0 type's symbolic name. */
#ifndef SQL_BOOLEAN
#define SQL_BOOLEAN 16
#endif

#ifdef DEBUG
#define elog_debug(...) elog(DEBUG1, __VA_ARGS__)
#else
#define elog_debug(...) ((void) 0)
#endif

#define PROCID_TEXTEQ 67
#define PROCID_TEXTCONST 25

#define MAXIMUM_CATALOG_NAME_LEN 255
#define MAXIMUM_SCHEMA_NAME_LEN 255
#define MAXIMUM_TABLE_NAME_LEN 255
#define MAXIMUM_COLUMN_NAME_LEN 255
#define MAXIMUM_BUFFER_SIZE 8192

#define SQLTABLES_SCHEMA_COLUMN 2
#define SQLTABLES_NAME_COLUMN 3

#define ODBC_SQLSTATE_FRACTIONAL_TRUNCATION "01S07"
#define ODBC_SQLSTATE_STRING_TRUNCATION "01004"
#define ODBC_SQLSTATE_BQ_TRUNCATION "01000"
#define ODBC_SQLSTATE_LENGTH 5

typedef enum { NO_TRUNCATION, FRACTIONAL_TRUNCATION, STRING_TRUNCATION } GetDataTruncation;
typedef enum { TEXT_CONVERSION, BIN_CONVERSION, BOOL_CONVERSION } ColumnConversion;

typedef struct odbcFdwOptions
{
	char  *schema;
	char  *table;
	char  *prefix;
	char  *sql_query;
	char  *sql_count;
	char  *encoding;
	int64 max_field_size;
	int64 max_row_count;
	int64 max_result_size;
	List *connection_list;
	List *mapping_list;
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
	int64           row_count;
	int64           result_bytes;
	char            *query;
	List            *col_position_mask;
	List            *col_size_array;
	List            *col_conversion_array;
	char            *sql_count;
	int             encoding;
} odbcFdwExecutionState;

/* SQL-callable entry points, declared here for every compilation unit. */
extern PGDLLEXPORT Datum odbc_fdw_handler(PG_FUNCTION_ARGS);
extern PGDLLEXPORT Datum odbc_fdw_validator(PG_FUNCTION_ARGS);
extern PGDLLEXPORT Datum odbc_tables_list(PG_FUNCTION_ARGS);
extern PGDLLEXPORT Datum odbc_table_size(PG_FUNCTION_ARGS);
extern PGDLLEXPORT Datum odbc_query_size(PG_FUNCTION_ARGS);

static inline bool
is_blank_string(const char *s)
{
	return s == NULL || s[0] == '\0';
}

/* FDW callbacks registered by odbc_fdw_handler. */
extern void odbcExplainForeignScan(ForeignScanState *node, ExplainState *es);
extern void odbcBeginForeignScan(ForeignScanState *node, int eflags);
extern TupleTableSlot *odbcIterateForeignScan(ForeignScanState *node);
extern void odbcReScanForeignScan(ForeignScanState *node);
extern void odbcEndForeignScan(ForeignScanState *node);
extern void odbcGetForeignRelSize(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid);
extern void odbcEstimateCosts(PlannerInfo *root, RelOptInfo *baserel, Cost *startup_cost, Cost *total_cost, Oid foreigntableid);
extern void odbcGetForeignPaths(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid);
extern bool odbcAnalyzeForeignTable(Relation relation, AcquireSampleRowsFunc *func, BlockNumber *totalpages);
extern ForeignScan *odbcGetForeignPlan(PlannerInfo *root, RelOptInfo *baserel,
	Oid foreigntableid, ForeignPath *best_path, List *tlist, List *scan_clauses,
	Plan *outer_plan);
extern List *odbcImportForeignSchema(ImportForeignSchemaStmt *stmt, Oid serverOid);

/* Option parsing and type mapping. */
extern void init_odbcFdwOptions(odbcFdwOptions *options);
extern void copy_odbcFdwOptions(odbcFdwOptions *to, odbcFdwOptions *from);
extern const char *empty_string_if_null(char *string);
extern void extract_odbcFdwOptions(List *options_list, odbcFdwOptions *extracted_options);
extern void odbcGetOptions(Oid server_oid, List *add_options, odbcFdwOptions *extracted_options);
extern void odbcGetTableOptions(Oid foreigntableid, odbcFdwOptions *extracted_options);
extern void sql_data_type(SQLSMALLINT odbc_data_type, SQLULEN column_size,
	SQLSMALLINT decimal_digits, SQLSMALLINT nullable, StringInfo sql_type);
extern SQLULEN minimum_buffer_size(SQLSMALLINT odbc_data_type);
extern const char *get_odbc_attribute_name(const char *defname);

/* ODBC connection and SQL helpers. */
extern void odbc_connection(odbcFdwOptions *options, SQLHENV *env, SQLHDBC *dbc);
extern void odbc_disconnection(SQLHENV *env, SQLHDBC *dbc);
extern void odbc_allocate_statement(SQLHDBC dbc, SQLHSTMT *stmt);
extern void check_return(SQLRETURN ret, char *msg, SQLHANDLE handle, SQLSMALLINT type);
extern void odbcGetTableSize(odbcFdwOptions *options, unsigned int *size);
extern void getNameQualifierChar(SQLHDBC dbc, StringInfoData *nq_char);
extern void getQuoteChar(SQLHDBC dbc, StringInfoData *q_char);
extern char *get_schema_name(odbcFdwOptions *options);
extern char *escape_sql_literal(const char *value);
extern char *escape_sql_identifier_part(const char *value, const char *quote_char);

#endif /* ODBC_FDW_H */
