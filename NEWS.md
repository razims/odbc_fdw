# Changelog

Entries from `1.0.0` onwards are Softinent's. Everything below it is the
upstream lineage's own record, kept because it is where this code came from;
note that those version numbers are git tags of *other* repositories and do
not line up with any `default_version` this extension ever declared. See
`README.md` for provenance and for the versioning rule from `1.0.0` on.

## Unreleased

Not tagged, and `default_version` is deliberately still `1.0.0`. The bump
belongs with the release cut, alongside the matching entry in `dwh`'s
`ODBC_FDW_DATA_OK` allowlist, so a build can never report a version that `dwh`
then refuses.

Fixed — resource leaks:
- **ODBC handles, and the remote sessions behind them, no longer outlive their
  transaction.** `odbcEndForeignScan` was the only place they were freed, and
  the executor does not call it for a failed portal — `PortalCleanup` skips
  `ExecutorEnd` — so every error raised from inside a scan abandoned an
  environment handle, a connection handle and a remote session for the life of
  the backend. The ceilings added in `1.0.0` are the most reliable way to reach
  that path, because raising is what they exist to do. Measured with the
  credential-free loopback harness: twenty scans refused by `max_row_count` left
  twenty extra client backends on the remote, and one hundred refused inside
  PL/pgSQL `EXCEPTION` blocks left ninety-nine. Both are zero now. Released from
  a transaction callback and a subtransaction callback, the shape `postgres_fdw`
  uses; the release path cannot `ereport`, because an error raised while a
  transaction aborts is a PANIC.
- three allocations in `IMPORT FOREIGN SCHEMA` that grew with the size of the
  remote rather than being constant per statement: a `StringInfo` per column in
  `sql_data_type`, a column-name buffer per table, and a table-name buffer per
  excluded table. A 500-table, 50-column import held roughly 25 MB it did not
  need.
- an environment handle was orphaned whenever the connection handle was null,
  because the free was nested inside the connection's arm.

Fixed — memory safety and wrong answers:
- **`IMPORT FOREIGN SCHEMA` could dereference NULL and take the whole instance
  into crash recovery.** `strcmp` was called against a schema name that is NULL
  both for the documented `OPTIONS (schema '')` configuration and after the
  function's own error handling sets it so.
- **a failed `SQLFetch` was indistinguishable from the end of the result set**,
  so a connection dropped mid-scan produced a silently truncated result with no
  error anywhere. Only `SQL_NO_DATA` now ends a scan.
- `getQuoteChar` used an uninitialised stack byte when `SQLGetInfo` wrote
  nothing — and that byte quotes every identifier sent to the remote and decides
  what `escape_sql_identifier_part` doubles.
- `ODBCTableSize` and `ODBCQuerySize` returned uninitialised stack when the
  count query produced no row.
- `odbc_connection` passed `check_return` the *address* of the connection handle
  rather than the handle; `SQLHANDLE` is `void *`, so it compiled silently and
  every connection failure reported no driver diagnostic at all.
- environment, connection, and statement `SQLAllocHandle` return codes were
  not checked.

Added:
- connection-leak gates in both harnesses. Each counts only the remote sessions
  created by its own probe run around twenty refused scans and a PL/pgSQL
  subtransaction loop; both the aborted- and successful-inner-subtransaction
  paths are covered. The HANA probe identifies its run with HANA's `APPLICATION`
  session variable and counts the `SYS.M_SESSION_CONTEXT` rows carrying that
  marker — a session variable surfaces there as a `KEY`/`VALUE` row, and
  `M_CONNECTIONS` has no client-application column at all, so an earlier draft
  of this gate selected a column that does not exist and could only ever report
  "could not read". Both gates were confirmed to fail against the code they were
  written for. Against a live tenant, twenty refused scans move the marked
  session count by **0** with the handle-lifetime fix in place and by exactly
  **20** with the release path stubbed out. The tenant gate also carries a
  control on its own instrument: it counts the marker while a second marked
  connection is held open by a cursor, and refuses to report anything if it
  cannot see both. Without that, a marker that stopped reaching the tenant, or
  an account that could see only its own session, would make every delta below
  it read as a clean run.
- a backend-growth check over 200 successful scans, and an empty-remote-result
  scan, which is the negative control for refusing a failed fetch.
- a **million-row transfer gate**. Two-row tests say nothing about behaviour at
  size, and the instrument matters: resident set from `/proc/self/statm` rather
  than `pg_backend_memory_contexts`, because the ODBC driver allocates inside
  the backend where PostgreSQL's context accounting cannot see it. Measured,
  two identical million-row passes differ by 40,960–65,536 bytes through
  psqlODBC and 241,664–282,624 bytes through SAP's libodbcHDB against a real
  tenant. Both are ranges because both move between runs — allocator
  granularity, not a trend, and quoting either as one exact figure would claim a
  reproducibility the measurements do not have. Around a quarter of a byte per
  row, so the difference is the driver's working set and not a per-row cost.
  The gate refuses anything above 4MB. Each pass checks `sum(id)` against
  `n(n+1)/2` so a short scan cannot pass as a complete one, and the same fixture
  checks the `max_row_count` boundary on both sides and a `statement_timeout`
  part-way through — those two in the loopback harness only; the tenant gate
  does the transfer and the resident-set comparison and nothing else. Opt-in
  against a tenant through `HANA_BULK_ROWS`, and reported as skipped rather than
  passed when unset.

## 1.0.0
Released 2026-08-13

First Softinent release, derived from `devrimgunduz/odbc_fdw` at `ee741f5`
(its tag `0.6.1`, whose control file declared `0.5.2`). From here the git tag
and `default_version` are one string.

Fixed, each measured against a real SAP HANA 2.0 tenant and, for the first two,
independently reproduced against psqlODBC:
- an empty `SQL_CATALOG_NAME_SEPARATOR` produced one malformed identifier
  instead of `schema.table`;
- `values[]` was sized by result columns, indexed by foreign-table position and
  never zeroed — wrong values, and a SIGSEGV that took the instance into crash
  recovery;
- result columns were matched to foreign-table columns with a case-sensitive
  compare, so an up-folding remote silently lost every column;
- three errors in the chunked `SQLGetData` loop: a decision made on an
  uninitialised byte, an ODBC indicator added to a length unchecked, and
  `SQL_NO_DATA` from a continuation call treated as failure.

Added:
- `CHECK_FOR_INTERRUPTS()` inside the chunked read, so one huge field is
  cancellable;
- bounds checks throughout the retrieval path, so a bad driver length raises
  instead of corrupting memory;
- `max_field_size`, `max_row_count` and `max_result_size` resource ceilings,
  valid on a server and a table, unlimited by default, tightest wins, per scan;
- `IMPORT FOREIGN SCHEMA` refuses to create a zero-column foreign table.

Removed: the six historical upgrade scripts, CARTO's `carto-package.json`, and
a `CONTRIBUTING.md` pointing at a tracker with issues disabled.

## 0.6.0
Released 2026-07-06
- Fix builds and crashes against recent PostgreSQL versions

## 0.5.2.3
Released 2020-11-09

Changes:
- Fix bug with data over 8192 bytes with some drivers (https://github.com/CartoDB/odbc_fdw/pull/138).

## 0.5.2.2
Released 2020-11-02

Changes:
- Fix bug with short binary data (https://github.com/CartoDB/odbc_fdw/pull/137).

## 0.5.2.1
Released 2020-10-30

Changes:
- Fix potential privacy problem (https://github.com/CartoDB/odbc_fdw/pull/128).
- Fix bug with ignored first column (https://github.com/CartoDB/odbc_fdw/pull/129).
- Fix IMPORT SCHEMA not retrieving all tables (https://github.com/CartoDB/odbc_fdw/pull/129).
- Check for errors while reading data (https://github.com/CartoDB/odbc_fdw/pull/130).
- Support for VARBINAR (https://github.com/CartoDB/odbc_fdw/pull/131).

## 0.5.2
Released 2020-10-14

Changes:
- Improve error messages (https://github.com/CartoDB/odbc_fdw/pull/126).
- Add support for VARCHAR(0) (https://github.com/CartoDB/odbc_fdw/pull/125).
- Fix missing columns problem (https://github.com/CartoDB/odbc_fdw/pull/123).

## 0.5.1
Released 2020-02-17

Changes:
- Fixes #96 by closing connections (https://github.com/CartoDB/odbc_fdw/pull/116).

## 0.5.0
Released 2020-01-16

Changes:
- Update CI dependencies (https://github.com/CartoDB/odbc_fdw/pull/102).
- PG 12 compatibility (https://github.com/CartoDB/odbc_fdw/pull/104).
- Added support for MS Windows builds & CI (https://github.com/CartoDB/odbc_fdw/pull/101)

## 0.4.0
Released 2019-01-29

Changes:
- Changes in the testing infraestructure (https://github.com/CartoDB/odbc_fdw/pull/80, https://github.com/CartoDB/odbc_fdw/pull/81, https://github.com/CartoDB/odbc_fdw/pull/84, https://github.com/CartoDB/odbc_fdw/pull/87, https://github.com/CartoDB/odbc_fdw/pull/93).
- Fixes to support the final release of PostgreSQL 11 (https://github.com/CartoDB/odbc_fdw/pull/82).
- Use TupleDescAttr instead of its internal representation (https://github.com/CartoDB/odbc_fdw/pull/89).

## 0.3.0
Released 2018-02-20

Bug fixes:
- Fixed issues with travis builds
- elog_debug: Avoid warnings when disabled 0a8b95a
- Avoid unsigned/signed comparison warnings 763d70e

Announcements:
- Added support for PostgreSQL versions 9.6 and 10, and future v11.
- Changed to apache hive 2.2.1 in travis builds
- Updated README.md with supported driver versions 4ede641
- Added CONTRIBUTING.md document
- Added an `.editorconfig` file to help enforce formatting of c/h/sql/yml files 222b39a
- Applied bulk formatting pass to get everything lined up d53480e
- Added this NEWS.md file
- Added a release procedure in HOWTO_RELEASE.md file


## 0.2.0
Released 2016-09-30

Bug fixes:
- Fixed missing schema option `OPTION` a3b43b0

Announcements:
- Added test capabilities for all connectors
- Added support for schema-less ODBC data sources (e.g. Hive) 109557a
- Updated `freetds` package version to `1.00.14cdb7`
- Added ODBCTablesList function to query for the list of tables the user has access to in the server
- Added ODBCTableSize function to get the size, in rows, of the foreign table
- Added ODBCQuerySize function to get the size, in rows, of the provided query


## 0.1.0-rc1
Released 2016-08-03

Bug fixes:
- Quote connection attributes #15
- Handle single quotes when quoting options #19
- Prevent memory leak and race conditions d52fd60
- Handle partial SQLGetData results 3db51c0
- Use adequate minimum buffer size for numeric data to avoid precission loss df59364
- Fix various binary column problems 4caff4f

Announcements:
- Allows definition of arbitrary ODBC attributes with `odbc_` options 778ae02
- Limits size of varying columns and buffers 8149e32


## 0.0.1
Released 2016-07-15

First version based off https://github.com/bluthg/odbc_fdw at 0d44e9d. Additionally, it provides the following:

Bug fixes:
- Fixed compilation issues and API mismatches
- Fixed bug causing segfaults with query columns not present in foreign table
- Many other fixes for typos, NULL values, pointers, lenght of params, etc.

Announcements:
- Minimum PostgreSQL supported version updated to 9.5 and removed support for older versions
- Updated build instructions
- Added license file
- Updated README file
- Added driver, host and port parameters
- Added tests for the build `PGUSER=postgres make installcheck`
- Added support for `IMPORT FOREIGN SCHEMA`
- Added support for Add for no `sql_query` and no `sql_count` in options cases
- Added `encoding` option
- Allows username and password in server definition
- Added support for `GUID` columns
