#include <sql.h>
#include <sqlext.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
die(const char *message)
{
	fprintf(stderr, "ODBC executor: %s\n", message);
	exit(EXIT_FAILURE);
}

static const char *
connection_string(void)
{
	const char *value = getenv("ODBC_TEST_CONNECTION_STRING");

	if (value == NULL || value[0] == '\0')
		die("ODBC_TEST_CONNECTION_STRING is not set");
	return value;
}

static void
print_diagnostic(SQLSMALLINT handle_type, SQLHANDLE handle, unsigned statement)
{
	SQLCHAR state[6] = "00000";
	SQLINTEGER native_error = 0;
	SQLCHAR message[1];
	SQLSMALLINT ignored;

	(void) SQLGetDiagRec(handle_type, handle, 1, state, &native_error, message,
					 sizeof(message), &ignored);
	fprintf(stderr,
			"ODBC executor: statement %u failed (SQLSTATE %.5s, native error %ld)\n",
			statement, state, (long) native_error);
}

static int
has_sql(const char *sql)
{
	while (*sql != '\0')
	{
		if (!isspace((unsigned char) *sql))
			return 1;
		++sql;
	}
	return 0;
}

static char *
read_sql(void)
{
	size_t capacity = 4096;
	size_t length = 0;
	char *sql = malloc(capacity);
	int c;

	if (sql == NULL)
		die("could not allocate SQL buffer");
	while ((c = fgetc(stdin)) != EOF)
	{
		if (length + 1 == capacity)
		{
			char *grown;

			capacity *= 2;
			grown = realloc(sql, capacity);
			if (grown == NULL)
			{
				free(sql);
				die("could not grow SQL buffer");
			}
			sql = grown;
		}
		sql[length++] = (char) c;
	}
	if (ferror(stdin))
	{
		free(sql);
		die("could not read SQL from standard input");
	}
	sql[length] = '\0';
	return sql;
}

static void
execute_batch(SQLHDBC dbc, char *sql)
{
	int single_quote = 0;
	int double_quote = 0;
	int backtick_quote = 0;
	int line_comment = 0;
	unsigned statement = 1;
	char *start = sql;
	char *cursor;

	for (cursor = sql;; ++cursor)
	{
		char c = *cursor;

		if (line_comment)
		{
			if (c == '\n' || c == '\0')
				line_comment = 0;
		}
		else if (!single_quote && !double_quote && !backtick_quote &&
				 c == '-' && cursor[1] == '-')
		{
			line_comment = 1;
			++cursor;
		}
		else if (!double_quote && !backtick_quote && c == '\'')
		{
			if (single_quote && cursor[1] == '\'')
				++cursor;
			else
				single_quote = !single_quote;
		}
		else if (!single_quote && !backtick_quote && c == '"')
		{
			if (double_quote && cursor[1] == '"')
				++cursor;
			else
				double_quote = !double_quote;
		}
		else if (!single_quote && !double_quote && c == '`')
		{
			if (backtick_quote && cursor[1] == '`')
				++cursor;
			else
				backtick_quote = !backtick_quote;
		}

		if ((c == ';' && !single_quote && !double_quote && !backtick_quote &&
			 !line_comment) || c == '\0')
		{
			SQLHSTMT stmt;
			SQLRETURN rc;

			*cursor = '\0';
			if (has_sql(start))
			{
				rc = SQLAllocHandle(SQL_HANDLE_STMT, dbc, &stmt);
				if (!SQL_SUCCEEDED(rc))
					die("could not allocate statement handle");
				rc = SQLExecDirect(stmt, (SQLCHAR *) start, SQL_NTS);
				if (!SQL_SUCCEEDED(rc))
				{
					print_diagnostic(SQL_HANDLE_STMT, stmt, statement);
					SQLFreeHandle(SQL_HANDLE_STMT, stmt);
					exit(EXIT_FAILURE);
				}
				SQLFreeHandle(SQL_HANDLE_STMT, stmt);
				++statement;
			}
			start = cursor + 1;
		}
		if (c == '\0')
			break;
	}
}

int
main(void)
{
	const char *connection = connection_string();
	char *sql = read_sql();
	SQLHENV env;
	SQLHDBC dbc;
	SQLRETURN rc;

	rc = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &env);
	if (!SQL_SUCCEEDED(rc))
		die("could not allocate ODBC environment");
	rc = SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, (void *) SQL_OV_ODBC3, 0);
	if (!SQL_SUCCEEDED(rc))
		die("could not select ODBC 3");
	rc = SQLAllocHandle(SQL_HANDLE_DBC, env, &dbc);
	if (!SQL_SUCCEEDED(rc))
		die("could not allocate ODBC connection");
	(void) SQLSetConnectAttr(dbc, SQL_LOGIN_TIMEOUT, (SQLPOINTER) 15, 0);
	rc = SQLDriverConnect(dbc, NULL, (SQLCHAR *) connection, SQL_NTS,
					  NULL, 0, NULL, SQL_DRIVER_NOPROMPT);
	if (!SQL_SUCCEEDED(rc))
	{
		print_diagnostic(SQL_HANDLE_DBC, dbc, 0);
		return EXIT_FAILURE;
	}

	execute_batch(dbc, sql);
	SQLDisconnect(dbc);
	SQLFreeHandle(SQL_HANDLE_DBC, dbc);
	SQLFreeHandle(SQL_HANDLE_ENV, env);
	free(sql);
	return EXIT_SUCCESS;
}
