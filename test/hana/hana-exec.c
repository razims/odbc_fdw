#include <sql.h>
#include <sqlext.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
die(const char *message)
{
	fprintf(stderr, "HANA executor: %s\n", message);
	exit(EXIT_FAILURE);
}

static const char *
required_env(const char *name)
{
	const char *value = getenv(name);

	if (value == NULL || value[0] == '\0' || strcmp(value, "replace-me") == 0)
	{
		fprintf(stderr, "HANA executor: set %s in .env before running\n", name);
		exit(EXIT_FAILURE);
	}
	return value;
}

static void
append_value(char **cursor, size_t *remaining, const char *value)
{
	if (*remaining < 3)
		die("connection string is too long");
	*(*cursor)++ = '{';
	--*remaining;
	for (; *value != '\0'; ++value)
	{
		if (*remaining < 2)
			die("connection string is too long");
		*(*cursor)++ = *value;
		--*remaining;
		if (*value == '}')
		{
			*(*cursor)++ = '}';
			--*remaining;
		}
	}
	*(*cursor)++ = '}';
	--*remaining;
	**cursor = '\0';
}

static void
append_option(char **cursor, size_t *remaining, const char *name, const char *value)
{
	int written = snprintf(*cursor, *remaining, "%s=", name);

	if (written < 0 || (size_t) written >= *remaining)
		die("connection string is too long");
	*cursor += written;
	*remaining -= (size_t) written;
	append_value(cursor, remaining, value);
	if (*remaining < 2)
		die("connection string is too long");
	*(*cursor)++ = ';';
	--*remaining;
	**cursor = '\0';
}

static SQLINTEGER
diagnostic(SQLSMALLINT handle_type, SQLHANDLE handle, SQLCHAR state[6])
{
	SQLINTEGER native_error = 0;
	SQLCHAR message[1];
	SQLSMALLINT ignored;

	memcpy(state, "00000", sizeof("00000"));
	(void) SQLGetDiagRec(handle_type, handle, 1, state, &native_error, message,
					 sizeof(message), &ignored);
	return native_error;
}

static void
print_sqlstate(SQLSMALLINT handle_type, SQLHANDLE handle, const char *operation)
{
	SQLCHAR state[6];

	(void) diagnostic(handle_type, handle, state);
	fprintf(stderr, "HANA executor: %s failed (SQLSTATE %.5s)\n", operation, state);
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

static int
is_drop_table(const char *sql)
{
	while (isspace((unsigned char) *sql))
		++sql;
	return strncmp(sql, "DROP TABLE ", strlen("DROP TABLE ")) == 0;
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
				die("could not allocate SQL buffer");
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
		else if (!single_quote && !double_quote && c == '-' && cursor[1] == '-')
		{
			line_comment = 1;
			++cursor;
		}
		else if (!double_quote && c == '\'')
		{
			if (single_quote && cursor[1] == '\'')
				++cursor;
			else
				single_quote = !single_quote;
		}
		else if (!single_quote && c == '"')
		{
			if (double_quote && cursor[1] == '"')
				++cursor;
			else
				double_quote = !double_quote;
		}

		if ((c == ';' && !single_quote && !double_quote && !line_comment) || c == '\0')
		{
			SQLHSTMT stmt;
			SQLRETURN rc;
			SQLCHAR state[6];

			*cursor = '\0';
			if (has_sql(start))
			{
				rc = SQLAllocHandle(SQL_HANDLE_STMT, dbc, &stmt);
				if (!SQL_SUCCEEDED(rc))
					die("could not allocate statement handle");
				rc = SQLExecDirect(stmt, (SQLCHAR *) start, SQL_NTS);
				if (!SQL_SUCCEEDED(rc))
				{
					SQLINTEGER native_error = diagnostic(SQL_HANDLE_STMT, stmt, state);

					if (is_drop_table(start) &&
						(native_error == 259 || strcmp((const char *) state, "42S02") == 0))
					{
						SQLFreeHandle(SQL_HANDLE_STMT, stmt);
						++statement;
						start = cursor + 1;
						continue;
					}
					fprintf(stderr, "HANA executor: statement %u ", statement);
					fprintf(stderr, "execution failed (SQLSTATE %.5s)\n", state);
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
	char connection[8192] = "DRIVER={HDBODBC};";
	char *cursor = connection + strlen(connection);
	size_t remaining = sizeof(connection) - strlen(connection);
	char servernode[4096];
	char *sql;
	SQLHENV env;
	SQLHDBC dbc;
	SQLRETURN rc;

	if (snprintf(servernode, sizeof(servernode), "%s:%s", required_env("HANA_HOST"),
			 required_env("HANA_PORT")) >= (int) sizeof(servernode))
		die("server name is too long");
	append_option(&cursor, &remaining, "SERVERNODE", servernode);
	append_option(&cursor, &remaining, "DATABASENAME", required_env("HANA_DATABASE"));
	append_option(&cursor, &remaining, "ENCRYPT", required_env("HANA_ENCRYPT"));
	append_option(&cursor, &remaining, "SSLVALIDATECERTIFICATE", "false");
	append_option(&cursor, &remaining, "UID", required_env("HANA_USER"));
	append_option(&cursor, &remaining, "PWD", required_env("HANA_PASSWORD"));

	sql = read_sql();

	rc = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &env);
	if (!SQL_SUCCEEDED(rc))
		die("could not allocate ODBC environment");
	rc = SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, (void *) SQL_OV_ODBC3, 0);
	if (!SQL_SUCCEEDED(rc))
		die("could not select ODBC 3");
	rc = SQLAllocHandle(SQL_HANDLE_DBC, env, &dbc);
	if (!SQL_SUCCEEDED(rc))
		die("could not allocate ODBC connection");
	rc = SQLDriverConnect(dbc, NULL, (SQLCHAR *) connection, SQL_NTS, NULL, 0, NULL,
					  SQL_DRIVER_NOPROMPT);
	if (!SQL_SUCCEEDED(rc))
	{
		print_sqlstate(SQL_HANDLE_DBC, dbc, "connection");
		return EXIT_FAILURE;
	}

	execute_batch(dbc, sql);
	SQLDisconnect(dbc);
	SQLFreeHandle(SQL_HANDLE_DBC, dbc);
	SQLFreeHandle(SQL_HANDLE_ENV, env);
	free(sql);
	return EXIT_SUCCESS;
}
