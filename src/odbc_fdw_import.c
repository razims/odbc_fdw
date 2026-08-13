/*----------------------------------------------------------
 *
 *        IMPORT FOREIGN SCHEMA support.
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
	/*
	 * The old "TODO: review memory management in this function; any leaks?"
	 * has been answered: yes, three, all of which grew with the size of the
	 * remote rather than being constant per statement -- a StringInfo per
	 * column in sql_data_type, a column-name buffer per table, and a table-name
	 * buffer per excluded table. Those are fixed. What remains is a handful of
	 * once-per-statement allocations released when this utility statement's
	 * context goes away, which is the right lifetime for them.
	 */
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

	/*
	 * Once for the whole import, not once per column: sql_data_type resets this
	 * rather than initialising it. Both branches below describe columns, and
	 * they are mutually exclusive, so one initialisation here covers both.
	 */
	initStringInfo(&sql_type);

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

		/* Allocate a statement handle. */
		odbc_allocate_statement(dbc, &query_stmt);

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

			/* Allocate a statement handle. */
			odbc_allocate_statement(dbc, &tables_stmt);

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
						/*
						 * schema_name may be NULL, and strcmp against NULL is a
						 * SIGSEGV -- which does not stop at this backend:
						 * HandleChildCrash SIGQUITs every other one and the
						 * instance replays WAL, so every session in every
						 * database on the host is taken into crash recovery.
						 *
						 * Two ways to arrive here with it NULL. The documented
						 * one is OPTIONS (schema ''), which the branch near the
						 * top of this function turns into NULL on purpose, for
						 * schema-less sources such as Hive -- against a remote
						 * that DOES report schemas, the first enumerated table
						 * then crashes the instance. The other is this loop's
						 * own error handling a few lines below, which sets
						 * schema_name = NULL when SQLGetData fails for one
						 * row's schema column; the next iteration reaches this
						 * comparison with it NULL. A blank schema cannot be
						 * matched against anything, so treat "we have no schema
						 * to filter by" as excluding nothing, which is what the
						 * NULL assignment below already intends.
						 */
						if (schema_name != NULL &&
						    !is_blank_string((char*)table_schema) &&
						    strcmp((char*)table_schema, schema_name) )
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
					else
					{
						/* Nothing holds an excluded name; it grew with the
						 * remote's table count. */
						pfree(TableName);
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
		/*
		 * One buffer for the whole loop. It was allocated per table and never
		 * freed, so the cost grew with the number of tables imported; every
		 * column overwrites it anyway, so there was never anything to keep.
		 */
		ColumnName = (SQLCHAR *) palloc(sizeof(SQLCHAR) * MAXIMUM_COLUMN_NAME_LEN);
		foreach(tables_cell, tables)
		{
			char *table_name = (char*)lfirst(tables_cell);

			/* Allocate a statement handle. */
			odbc_allocate_statement(dbc, &columns_stmt);

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
