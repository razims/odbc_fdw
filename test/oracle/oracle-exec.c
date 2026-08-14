#include <sql.h>
#include <sqlext.h>

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
die(const char *message)
{
	fprintf(stderr, "Oracle executor: %s\n", message);
	exit(EXIT_FAILURE);
}

static const char *
required_env(const char *name)
{
	const char *value = getenv(name);

	if (value == NULL || value[0] == '\0' || strcmp(value, "replace-me") == 0)
	{
		fprintf(stderr, "Oracle executor: set %s in .env before running\n", name);
		exit(EXIT_FAILURE);
	}
	return value;
}

static void
append_option(char **cursor, size_t *remaining, const char *name, const char *value)
{
	int written;

	/*
	 * Match odbc_fdw's production connection-string construction.  Oracle's
	 * ODBC driver treats braces around UID/PWD as credential characters rather
	 * than stripping them, which turns otherwise valid credentials into
	 * ORA-01017.  Reject delimiters before emitting the value unbraced.
	 */
	if (strpbrk(value, ";{}") != NULL)
		die("connection option contains an ODBC connection-string delimiter");
	written = snprintf(*cursor, *remaining, "%s=%s;", name, value);
	if (written < 0 || (size_t) written >= *remaining)
		die("connection string is too long");
	*cursor += written;
	*remaining -= (size_t) written;
}

/*
 * Oracle's DBQ Easy Connect value must be passed as
 * DBQ=//host:port/service. Unlike UID/PWD, wrapping it in ODBC braces makes
 * the Oracle driver resolve the braced text as a TNS name (ORA-12154).
 * Refuse connection-string delimiters before emitting this one unbraced.
 */
static void
append_dbq(char **cursor, size_t *remaining, const char *value)
{
	int written;

	if (strpbrk(value, ";{}") != NULL)
		die("DBQ contains an ODBC connection-string delimiter");
	written = snprintf(*cursor, *remaining, "DBQ=%s;", value);
	if (written < 0 || (size_t) written >= *remaining)
		die("connection string is too long");
	*cursor += written;
	*remaining -= (size_t) written;
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
	SQLINTEGER native_error;

	native_error = diagnostic(handle_type, handle, state);
	fprintf(stderr, "Oracle executor: %s failed (SQLSTATE %.5s, ORA-%05ld)\n",
			operation, state, (long) native_error);
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

/* Convert one validated UTF-8 character and advance *cursor past it. */
static uint32_t
next_utf8(const unsigned char **cursor, const unsigned char *end)
{
	const unsigned char *input = *cursor;
	uint32_t codepoint;
	unsigned continuation;
	unsigned i;

	if (input[0] < 0x80)
	{
		*cursor = input + 1;
		return input[0];
	}
	if (input[0] >= 0xC2 && input[0] <= 0xDF)
	{
		codepoint = input[0] & 0x1F;
		continuation = 1;
	}
	else if (input[0] >= 0xE0 && input[0] <= 0xEF)
	{
		codepoint = input[0] & 0x0F;
		continuation = 2;
	}
	else if (input[0] >= 0xF0 && input[0] <= 0xF4)
	{
		codepoint = input[0] & 0x07;
		continuation = 3;
	}
	else
		die("seed SQL is not valid UTF-8");
	if ((size_t) (end - input) <= continuation)
		die("seed SQL is not valid UTF-8");

	for (i = 1; i <= continuation; ++i)
	{
		if ((input[i] & 0xC0) != 0x80)
			die("seed SQL is not valid UTF-8");
		codepoint = (codepoint << 6) | (input[i] & 0x3F);
	}
	if ((continuation == 2 && codepoint < 0x800) ||
		(continuation == 3 && codepoint < 0x10000) ||
		(codepoint >= 0xD800 && codepoint <= 0xDFFF) || codepoint > 0x10FFFF)
		die("seed SQL is not valid UTF-8");
	*cursor = input + continuation + 1;
	return codepoint;
}

/* Oracle's wide ODBC entry points consume UTF-16 on unixODBC. */
static SQLWCHAR *
utf8_to_sqlwchar(const char *input)
{
	const unsigned char *cursor = (const unsigned char *) input;
	size_t input_length = strlen(input);
	const unsigned char *end = cursor + input_length;
	size_t used = 0;
	SQLWCHAR *wide;

	if (sizeof(SQLWCHAR) != 2)
		die("this platform does not use 2-byte SQLWCHAR values");
	if (input_length > (SIZE_MAX / sizeof(*wide)) - 1)
		die("SQL statement is too long");
	wide = malloc((input_length + 1) * sizeof(*wide));
	if (wide == NULL)
		die("could not allocate wide SQL buffer");

	while (*cursor != '\0')
	{
		uint32_t codepoint = next_utf8(&cursor, end);

		if (codepoint <= 0xFFFF)
			wide[used++] = (SQLWCHAR) codepoint;
		else
		{
			codepoint -= 0x10000;
			wide[used++] = (SQLWCHAR) (0xD800 + (codepoint >> 10));
			wide[used++] = (SQLWCHAR) (0xDC00 + (codepoint & 0x3FF));
		}
	}
	wide[used] = 0;
	return wide;
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
			SQLWCHAR *wide_sql;

			*cursor = '\0';
			if (has_sql(start))
			{
				rc = SQLAllocHandle(SQL_HANDLE_STMT, dbc, &stmt);
				if (!SQL_SUCCEEDED(rc))
					die("could not allocate statement handle");
				wide_sql = utf8_to_sqlwchar(start);
				rc = SQLExecDirectW(stmt, wide_sql, SQL_NTS);
				free(wide_sql);
				if (!SQL_SUCCEEDED(rc))
				{
					SQLINTEGER native_error = diagnostic(SQL_HANDLE_STMT, stmt, state);

					/* ORA-00942 makes cleanup/idempotent seed DROP TABLE safe. */
					if (is_drop_table(start) && native_error == 942)
					{
						SQLFreeHandle(SQL_HANDLE_STMT, stmt);
						++statement;
						start = cursor + 1;
						continue;
					}
					fprintf(stderr, "Oracle executor: statement %u ", statement);
					fprintf(stderr, "execution failed (SQLSTATE %.5s, ORA-%05ld)\n",
							state, (long) native_error);
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
	char connection[8192] = "DRIVER={Oracle 21 ODBC driver};";
	char *cursor = connection + strlen(connection);
	size_t remaining = sizeof(connection) - strlen(connection);
	char dbq[4096];
	char *sql;
	SQLHENV env;
	SQLHDBC dbc;
	SQLRETURN rc;

	if (snprintf(dbq, sizeof(dbq), "//%s:%s/%s", required_env("ORACLE_HOST"),
			 required_env("ORACLE_PORT"), required_env("ORACLE_SERVICE")) >=
		(int) sizeof(dbq))
		die("DBQ is too long");
	append_dbq(&cursor, &remaining, dbq);
	append_option(&cursor, &remaining, "UID", required_env("ORACLE_USER"));
	append_option(&cursor, &remaining, "PWD", required_env("ORACLE_PASSWORD"));

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
