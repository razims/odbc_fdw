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
 * ODBC handle lifetime.
 *
 * SQLHENV and SQLHDBC are driver-manager allocations, not palloc'd memory, so
 * nothing PostgreSQL does when a statement, a query context or a transaction
 * ends releases them. odbcEndForeignScan was the only place they were freed,
 * and the executor does NOT call it when a scan errors: PortalCleanup skips
 * ExecutorEnd for a failed portal. So every error raised from inside a scan
 * abandoned an environment handle, a connection handle and the remote session
 * behind it for the life of the backend -- and the ceilings this extension
 * added are the most reliable way to reach that path, because raising is what
 * they are for. Cancellation and any driver error do it too.
 *
 * Measured before this change with the credential-free loopback harness in
 * docker/run-local-tests.sh: twenty scans refused by max_row_count left twenty
 * additional client backends on the remote database, counted from inside the
 * same session while it was still holding them. Connection pooling makes it
 * worse, because the backend outlives the client whose query caused the scan.
 *
 * So every handle pair this extension allocates is recorded here, and the list
 * is emptied when the transaction that created the entry ends -- however it
 * ends. Same shape as postgres_fdw's pgfdw_xact_callback, minus the connection
 * cache: that has connections worth keeping between transactions, and this does
 * not, because a connection here never outlives its scan.
 *
 * The list lives in TopMemoryContext because it has to survive the destruction
 * of every memory context a scan used, which is precisely the event it exists
 * to clean up after.
 *
 * This bounds OUR handles and the sessions behind them. It is not a process
 * boundary: the driver still runs inside the backend, and a fault in it is
 * still a SIGSEGV that takes the whole instance into crash recovery.
 */
typedef struct odbcConnEntry
{
	SQLHENV  env;
	SQLHDBC  dbc;
	SubTransactionId subxid; /* Current subtransaction when claimed */
	struct odbcConnEntry *next;
} odbcConnEntry;

static odbcConnEntry *odbc_live_connections = NULL;
static bool odbc_xact_callback_registered = false;
static bool odbc_subxact_callback_registered = false;

/*
 * Free one connection and its environment. NOTHING HERE MAY ereport.
 *
 * This runs from odbc_disconnection on the ordinary path and from the
 * transaction callbacks on the abort path, and an error raised while a
 * transaction is aborting re-enters AbortTransaction, which is a PANIC that
 * takes the instance down -- a considerably worse outcome than the leak. A
 * failed disconnect is not actionable in any case: the handles must be released
 * either way, and refusing to release them because the remote has already gone
 * away is exactly the behaviour that leaked them. Return codes are therefore
 * read and discarded.
 *
 * SQLDisconnect frees any statement handles still allocated on the connection,
 * which is what odbc_tables_list has always relied on.
 */
static void
odbc_release_handles(SQLHENV env, SQLHDBC dbc)
{
	if (dbc != SQL_NULL_HANDLE)
	{
		(void) SQLDisconnect(dbc);
		(void) SQLFreeHandle(SQL_HANDLE_DBC, dbc);
	}
	/*
	 * Not nested inside the dbc arm. It used to be, so a connection handle that
	 * was never allocated orphaned the environment handle that was.
	 */
	if (env != SQL_NULL_HANDLE)
		(void) SQLFreeHandle(SQL_HANDLE_ENV, env);
}

/*
 * Release every recorded connection when the top-level transaction ends.
 */
static void
odbc_release_connections(void)
{
	odbcConnEntry **link = &odbc_live_connections;

	while (*link != NULL)
	{
		odbcConnEntry *entry = *link;

		*link = entry->next;
		odbc_release_handles(entry->env, entry->dbc);
		pfree(entry);
	}
}

/* Release entries owned by the subtransaction that just aborted. */
static void
odbc_release_subxact_connections(SubTransactionId subxid)
{
	odbcConnEntry **link = &odbc_live_connections;

	while (*link != NULL)
	{
		odbcConnEntry *entry = *link;

		if (entry->subxid == subxid)
		{
			*link = entry->next;
			odbc_release_handles(entry->env, entry->dbc);
			pfree(entry);
		}
		else
			link = &entry->next;
	}
}

static void
odbc_xact_callback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_COMMIT:
		case XACT_EVENT_ABORT:
		case XACT_EVENT_PREPARE:
		case XACT_EVENT_PARALLEL_COMMIT:
		case XACT_EVENT_PARALLEL_ABORT:
			/*
			 * On COMMIT the list is normally already empty: PreCommit_Portals
			 * runs ExecutorEnd -- including for WITH HOLD cursors, which it
			 * materialises first -- before these callbacks fire, so
			 * odbcEndForeignScan has already had its chance. That arm is a
			 * backstop for a path that forgot to disconnect, not the expected
			 * route. ABORT is the one that matters.
			 */
			odbc_release_connections();
			break;
		default:
			break;
	}
}

static void
odbc_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
                      SubTransactionId parentSubid, void *arg)
{
	if (event != SUBXACT_EVENT_ABORT_SUB && event != SUBXACT_EVENT_PRE_COMMIT_SUB)
		return;

	if (event == SUBXACT_EVENT_ABORT_SUB)
	{
		/*
		 * A PL/pgSQL BEGIN ... EXCEPTION block around a scan is an ordinary
		 * shape, and it aborts a SUBtransaction rather than the transaction --
		 * so a hook hung only on the transaction would not fire until the outer
		 * one ended, and a loop of them would hold one remote session per
		 * iteration until then. Measured with a 100-iteration loop.
		 */
		odbc_release_subxact_connections(mySubid);
	}
	else
	{
		/*
		 * PRE_COMMIT is deliberately used rather than COMMIT: after commit,
		 * GetCurrentTransactionNestLevel() already names the parent. Match the
		 * exact subtransaction ID instead, so a sibling or parent connection
		 * can never be adopted accidentally.
		 */
		odbcConnEntry *entry;

		for (entry = odbc_live_connections; entry != NULL; entry = entry->next)
		{
			if (entry->subxid == mySubid)
				entry->subxid = parentSubid;
		}
	}
}

/*
 * Claim a slot BEFORE the first handle exists.
 *
 * Deliberately not after: SQLDriverConnect is the call that usually fails, and
 * by the time it is reached both handles are already allocated. Recording them
 * first means there is no instant at which a handle exists unrecorded, so every
 * failure below can simply throw and let the callbacks clean up.
 */
static odbcConnEntry *
odbc_claim_connection_slot(void)
{
	odbcConnEntry *entry;

	/*
	 * One flag per registration, each set immediately after its own call.
	 *
	 * Not one flag for both: Register*Callback palloc's, so the second can throw
	 * while the first has already taken effect. A single flag would still be
	 * false, and the next attempt would register the FIRST callback a second
	 * time, leaving two copies installed for the life of the backend. Harmless
	 * as it happens -- the second odbc_release_connections finds an
	 * already-drained list -- but a flag that claims "registered exactly once"
	 * should not be able to lie, and there is no way to unregister.
	 */
	if (!odbc_xact_callback_registered)
	{
		RegisterXactCallback(odbc_xact_callback, NULL);
		odbc_xact_callback_registered = true;
	}
	if (!odbc_subxact_callback_registered)
	{
		RegisterSubXactCallback(odbc_subxact_callback, NULL);
		odbc_subxact_callback_registered = true;
	}

	entry = (odbcConnEntry *) MemoryContextAlloc(TopMemoryContext,
	                                             sizeof(odbcConnEntry));
	entry->env = SQL_NULL_HANDLE;
	entry->dbc = SQL_NULL_HANDLE;
	entry->subxid = GetCurrentSubTransactionId();
	entry->next = odbc_live_connections;
	odbc_live_connections = entry;

	return entry;
}

/* Allocate a statement with a useful connection diagnostic on failure. */
void
odbc_allocate_statement(SQLHDBC dbc, SQLHSTMT *stmt)
{
	SQLRETURN ret;

	*stmt = SQL_NULL_HANDLE;
	ret = SQLAllocHandle(SQL_HANDLE_STMT, dbc, stmt);
	check_return(ret, "Allocating ODBC statement handle", dbc, SQL_HANDLE_DBC);
}

static void
odbc_forget_entry(odbcConnEntry *target)
{
	odbcConnEntry **link = &odbc_live_connections;

	while (*link != NULL)
	{
		if (*link == target)
		{
			*link = target->next;
			pfree(target);
			return;
		}
		link = &(*link)->next;
	}
}

static odbcConnEntry *
odbc_find_connection(SQLHENV env, SQLHDBC dbc)
{
	odbcConnEntry *entry;

	for (entry = odbc_live_connections; entry != NULL; entry = entry->next)
	{
		if (entry->env == env && entry->dbc == dbc)
			return entry;
	}
	return NULL;
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
	odbcConnEntry *entry;

	odbcConnStr(&conn_str, options);

	*env = SQL_NULL_HANDLE;
	*dbc = SQL_NULL_HANDLE;
	entry = odbc_claim_connection_slot();

	/*
	 * The SQLAllocHandle returns were not checked. A failure left the handle
	 * variable holding whatever the driver manager did or did not write, and
	 * every call below was made against it.
	 */
	ret = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, env);
	if (!SQL_SUCCEEDED(ret))
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
		         errmsg("odbc_fdw: could not allocate an ODBC environment handle")));
	entry->env = *env;

	/* We want ODBC 3 support */
	ret = SQLSetEnvAttr(*env, SQL_ATTR_ODBC_VERSION, (void *) SQL_OV_ODBC3, 0);
	check_return(ret, "Setting ODBC environment version", *env, SQL_HANDLE_ENV);

	/* Allocate a connection handle */
	ret = SQLAllocHandle(SQL_HANDLE_DBC, *env, dbc);
	if (!SQL_SUCCEEDED(ret))
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_UNABLE_TO_ESTABLISH_CONNECTION),
		         errmsg("odbc_fdw: could not allocate an ODBC connection handle")));
	entry->dbc = *dbc;

	/* Connect to the DSN */
	ret = SQLDriverConnect(*dbc, NULL, (SQLCHAR *) conn_str.data, SQL_NTS,
	                       OutConnStr, 1024, &OutConnStrLen, SQL_DRIVER_COMPLETE);
	/*
	 * `*dbc`, not `dbc`. This passed the ADDRESS of the handle, and SQLHANDLE
	 * is void * so it compiled silently -- handing the driver manager a stack
	 * address where it expected a connection handle. The visible effect was
	 * that every connection failure reported a bare "Connecting to driver"
	 * with no driver diagnostic attached, because the diagnostic records were
	 * being read from something that was not the handle. odbc_disconnection
	 * always got this right on the identical call.
	 */
	check_return(ret, "Connecting to driver", *dbc, SQL_HANDLE_DBC);
	elog_debug("Connection opened");
}

/*
 * Close the ODBC connection
 */
void
odbc_disconnection(SQLHENV *env, SQLHDBC *dbc)
{
	odbcConnEntry *entry = odbc_find_connection(*env, *dbc);

	/*
	 * Absent from the registry means these handles have ALREADY been released --
	 * by the transaction callbacks, or by an earlier disconnection -- and what
	 * the caller still holds is dangling. odbc_connection is the only thing that
	 * opens a connection and it always registers one, so this is a reliable
	 * test, and honouring it is what stops a double release from becoming a
	 * use-after-free inside the driver manager.
	 *
	 * The ordering says this should not arise today: AtAbort_Portals runs before
	 * CallXactCallbacks, so odbcEndForeignScan has either already run or been
	 * skipped altogether by then. It is guarded rather than asserted because the
	 * cost of that reasoning being wrong is a corrupted driver heap, which is
	 * the failure mode this whole change exists to remove.
	 */
	if (entry != NULL)
	{
		odbc_forget_entry(entry);
		odbc_release_handles(*env, *dbc);
	}

	/* Clear the caller's copies so a second call is a no-op either way. */
	*env = SQL_NULL_HANDLE;
	*dbc = SQL_NULL_HANDLE;

	elog_debug("Connection closed");
}

/*
 * Validate function
 */
#define MAX_ERROR_MSG_LENGTH 8192

void
check_return(SQLRETURN ret, const char *msg, SQLHANDLE handle, SQLSMALLINT type)
{
	SQLINTEGER   i = 0;
	SQLINTEGER   native;
	SQLCHAR  state[ 7 ];
	SQLCHAR  text[256];
	SQLSMALLINT  len;
	SQLRETURN    diag_ret;
	StringInfoData error_msg;
	int err_code = ERRCODE_SYSTEM_ERROR;

	if (SQL_SUCCEEDED(ret))
		return;

	initStringInfo(&error_msg);
	appendStringInfoString(&error_msg, msg);

	#ifdef DEBUG
	elog(DEBUG1, "Error result (%d): %s", ret, error_msg.data);
	#endif
	if (handle)
	{
		for (;;)
		{
			memset(state, 0, sizeof(state));
			memset(text, 0, sizeof(text));
			diag_ret = SQLGetDiagRec(type, handle, ++i, state, &native, text,
				                         sizeof(text), &len);
			if (diag_ret == SQL_NO_DATA)
				break;
			if (!SQL_SUCCEEDED(diag_ret))
				break;

			#ifdef DEBUG
			elog(DEBUG1, " %s:%ld:%ld:%s\n", state, (long int) i, (long int) native, text);
			#endif
			if (error_msg.len < MAX_ERROR_MSG_LENGTH)
			{
				int remaining = MAX_ERROR_MSG_LENGTH - error_msg.len;

				appendStringInfoChar(&error_msg, '\n');
				if (remaining > 1)
					appendBinaryStringInfo(&error_msg, (char *) text,
					                       Min((int) strnlen((char *) text,
					                                         sizeof(text) - 1),
					                           remaining - 1));
			}
		}
	}
	ereport(ERROR, (errcode(err_code), errmsg("%s", error_msg.data)));
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
	SQLSMALLINT info_len = 0;
	SQLRETURN ret;

	elog_debug("%s", __func__);

	ret = SQLGetInfo(dbc,
	                 SQL_CATALOG_NAME_SEPARATOR,
	                 (SQLPOINTER)&name_qualifier_char,
	                 sizeof(name_qualifier_char),
	                 &info_len);
	check_return(ret, "Reading ODBC catalog separator", dbc, SQL_HANDLE_DBC);
	if (info_len > 1)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("ODBC driver returned a multi-byte catalog separator")));
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
	/*
	 * Zero-initialised, for the same reason getNameQualifierChar above is:
	 * SQLGetInfo leaves this untouched if it fails, and quote_char[0] is used
	 * either way. That byte then wraps every schema, table and column name in
	 * every query sent to the remote, and is handed to
	 * escape_sql_identifier_part as the character to double -- so a garbage
	 * value read off the stack does not merely mangle a name, it decides what
	 * escaping is applied to it.
	 */
	SQLCHAR quote_char[2] = {0, 0};
	SQLSMALLINT info_len = 0;
	SQLRETURN ret;

	elog_debug("%s", __func__);

	ret = SQLGetInfo(dbc,
	                 SQL_IDENTIFIER_QUOTE_CHAR,
	                 (SQLPOINTER)&quote_char,
	                 sizeof(quote_char),
	                 &info_len);
	check_return(ret, "Reading ODBC identifier quote character", dbc,
	             SQL_HANDLE_DBC);
	if (info_len != 1 || quote_char[0] == ' ')
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("ODBC driver does not report a usable identifier quote character")));
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
odbcGetTableSize(odbcFdwOptions* options, SQLUBIGINT *size)
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

	/* Allocate a statement handle. */
	odbc_allocate_statement(dbc, &stmt);

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
			char *query = pstrdup(options->sql_query);
			size_t query_len = strlen(query);

			/* Strip a trailing terminator from our private copy, not the option. */
			if (query_len > 0 && query[query_len - 1] == ';')
				query[query_len - 1] = '\0';
			appendStringInfo(&sql_str,
			                 "SELECT COUNT(*) FROM (%s) AS _odbc_fwd_count_wrapped",
			                 query);
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

	ret = SQLFetch(stmt);
	check_return(ret, "Fetching ODBC table size", stmt, SQL_HANDLE_STMT);

	/* Retrieve the count without narrowing it to the platform's unsigned int. */
	ret = SQLGetData(stmt, 1, SQL_C_UBIGINT, &table_size,
	                 sizeof(table_size), &indicator);
	check_return(ret, "Reading ODBC table size", stmt, SQL_HANDLE_STMT);
	if (indicator == SQL_NULL_DATA)
		ereport(ERROR,
		        (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
		         errmsg("ODBC count query returned NULL")));

	*size = table_size;
	elog_debug("Count query result: %llu", (unsigned long long) table_size);

	/* Free handles, and disconnect */
	if (stmt)
	{
		SQLFreeHandle(SQL_HANDLE_STMT, stmt);
		stmt = NULL;
	}
	odbc_disconnection(&env, &dbc);
}

static Oid
oid_from_server_name(const char *serverName)
{
	ForeignServer *server = GetForeignServerByName(serverName, false);
	AclResult aclresult;

#if PG_VERSION_NUM >= 160000
	aclresult = object_aclcheck(ForeignServerRelationId, server->serverid,
	                            GetUserId(), ACL_USAGE);
#else
	aclresult = pg_foreign_server_aclcheck(server->serverid, GetUserId(),
	                                       ACL_USAGE);
#endif
	if (aclresult != ACLCHECK_OK)
		aclcheck_error(aclresult, OBJECT_FOREIGN_SERVER, serverName);

	return server->serverid;
}

Datum
odbc_table_size(PG_FUNCTION_ARGS)
{
	char *serverName = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char *tableName = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char *defname = "table";
	/*
	 * Initialised, because odbcGetTableSize assigns *size only when both
	 * SQLExecDirect and SQLGetData succeed -- the SQLFetch between them is not
	 * checked at all -- so a count query returning no row left this holding
	 * whatever was on the stack and returned it. The two internal callers in
	 * odbc_fdw_scan.c have always initialised to 0; these two had not.
	 */
	SQLUBIGINT tableSize = 0;
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
	if (tableSize > PG_INT32_MAX)
		ereport(ERROR,
		        (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
		         errmsg("ODBC table row count exceeds integer range")));

	PG_RETURN_INT32((int32) tableSize);
}

Datum
odbc_query_size(PG_FUNCTION_ARGS)
{
	char *serverName = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char *sqlQuery = text_to_cstring(PG_GETARG_TEXT_PP(1));
	char *defname = "sql_query";
	/* Initialised for the reason given in odbc_table_size above. */
	SQLUBIGINT querySize = 0;
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
	if (querySize > PG_INT32_MAX)
		ereport(ERROR,
		        (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
		         errmsg("ODBC query row count exceeds integer range")));

	PG_RETURN_INT32((int32) querySize);
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
	DataBinding* tableResult;
	SQLHENV env;
	SQLHDBC dbc;
	SQLHSTMT stmt;
	int32 rowLimit;
	uint64 currentRow;
} TableDataCtx;


Datum odbc_tables_list(PG_FUNCTION_ARGS)
{
	SQLHENV env;
	SQLHDBC dbc;
	SQLHSTMT stmt;
	SQLUSMALLINT i;
	SQLUSMALLINT numColumns = 5;
	SQLUSMALLINT bufferSize = 1024;
	int32 rowLimit;
	uint64 currentRow;
	SQLRETURN retCode;

	FuncCallContext *funcctx;
	TupleDesc tupdesc;
	TableDataCtx *datafctx;
	DataBinding* tableResult;
	AttInMetadata *attinmeta;

	if (SRF_IS_FIRSTCALL()) {
		MemoryContext oldcontext;
		char *serverName;
		Oid serverOid;
		odbcFdwOptions options;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
		datafctx = (TableDataCtx *) palloc0(sizeof(TableDataCtx));
		tableResult = (DataBinding*) palloc0(numColumns * sizeof(DataBinding));

		serverName = text_to_cstring(PG_GETARG_TEXT_PP(0));
		serverOid = oid_from_server_name(serverName);

		rowLimit = PG_GETARG_INT32(1);
		if (rowLimit < 0)
			ereport(ERROR,
			        (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
			         errmsg("row limit must not be negative")));
		currentRow = 0;

		odbcGetOptions(serverOid, NULL, &options);
		odbc_connection(&options, &env, &dbc);
		odbc_allocate_statement(dbc, &stmt);

		for ( i = 0 ; i < numColumns ; i++ ) {
			tableResult[i].TargetType = SQL_C_CHAR;
			tableResult[i].BufferLength = (bufferSize + 1);
			tableResult[i].TargetValuePtr = palloc( sizeof(char)*tableResult[i].BufferLength );
		}

		for ( i = 0 ; i < numColumns ; i++ ) {
			retCode = SQLBindCol(stmt, i + 1, tableResult[i].TargetType, tableResult[i].TargetValuePtr, tableResult[i].BufferLength, &(tableResult[i].StrLen_or_Ind));
			check_return(retCode, "Binding SQLTables result column", stmt,
			             SQL_HANDLE_STMT);
		}

		retCode = SQLTables(stmt, NULL, 0, NULL, 0, NULL, 0,
		                    (SQLCHAR *) "TABLE", SQL_NTS);
		check_return(retCode, "Listing ODBC tables", stmt, SQL_HANDLE_STMT);

		if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
			ereport(ERROR,
			        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			         errmsg("function returning record called in context "
			                "that cannot accept type record")));

		attinmeta = TupleDescGetAttInMetadata(tupdesc);

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

	if (rowLimit == 0 || currentRow < (uint64) rowLimit)
		retCode = SQLFetch(stmt);
	else
		retCode = SQL_NO_DATA;

	if (SQL_SUCCEEDED(retCode)) {
		char       **values;
		HeapTuple    tuple;
		Datum        result;

		if (tableResult[SQLTABLES_SCHEMA_COLUMN - 1].StrLen_or_Ind >=
		    tableResult[SQLTABLES_SCHEMA_COLUMN - 1].BufferLength ||
		    tableResult[SQLTABLES_NAME_COLUMN - 1].StrLen_or_Ind >=
		    tableResult[SQLTABLES_NAME_COLUMN - 1].BufferLength)
			ereport(ERROR,
			        (errcode(ERRCODE_NAME_TOO_LONG),
			         errmsg("ODBC table metadata exceeds the result buffer")));

		values = (char **) palloc0(2 * sizeof(char *));
		if (tableResult[SQLTABLES_SCHEMA_COLUMN - 1].StrLen_or_Ind != SQL_NULL_DATA)
			values[0] = (char *) tableResult[SQLTABLES_SCHEMA_COLUMN - 1].TargetValuePtr;
		if (tableResult[SQLTABLES_NAME_COLUMN - 1].StrLen_or_Ind != SQL_NULL_DATA)
			values[1] = (char *) tableResult[SQLTABLES_NAME_COLUMN - 1].TargetValuePtr;
		tuple = BuildTupleFromCStrings(attinmeta, values);
		result = HeapTupleGetDatum(tuple);
		currentRow++;
		datafctx->currentRow = currentRow;
		SRF_RETURN_NEXT(funcctx, result);
	} else {
		if (retCode != SQL_NO_DATA)
			check_return(retCode, "Fetching SQLTables result", stmt,
			             SQL_HANDLE_STMT);
		SQLFreeHandle(SQL_HANDLE_STMT, datafctx->stmt);
		datafctx->stmt = SQL_NULL_HSTMT;
		odbc_disconnection(&datafctx->env, &datafctx->dbc);
		SRF_RETURN_DONE(funcctx);
	}
}

/*
 * get quals in the select if there is one
 */
