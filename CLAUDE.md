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

### Column buffers are sized from display size, not column size

`SQLDescribeCol`'s column size answers a different question from the one a text
retrieval asks. For `SQL_DECIMAL` and `SQL_NUMERIC` it is the PRECISION, which
budgets digits only, while the rendering also needs a character for a sign and
one for a decimal point. Sizing from it alone returned a value correctly only
while its rendering was at most `max(precision, 32)` characters.

Raise the buffer to `SQL_DESC_DISPLAY_SIZE`, as a LOWER BOUND only: an
unsupported attribute, `SQL_NO_TOTAL`, or a value that cannot be a length must
leave the existing sizing untouched. Nothing about consulting it may make a
buffer smaller than it would otherwise have been.

Sizing is the prevention, not the guarantee. ODBC guarantees a value can be
retrieved across several `SQLGetData` calls only for character and binary source
types, so for every other type the first call is the only one a driver need
honour, and a driver that under-reports its own display size will still
truncate. Therefore: when the driver has reported a length and fewer bytes than
that arrive, REFUSE. Do not return the short value and do not attempt to repair
it — the lost digits are unrecoverable, and `numeric(p,s)` pads a short
rendering back to scale with zeros, so the wrong amount is indistinguishable
from a right one. The same applies to fractional truncation (`01S07`) on a
numeric type; the temporal half of that diagnostic stays tolerant because
PostgreSQL's own temporal types round to microseconds regardless.

That `01S07` branch is a GUARD, not an active path, and the distinction is
measured: no driver in the matrix returns `01S07` for any C type this extension
binds. MySQL Connector/ODBC and Microsoft ODBC Driver 18 do return it, for
`SQL_C_SLONG`, `SQL_C_NUMERIC` and `SQL_C_TYPE_TIME`, so the capability is real
and its absence elsewhere is a choice; psqlODBC, SQLite ODBC and SAP HANA never
return it at all, even where the specification says they should. For
`SQL_C_CHAR` all five report `01004` instead. Do not delete the branch on the
strength of that, and do not claim it is exercised.

Temporal floors carry a FULL sub-second fraction rather than trusting the
reported size. ODBC caps fractional seconds precision at 9, so the widest
renderings are 18 characters for a time and 29 for a timestamp, and those are
the floors. SAP HANA reports a column size AND a display size of 27 for
`TIMESTAMP` and then renders 29 bytes, so a buffer sized from what it reported
truncated on the only `SQLGetData` call it would answer.

Floating point columns do not go through text at all. `SQL_REAL`, `SQL_FLOAT`
and `SQL_DOUBLE` are retrieved as `SQL_C_FLOAT`/`SQL_C_DOUBLE` and rendered with
PostgreSQL's own `float4out`/`float8out`, because a driver's text rendering is
not required to round-trip: SAP HANA renders 15 significant digits, losing the
17th digit of a full-precision double and rendering `DBL_MAX` as a value larger
than `DBL_MAX` that PostgreSQL rejects. Keep `float4` separate from `float8`;
widening a real to a double prints `0.10000000149011612` where PostgreSQL
prints `0.1`. Never format a float by hand here.

Measured: Microsoft ODBC Driver 18 reproduces the silent decimal loss on
`DECIMAL(38,2)`, and so does SAP HANA. psqlODBC and MySQL Connector/ODBC
undersize identically and lose nothing only because they honour the
continuation call, so a suite passing on those two proves nothing about the
sizing.

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
`SQL_C_WCHAR`; others return INCORRECT DATA through the wide target without an
error. Keep this product-neutral: `wide_char_mode` selects the behavior on the
foreign server or table, defaults to `char`, and must never be inferred from a
database or driver product name. A table value wins over its server value.

DO NOT change the default to `wchar`, and do not probe or fall back
automatically. This was tried and reverted on measurement. `SQL_C_WCHAR` is the
C type ODBC pairs with the wide SQL types, so defaulting to it looks obviously
correct, and it is byte-identical on MySQL Connector/ODBC and Microsoft ODBC
Driver 18 while psqlODBC and SQLite ODBC report no wide types at all — four
drivers giving no reason not to. The SAP HANA client then returns its UTF-8
bytes zero-extended into `SQLWCHAR` units rather than UTF-16, so every byte
becomes a code point and the value arrives double encoded, silently: `Grüße` as
11 bytes rather than 7, byte-exact through `SQL_C_CHAR` in the same scan.

That is the whole argument for the option existing. A driver returning
corrupted text instead of an error cannot be distinguished from one returning
the truth, so no amount of evidence from other drivers licenses a default.

The driver's own `CHAR_AS_UTF8` connection property does the SAME DAMAGE, and it
is worth knowing before recommending it: passed through as
`odbc_CHAR_AS_UTF8 'TRUE'`, it produces byte-for-byte the same double encoding
as the wide target -- `Grueszlige` as 11 bytes, md5 `d38ba5b3...`, against 7
bytes and `49c5f675...` without it. The pass-through mechanism works; the
setting is what corrupts. On this tenant, driver and image, a plain server with
NO character options is the configuration that is byte-exact, and both remedies
recorded against this driver elsewhere make it worse.

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

### A derived type must not invent a scale

`SQLColumns` reports `DECIMAL_DIGITS` as NULL for a type where it does not
apply, which is how a driver describes a decimal whose scale belongs to each
VALUE rather than to the column. Treating that NULL as 0 renders
`numeric(column_size, 0)`, and PostgreSQL then ENFORCES that scale, so the
import rounds every fractional part away at DDL time and no later scan can
recover it.

Keep the two distinguishable. `ODBC_SCALE_UNKNOWN` carries "the driver would not
say" through to `sql_data_type`, which emits an unconstrained `numeric` when
either the precision or the scale is unknown. An unconstrained `numeric` holds
everything a `numeric(p,s)` holds and rounds nothing. A stated scale of 0 keeps
its modifier, and that case must keep working, or the fix has merely become
"drop every modifier".

Measured, SAP HANA Client 2.29.25, `SQLColumns`: `SMALLDECIMAL` and
unconstrained `DECIMAL` report `DECIMAL_DIGITS` NULL, `DECIMAL(18,4)` reports 4,
`DECIMAL(38,0)` reports 0. Before the fix a remote `3.14159` imported as `3` and
a remote `-0.00001` imported as `0`.

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
