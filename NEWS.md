# Changelog

Entries from `1.0.0` onwards are Softinent's. Everything below it is the
upstream lineage's own record, kept because it is where this code came from;
note that those version numbers are git tags of *other* repositories and do
not line up with any `default_version` this extension ever declared. See
`README.md` for provenance and for the versioning rule from `1.0.0` on.

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
