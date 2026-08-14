# CLAUDE.md

Instructions for changing this repository.

## Project scope

This is Softinent's maintained distribution of `odbc_fdw`, derived from
`devrimgunduz/odbc_fdw` at commit `ee741f5` (tag `0.6.1`). It is a generic,
read-only PostgreSQL foreign data wrapper that connects through unixODBC.

The implementation is a native shared library loaded into PostgreSQL backend
processes. Treat memory safety, driver input, handle lifetime, and error
unwinding as database-instance concerns rather than ordinary application bugs.

The source carries PostgreSQL compatibility branches from 9.5 through 18.
PostgreSQL 18 is the current maintained build and test target; the predecessor
project historically tested 9.5 through 12. Do not remove an older-version
branch merely because the current Docker suite does not exercise it. Read
`README.md` first; it is the public contract. This file records maintenance
invariants that are easy to break while refactoring.

## Keep documentation synchronized

`README.md`, `CHANGELOG.md`, and this file are living documents.

| Change | Also update |
| --- | --- |
| option added, renamed, or removed | option validation, extraction, README option table, and tests |
| type mapping changed | README type table and import tests |
| extension version changed | control file, base SQL file, Makefile `DATA`, upgrade SQL, changelog, README, and annotated tag |
| behavior fixed | changelog and a regression test |
| compatibility evidence changed | README compatibility table |

Public documentation describes a generic ODBC extension. Product-specific
connection instructions belong in executable integration-test infrastructure,
not in the README or contributor narrative. Database product names may appear
in the README compatibility table as test evidence.

## Option invariants

### `odbc_` means pass-through

An option prefixed with `odbc_` is converted to an ODBC connection-string
attribute. The FDW does not interpret it.

- The prefix comparison is case-sensitive. PostgreSQL folds unquoted option
  names to lower case, but a quoted upper-case prefix is not recognised.
- `DRIVER`, `DSN`, `UID`, and `PWD` are normalised to upper case. Other
  attribute names preserve their stored spelling.
- An unrecognised server or user-mapping option is rejected. An unrecognised
  foreign-table option becomes a remote column mapping, so a misspelled option
  can be accepted silently and change the generated query.
- Never give an FDW-owned option an `odbc_` prefix.
- Never add a generic key/value pass-through that bypasses the existing
  validation and privilege rules.

Driver and DSN selection is superuser-only in every object context. The driver
manager loads the selected native library into the backend, so this restriction
applies equally to `driver`, `dsn`, `odbc_driver`, and `odbc_dsn`.

Credentials belong in user mappings. Server options are visible through
catalogs and included in dumps; user-mapping options are hidden from roles that
do not own the server.

### Claim FDW options before column mappings

`extract_odbcFdwOptions` must handle every FDW-owned foreign-table option before
the mapping fallthrough. Registering an option in `valid_options[]` without
extracting it turns the option into a remote column name.

### Resource ceilings use the tightest value

`max_field_size`, `max_row_count`, and `max_result_size` are valid on servers
and foreign tables. They fold to the smallest positive value regardless of the
order in which option lists are combined. Zero means unlimited and cannot
loosen a positive limit already in force.

Validate ceiling syntax and range in the validator so invalid DDL fails when it
is executed, not during a later scan.

`max_field_size` and `max_result_size` each require two checks:

- an in-loop check bounds memory while a chunked value is assembled;
- an exact post-loop check catches a value delivered in one chunk.

`check_result_size` compares by subtraction. `done + field` may overflow for
an arbitrary non-negative `int64` ceiling; `field > max - done` does not while
the maintained invariant `done <= max` holds.

Ceilings are per scan. `ReScanForeignScan` re-executes the statement and resets
row and byte counters. Whether a query succeeds must not depend on the planner
choosing a rescan, materialization, or memoization shape.

The limits count bytes retrieved by the FDW. They do not represent the
backend's full memory high-water mark and are not a process-isolation boundary.

## Scan and conversion invariants

### Tuple arrays are sized by the foreign table

Arrays passed to `BuildTupleFromCStrings` are sized by `natts`, not by the
number of result columns, and allocated with `palloc0`. A result column may not
map to a local attribute; the untouched local slot must be SQL NULL rather than
uninitialised memory.

### Column matching is exact before case-insensitive

Prefer an exact result-column match. Permit a case-insensitive fallback only
when it is unique. Use PostgreSQL's `pg_strcasecmp`, not `strcmp` or the
locale-dependent system `strcasecmp`.

This preserves remotes with a different identifier-folding convention while
keeping case-distinct remote columns unambiguous.

### Schema qualification uses a period

`SQL_CATALOG_NAME_SEPARATOR` answers how a catalog is joined to the following
name. It does not define the separator between a schema and a table. Every
generated schema-qualified table name uses SQL's period, through the shared
qualification helper, so scans and metadata queries cannot disagree.

### Driver lengths are indicators

An `SQLGetData` result length may instead be `SQL_NULL_DATA` or `SQL_NO_TOTAL`.
Check sign and range before arithmetic. A failed `SQLFetch` is an error; only
`SQL_NO_DATA` is the end of a result set.

Refuse impossible driver lengths and buffer geometry. Do not clamp them and
continue with a different read: once length arithmetic is invalid, continuing
risks either memory corruption or a silently wrong value.

Chunked buffer growth is geometric. Reintroducing exact-size growth makes
large-value assembly quadratic.

### Wide text is driver-sensitive

Some ODBC drivers require national character types to be retrieved through
`SQL_C_WCHAR`; others already transcode those types correctly through
`SQL_C_CHAR` and return incorrect data through the wide target without an
error. Keep this product-neutral: `wide_char_mode` selects the behavior on the
foreign server or table, defaults to `char`, and must never be inferred from a
database or driver product name. A table value wins over its server value.

The wide path accepts aligned 2-byte UTF-16 or 4-byte UTF-32 `SQLWCHAR` units,
validates code points and surrogate pairs, converts them to UTF-8, and then
converts from UTF-8 to the PostgreSQL server encoding. PostgreSQL text cannot
contain a zero code point.

### Interrupt placement is deliberate

There is no explicit interrupt check at the row boundary in
`odbcIterateForeignScan`; PostgreSQL's executor already checks once per tuple.
The explicit check belongs inside the chunked field-read loop, which is the
part PostgreSQL cannot reach while one tuple is being assembled.

This makes a long chunk loop cancellable. It cannot interrupt a driver call
that is blocked inside the driver.

## ODBC handle lifetime

The executor does not guarantee that `odbcEndForeignScan` runs after every
error. Environment, connection, and statement handles are therefore registered
with transaction and subtransaction cleanup callbacks.

- Release handles on successful completion, error, cancellation, and abort.
- Adopt handles opened in a committed subtransaction into the parent.
- Cleanup callbacks must not raise errors while PostgreSQL is already aborting.
- Free the environment even when no connection handle was created.
- Do not count a tidy backend exit as proof that an in-session error path is
  leak-free; tests must observe the remote sessions while the backend remains
  alive.

## Metadata invariants

Check every ODBC metadata call and validate NULL indicators, truncation, and
integer widths before using returned values.

`IMPORT FOREIGN SCHEMA` must refuse a zero-column result. PostgreSQL accepts an
empty foreign-table declaration, but reporting a successful import for a
missing table or entirely unsupported schema is misleading.

Reuse metadata buffers within a statement. Per-table and per-column allocations
that survive until statement end turn a large import into memory growth
proportional to the remote catalog.

Generated local SQL uses PostgreSQL's identifier and literal quoting helpers.
Generated remote SQL quotes identifier parts using the quote character reported
by the driver and doubles embedded quote characters.

## Planner and helper invariants

Plain `EXPLAIN` performs no remote connection or query. Use local estimates at
planning time. Only execution, including `EXPLAIN ANALYZE`, may contact the
remote.

`ODBCTablesList`, `ODBCTableSize`, and `ODBCQuerySize` open remote connections.
Their SQL functions are revoked from `PUBLIC`, require explicit `EXECUTE`, and
also require `USAGE` on the named foreign server.

Set-returning metadata functions execute their ODBC catalog call once and
fetch the existing cursor across calls. Do not restart the remote operation for
each returned row.

## Build

```sh
make USE_PGXS=1 PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
sudo make install USE_PGXS=1 PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

The official PostgreSQL runtime image does not contain server headers.
`postgresql-server-dev-18` supplies PGXS and server headers; `unixodbc-dev`
supplies the ODBC headers and link library.

Do not suppress new compiler warnings. The supported Docker build is clean with
the PGXS warning set under both GCC and Clang.

`ldd` proves only that linked dependencies resolve. Individual ODBC drivers are
loaded dynamically at connection time. Verify registration with
`odbcinst -q -d` and execute a real scan before claiming a driver works.

## Tests

Docker is the supported development environment:

```sh
make docker-build
make docker-shell
make docker-test
make docker-test-all
make docker-sqlite
make docker-mysql
make docker-mssql
```

The credential-free suites build and install the extension, start disposable
local databases, and reach them through real ODBC drivers. They cover loading,
imports, scans, identifier mapping, binary values, Unicode, bound parameters,
limits, rescans, cancellation, handle cleanup, and a repeated 1,000,000-row
transfer. Keep their database images and downloaded clients pinned to exact
versions and verified digests.

Additional integration suites use external databases. They are opt-in, read
credentials only from the gitignored `.env`, and operate only on dedicated
fixture tables. Keep product-specific configuration, grants, driver versions,
and architecture constraints in those executable test directories, the
Dockerfile, Compose configuration, Makefile, and `.env.example`.

The inherited regression harness also requires configured live sources and
fixture data from infrastructure this repository does not have. Do not claim
`make installcheck` as a standalone gate.

Every regression check needs a negative control or a paired success case that
proves it can fail for the intended reason.

## Versioning

The annotated git tag and `default_version` are identical. A release also keeps
the base SQL filename, Makefile `DATA`, README, changelog, and upgrade path aligned.

Use semantic versioning:

- patch for a C-only fix;
- minor for an additive option or feature;
- major for a breaking behavior change.

Every release has a base SQL script and an upgrade script from the previous
release. An empty upgrade script is correct for a C-only change. Never require
operators to drop the extension merely because an upgrade file was omitted;
dropping can cascade to foreign tables and dependent views.

Do not reuse the upstream control-file version `0.5.2`. It identifies stock
builds with different behavior and cannot safely identify this distribution.

Never rename `odbc_fdw`, `odbc_fdw.so`, `odbc_fdw_handler`, or
`odbc_fdw_validator`; downstream installations and PostgreSQL catalogs depend
on those interface names.

## Licence and provenance

Keep the upstream lineage and every existing copyright notice.

- `LICENSE` grant text stays byte-identical.
- Softinent's notice applies only to files it substantially modifies and sits
  beside, never in place of, existing notices.
- Files do not all carry the same historical notices; do not normalize them.
- README provenance is part of the public documentation, not optional history.

## Conventions

- Use Conventional Commits: `type(scope)!: subject`, imperative, no trailing
  period, header at most 72 characters.
- Put measurements and negative results in commit bodies.
- Label untested conclusions as inferences.
- Preserve surrounding C style and tabs; avoid unrelated formatting.
- Ported commits keep their original messages.
- Commits carry no AI attribution.
- Never commit credentials, real hostnames, or real schema names.
