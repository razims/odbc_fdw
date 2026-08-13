/*----------------------------------------------------------
 *
 *        ODBC connections and catalog helpers.
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

static void odbcConnStr(StringInfoData *conn_str, odbcFdwOptions *options);
/*
 * Escape a value for safe use inside a single-quoted SQL string literal,
 * by doubling every embedded single-quote character (the standard SQL
 * escaping rule, e.g. "O'Brien" -> "O''Brien"). Returns a freshly palloc'd,
 * NUL-terminated string; safe to call with value == NULL (returns "").
 *
 * This must be used for every value that gets interpolated into a SQL
 * string sent to the remote ODBC data source, to avoid SQL injection.
 */
char *
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
char *
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

/*
 * Get the schema name from the options
 */
char *
get_schema_name(odbcFdwOptions *options)
{
	return options->schema;
}

/*
 * Establish ODBC connection
 */
void
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
void
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
#define MAX_ERROR_MSG_LENGTH 512
#define ERROR_MSG_SEP "\n"

void
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
void
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
void
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
void
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
