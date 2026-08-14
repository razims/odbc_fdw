# odbc_fdw

`odbc_fdw` is a read-only PostgreSQL foreign data wrapper for ODBC data
sources. It connects through unixODBC, so the extension is not tied to a
particular database product: if a suitable ODBC driver is installed and
registered, PostgreSQL can expose the remote tables through the foreign-table
interface.

This repository is Softinent's maintained distribution. It adds resource
ceilings, safer metadata and buffer handling, reliable connection cleanup, and
other correctness fixes to the upstream lineage.

| | |
| --- | --- |
| Extension | `odbc_fdw` |
| Release | `1.0.2` |
| PostgreSQL compatibility | PostgreSQL 9.5–18 |
| Current build and test target | PostgreSQL 18 |
| Runtime dependency | unixODBC plus an ODBC driver for the remote source |
| Licence | PostgreSQL licence; see [`LICENSE`](LICENSE) |

## Compatibility

The extension uses standard ODBC APIs and is intended to remain
driver-independent. ODBC drivers differ in metadata, type conversion,
identifier folding, and connection attributes, so compatibility must still be
verified with the exact driver version used in production.

The source retains PostgreSQL API compatibility branches from 9.5 through 18.
The current release suite runs on PostgreSQL 18. The predecessor project's CI
historically exercised PostgreSQL 9.5 through 12; those results are inherited
evidence, not a claim that this 1.0.2 tree has been rerun on every older major.
PostgreSQL 13 through 17 are covered by the compatibility code but are not yet
part of the maintained test matrix.

This release has been tested against:

| Remote database | ODBC driver |
| --- | --- |
| PostgreSQL 18 | psqlODBC from Debian 13 |
| SAP HANA 2.0 | SAP HANA Client 2.29.25 |
| Oracle Database 19c | Oracle Instant Client ODBC 21.23 |
| SQLite 3.53.4 | SQLite ODBC 0.99991 |
| MySQL 9.7.1 | MySQL Connector/ODBC 9.7.0 |
| Microsoft SQL Server 2025 Express | Microsoft ODBC Driver 18.6.2.1 |

This table records test evidence; it is not an allowlist. Other ODBC data
sources may work without code changes.

## Install

Install the PostgreSQL server development files and unixODBC headers, then
build with PGXS. The commands below use the maintained PostgreSQL 18 target;
for an older compatible major, use its matching server-development package and
`pg_config`:

```sh
apt-get install -y build-essential postgresql-server-dev-18 unixodbc-dev
make USE_PGXS=1
sudo make install USE_PGXS=1
```

Select a specific PostgreSQL installation with `PG_CONFIG`:

```sh
make USE_PGXS=1 PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
sudo make install USE_PGXS=1 PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

The extension links to the unixODBC driver manager, not to an individual
database driver. Install and register the required driver separately. Confirm
that unixODBC can see it before configuring PostgreSQL:

```sh
odbcinst -q -d
```

Create the extension in each PostgreSQL database that will use it:

```sql
CREATE EXTENSION odbc_fdw;
```

## Quick start

ODBC connection attributes can be split across three PostgreSQL objects:

- the foreign server for shared connection settings;
- the user mapping for credentials and role-specific settings;
- the foreign table for the remote object or query.

Create a server with a registered driver:

```sql
CREATE SERVER remote_source
  FOREIGN DATA WRAPPER odbc_fdw
  OPTIONS (
    odbc_driver   'Example ODBC Driver',
    odbc_server   'db.example.internal',
    odbc_port     '1234',
    odbc_database 'analytics'
  );
```

The names after `odbc_` are passed to the driver as connection-string
attributes. Use the names documented by that driver.

Store credentials in a user mapping:

```sql
CREATE USER MAPPING FOR reporting_user
  SERVER remote_source
  OPTIONS (
    odbc_uid 'remote_login',
    odbc_pwd 'remote_password'
  );
```

Define a foreign table explicitly:

```sql
CREATE SCHEMA external;

CREATE FOREIGN TABLE external.orders (
  id         bigint,
  customer   text,
  created_at timestamp
)
SERVER remote_source
OPTIONS (
  schema 'sales',
  table  'orders'
);
```

Then query it like a PostgreSQL table:

```sql
SELECT id, customer
FROM external.orders
WHERE customer = 'example';
```

The wrapper is read-only. `INSERT`, `UPDATE`, and `DELETE` are not supported.

## Import remote metadata

`IMPORT FOREIGN SCHEMA` creates foreign-table definitions from ODBC catalog
metadata:

```sql
IMPORT FOREIGN SCHEMA sales
  LIMIT TO ("Orders", "Customers")
  FROM SERVER remote_source
  INTO external;
```

Quote remote names with their exact spelling. PostgreSQL folds unquoted names
to lower case before the FDW receives them, while a remote database may use a
different identifier-folding rule. The wrapper preserves quoted names and
refuses an import that produces no supported columns.

Use `prefix` when imported local names need a namespace:

```sql
IMPORT FOREIGN SCHEMA sales
  FROM SERVER remote_source
  INTO external
  OPTIONS (prefix 'sales_');
```

## Query-backed foreign tables

Use `sql_query` when the foreign table should expose a remote query rather
than one remote table:

```sql
CREATE FOREIGN TABLE external.order_totals (
  customer_id bigint,
  total       numeric
)
SERVER remote_source
OPTIONS (
  table 'order_totals',
  sql_query 'SELECT customer_id, SUM(amount) AS total
             FROM sales.orders
             GROUP BY customer_id'
);
```

`sql_query` is sent in the remote database's SQL dialect. The `table` option
supplies the local name when query metadata is imported.

## Options

### Connection attributes

Any option named `odbc_<attribute>` becomes an ODBC connection-string
attribute. For example, `odbc_driver`, `odbc_uid`, and `odbc_pwd` become
`DRIVER`, `UID`, and `PWD`.

Important rules:

- Write the `odbc_` prefix in lower case. PostgreSQL normally folds unquoted
  option names to lower case, but a double-quoted upper-case prefix is not
  recognised.
- `DRIVER`, `DSN`, `UID`, and `PWD` are normalised to upper case. Other
  attribute names retain their stored spelling.
- Wrap an attribute value containing `=` or `;` in ODBC braces, for example
  `OPTIONS (odbc_pwd '{value=with;delimiters}')`.
- Driver and DSN selection is superuser-only because the driver manager loads
  the selected shared library into the PostgreSQL backend.
- Credentials belong in user mappings. Server options are visible in system
  catalogs and are included in dumps.

### FDW options

These options are interpreted by `odbc_fdw` and are not passed to the driver:

| Option | Context | Description |
| --- | --- | --- |
| `driver` | server | Registered ODBC driver name |
| `dsn` | server | Registered ODBC data source name |
| `encoding` | server, table | Remote character encoding, using a PostgreSQL encoding name |
| `wide_char_mode` | server, table | Retrieval target for ODBC wide text: `char` (default) or `wchar` |
| `schema` | table, import | Remote schema; an empty value selects a schema-less source |
| `table` | table, import | Remote table name, or local name for an imported query |
| `sql_query` | table, import | Remote SQL used instead of a generated table scan |
| `sql_count` | table | Remote SQL used by the explicit size helper |
| `prefix` | import | Prefix added to imported local table names |
| `max_field_size` | server, table | Maximum bytes retrieved for one field |
| `max_row_count` | server, table | Maximum rows returned by one scan |
| `max_result_size` | server, table | Maximum total bytes retrieved by one scan |

Any other non-prefixed foreign-table option is treated as a remote column-name
mapping:

```sql
CREATE FOREIGN TABLE external.accounts (
  account_id bigint,
  display_name text
)
SERVER remote_source
OPTIONS (
  schema 'crm',
  table 'accounts',
  account_id 'ACCOUNT_NUMBER',
  display_name 'DISPLAY_LABEL'
);
```

## Resource ceilings

The three resource ceilings are unlimited by default. A positive value refuses
a scan that exceeds it:

```sql
CREATE SERVER bounded_source
  FOREIGN DATA WRAPPER odbc_fdw
  OPTIONS (
    odbc_driver     'Example ODBC Driver',
    max_field_size  '1048576',
    max_row_count   '10000000',
    max_result_size '2147483648'
  );
```

Their common behavior is:

- values are non-negative integers; `0` means unlimited;
- invalid values are rejected when the server or table is created;
- limits can be set on a server and lowered on an individual table;
- the tightest positive value wins, so a table cannot raise its server's
  limit;
- exceeding a limit raises an error instead of silently truncating data;
- counters apply to one foreign scan and restart when PostgreSQL rescans it.

`max_result_size` counts bytes retrieved into the FDW's field buffers. It does
not equal the backend's total memory footprint: converted values, tuples,
sorts, hashes, and allocations made by the ODBC driver have separate costs.
These limits also do not bound query duration or interrupt a driver call that
is blocked inside the driver. Use PostgreSQL statement timeouts as a separate
control.

The ODBC driver runs inside the PostgreSQL backend process. Resource ceilings
reduce exposure to unexpectedly large remote results; they are not a process
isolation boundary for untrusted drivers.

## Metadata helpers

The extension provides three SQL helpers:

- `ODBCTablesList(server_name, limit)` lists accessible remote tables;
- `ODBCTableSize(server_name, table_name)` returns a table row count;
- `ODBCQuerySize(server_name, query)` returns a query row count.

They open remote connections, and the query helper executes caller-supplied
remote SQL. Fresh installations revoke their execution privileges from
`PUBLIC`. Grant both foreign-server usage and the required function explicitly:

```sql
GRANT USAGE ON FOREIGN SERVER remote_source TO metadata_reader;
GRANT EXECUTE ON FUNCTION ODBCTablesList(text, integer) TO metadata_reader;
```

Upgrade an existing installation to the current release:

```sql
ALTER EXTENSION odbc_fdw UPDATE TO '1.0.2';
```

## Type mapping

`IMPORT FOREIGN SCHEMA` currently maps these ODBC types:

| ODBC types | PostgreSQL type |
| --- | --- |
| `SQL_CHAR`, `SQL_WCHAR` | `char(n)` |
| `SQL_VARCHAR`, `SQL_WVARCHAR` | `varchar(n)` or `text` |
| `SQL_LONGVARCHAR`, `SQL_WLONGVARCHAR` | `text` |
| `SQL_DECIMAL`, `SQL_NUMERIC` | `decimal(p,s)`, `numeric(p,s)` |
| `SQL_TINYINT`, `SQL_SMALLINT` | `smallint` |
| `SQL_INTEGER` | `integer` |
| `SQL_BIGINT` | `bigint` |
| `SQL_REAL` | `real` |
| `SQL_FLOAT`, `SQL_DOUBLE` | `double precision` |
| `SQL_BIT`, `SQL_BOOLEAN` | `boolean` |
| date, time, and timestamp ODBC types | matching PostgreSQL temporal type |
| `SQL_GUID` | `uuid` |
| `SQL_BINARY`, `SQL_VARBINARY`, `SQL_LONGVARBINARY` | `bytea` |

### Tested remote type mappings

The integration suites exercise the following remote-to-PostgreSQL scan
declarations with the database and driver versions in the compatibility table.
These are tested examples, not a complete compatibility list. Automatic import
may emit modifier-preserving equivalents such as `char(n)`, `varchar(n)`, or
`numeric(p,s)`, according to the ODBC metadata and the generic rules above.

| Tested remote database | Remote column type(s) | PostgreSQL foreign-column type exercised |
| --- | --- | --- |
| PostgreSQL | `INTEGER` | `integer` |
| PostgreSQL | `TEXT` | `text` |
| PostgreSQL | `BYTEA` | `bytea` |
| SAP HANA | `TINYINT`, `SMALLINT` | `smallint` |
| SAP HANA | `INTEGER` | `integer` |
| SAP HANA | `BIGINT` | `bigint` |
| SAP HANA | `DECIMAL(18,4)`, `DECIMAL(20,4)` | `numeric` |
| SAP HANA | `REAL` | `real` |
| SAP HANA | `DOUBLE` | `double precision` |
| SAP HANA | `BOOLEAN` | `boolean` |
| SAP HANA | `CHAR(6)`, `NCHAR(6)`, `VARCHAR(100)`, `NVARCHAR(100)`, `CLOB`, `NCLOB` | `text` |
| SAP HANA | `DATE` | `date` |
| SAP HANA | `TIME` | `time` |
| SAP HANA | `TIMESTAMP`, `SECONDDATE` | `timestamp` |
| SAP HANA | `BLOB`, `BINARY(4)`, `VARBINARY(4)` | `bytea` |
| Oracle Database | `NUMBER(5,0)` | `smallint` |
| Oracle Database | `NUMBER(10,0)` | `integer` |
| Oracle Database | `NUMBER(19,0)` | `bigint` |
| Oracle Database | `NUMBER(18,4)`, `NUMBER(20,4)` | `numeric` |
| Oracle Database | `BINARY_FLOAT` | `real` |
| Oracle Database | `BINARY_DOUBLE` | `double precision` |
| Oracle Database | `CHAR(6)`, `NCHAR(6)`, `VARCHAR2(100)`, `NVARCHAR2(100)`, `CLOB`, `NCLOB` | `text` |
| Oracle Database | `DATE`, `TIMESTAMP(6)` | `timestamp` |
| Oracle Database | `BLOB`, `RAW(4)` | `bytea` |
| SQLite | `TINYINT`, `SMALLINT` | `smallint` |
| SQLite | `INTEGER` | `integer` |
| SQLite | `BIGINT` | `bigint` |
| SQLite | `NUMERIC` | `numeric` when declared explicitly; `double precision` on import with SQLite ODBC 0.99991 |
| SQLite | `REAL` | `real` |
| SQLite | `DOUBLE` | `double precision` |
| SQLite | `BOOLEAN` | `boolean` |
| SQLite | `CHAR(6)`, `VARCHAR(100)`, `TEXT` | `text` |
| SQLite | `DATE` | `date` |
| SQLite | `TIME` | `time` |
| SQLite | `TIMESTAMP` | `timestamp` |
| SQLite | `BLOB` | `bytea` |
| MySQL | `TINYINT`, `TINYINT UNSIGNED`, `SMALLINT` | `smallint` |
| MySQL | `INT` | `integer` |
| MySQL | `BIGINT` | `bigint` |
| MySQL | `DECIMAL(18,4)`, `DECIMAL(20,4)` | `numeric` |
| MySQL | `FLOAT` | `real` |
| MySQL | `DOUBLE` | `double precision` |
| MySQL | `BOOLEAN`, `BIT(1)` | `boolean` |
| MySQL | `CHAR(6)`, `VARCHAR(100)`, `TEXT`, `LONGTEXT` | `text` |
| MySQL | `DATE` | `date` |
| MySQL | `TIME(6)` | `time` |
| MySQL | `DATETIME(6)`, `TIMESTAMP(6)` | `timestamp` |
| MySQL | `YEAR` | `smallint` |
| MySQL | `BINARY(4)`, `VARBINARY(4)`, `BLOB`, `LONGBLOB` | `bytea` |
| MySQL | `JSON` | `jsonb` in an explicit foreign-table declaration |
| Microsoft SQL Server | `TINYINT`, `SMALLINT` | `smallint` |
| Microsoft SQL Server | `INT` | `integer` |
| Microsoft SQL Server | `BIGINT` | `bigint` |
| Microsoft SQL Server | `DECIMAL(18,4)`, `DECIMAL(20,4)` | `numeric` |
| Microsoft SQL Server | `REAL` | `real` |
| Microsoft SQL Server | `FLOAT(53)` | `double precision` |
| Microsoft SQL Server | `BIT` | `boolean` |
| Microsoft SQL Server | `CHAR(6)`, `NCHAR(6)`, `VARCHAR(100)`, `NVARCHAR(100)`, `VARCHAR(MAX)`, `NVARCHAR(MAX)` | `text` |
| Microsoft SQL Server | `DATE` | `date` |
| Microsoft SQL Server | `TIME(6)` | `time` in an explicit foreign-table declaration |
| Microsoft SQL Server | `DATETIME2(6)`, `SMALLDATETIME` | `timestamp` |
| Microsoft SQL Server | `UNIQUEIDENTIFIER` | `uuid` |
| Microsoft SQL Server | `BINARY(4)`, `VARBINARY(4)`, `VARBINARY(MAX)` | `bytea` |

The national-character Oracle cases were exercised with
`wide_char_mode 'wchar'`. A missing type in this table means that the current
fixtures do not cover it; it does not mean that the type or database is
unsupported. Numeric mappings demonstrate the seeded precisions and values,
not every value in each remote type's full domain.

SQLite's dynamic type system and the SQLite ODBC bridge's metadata explain the
different `NUMERIC` import result recorded above. Microsoft ODBC Driver 18
reports SQL Server `TIME` metadata as the vendor-specific type `-154`; the
current generic importer omits that column with a `NOTICE`, while an explicit
`time` declaration is covered by the scan suite. These measured exceptions are
kept visible rather than presented as portable generic mappings.

Unsupported metadata types are reported with a `NOTICE` and omitted from the
generated table definition. A hand-written foreign table may use PostgreSQL's
input conversion for additional remote textual representations, but that
behavior is driver-dependent and should be tested explicitly.

ODBC drivers disagree on how national character types should be retrieved.
The default `wide_char_mode 'char'` uses `SQL_C_CHAR` and preserves the
extension's established behavior. Set `wide_char_mode 'wchar'` on a server—or
on one foreign table as an override—when its driver requires `SQL_C_WCHAR`.
The wrapper accepts both 2-byte UTF-16 and 4-byte UTF-32 `SQLWCHAR`
representations. This setting is explicit because a driver may return corrupted
text instead of an error for the wrong target, so automatic fallback cannot be
made reliable.

## Security and operations

- Treat ODBC drivers as native code trusted by the PostgreSQL instance. The
  driver manager loads them into backend processes.
- Restrict who can create or alter servers and user mappings.
- Put credentials in user mappings, not server or foreign-table options.
- Use encrypted transport and certificate validation according to the selected
  driver's documentation.
- Set explicit resource ceilings and `statement_timeout` for shared or
  production systems.
- Use `EXPLAIN` without `ANALYZE` when remote execution is not intended. Plain
  `EXPLAIN` performs no remote connection or query.
- Test the exact driver build and connection attributes before production use.

## Development and testing

Docker is the supported development environment:

```sh
make docker-build
make docker-shell
make docker-test
make docker-sqlite
make docker-mysql
make docker-mssql
```

`make docker-test` compiles and installs the extension, starts disposable local
PostgreSQL databases, and reaches one through a real ODBC driver. It covers
extension loading, imports, scans, identifier mapping, parameter binding,
binary values, rescans, resource ceilings, error cleanup, and a repeated
1,000,000-row transfer with row-count, checksum, and backend-memory checks.

The SQLite, MySQL, and SQL Server targets build the same test runner and execute
live ODBC suites against isolated Compose services. They need no credentials
and cover explicit declarations, metadata import, nulls, Unicode, numeric and
temporal values, large text and binary values, identifier case, bound
parameters, query-backed tables, rescans, read-only enforcement, and resource
ceilings. The SQL Server database image is amd64-only; on an arm64 host Docker
emulates that database container while the test runner and Microsoft ODBC
client remain native.

Architecture-specific variants are available:

```sh
make docker-test-amd64
make docker-test-arm64
make docker-test-all
```

Additional live-database integration suites are kept under `test/`. Suites for
external databases are opt-in because they require credentials from the
gitignored `.env` file. Their seed and cleanup commands modify only dedicated
`ODBC_FDW_*` fixtures. See `.env.example`, the Makefile targets, and the test
scripts for operational details.

The inherited regression harness also requires configured live ODBC sources
and fixture data. It is retained as upstream test coverage, but it is not the
credential-free development gate.

## Versioning

The annotated git tag, `default_version`, base SQL filename, Makefile `DATA`,
and upgrade path use the same version. This release is `1.0.2`.

Every release changes that version:

| Change | Version bump |
| --- | --- |
| C-only fix | patch |
| New option or additive feature | minor |
| Breaking behavior change | major |

Each release includes a base `odbc_fdw--<version>.sql` script and an upgrade
script from the previous release so operators can use `ALTER EXTENSION` without
dropping dependent foreign tables and views. See [`CHANGELOG.md`](CHANGELOG.md) for the
release history.

## Provenance

This distribution is derived from `devrimgunduz/odbc_fdw` at commit `ee741f5`
(tag `0.6.1`), which continues the work of CARTO, Gunnar "Nick" Bluth, Zheng
Yang, and the PostgreSQL Global Development Group. The full notices remain in
the source files and `LICENSE`.

Softinent's copyright notice applies only to its modifications. Existing
copyright and licence notices must remain with the software.
