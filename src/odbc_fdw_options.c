/*----------------------------------------------------------
 *
 *        Option definitions, validation and extraction.
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
 *----------------------------------------------------------
 */

#include "odbc_fdw.h"

static bool odbcIsValidOption(const char *option, Oid context);
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

void
init_odbcFdwOptions(odbcFdwOptions* options)
{
	memset(options, 0, sizeof(odbcFdwOptions));
}

void
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
const char *
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

const char *
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

void
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
void
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
	case SQL_BOOLEAN :
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

SQLULEN
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
void
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
void
odbcGetTableOptions(Oid foreigntableid, odbcFdwOptions *extracted_options)
{
	ForeignTable    *table;

	elog_debug("%s", __func__);

	table = GetForeignTable(foreigntableid);
	odbcGetOptions(table->serverid, table->options, extracted_options);
}

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
