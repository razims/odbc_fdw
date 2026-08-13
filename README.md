# odbc_fdw — Softinent's ODBC foreign-data wrapper

A PostgreSQL extension that reads any [ODBC](https://learn.microsoft.com/sql/odbc/reference/odbc-programmer-s-reference)
data source as foreign tables. This is **Softinent's maintained wrapper**: our
release cadence, our resource ceilings, and a set of memory-safety fixes that
the lineage it comes from does not have.

Built and tested against **PostgreSQL 18**. Nothing here is version-specific
beyond what PGXS provides, but 18 is the only major version this release has
been compiled and exercised on, so it is the only one claimed.

| | |
| --- | --- |
| Extension name | `odbc_fdw` |
| This release | `1.0.0` — the git tag and `default_version` are the same string |
| Licence | PostgreSQL licence, see [`LICENSE`](LICENSE) |
| Requires | unixODBC (`libodbc`), plus an ODBC driver for whatever you are reading |

---

## Provenance

This is not original work, and the lineage matters because the fixes below are
defects **in that lineage** rather than local policy:

- originally written by **Zheng Yang** in 2011, with a PostgreSQL Global
  Development Group copyright;
- updated for PostgreSQL 9.2+ by **Gunnar "Nick" Bluth**, based on `tds_fdw`
  by Geoff Montee;
- developed by **CARTO** from 2016 as
  [`CartoDB/odbc_fdw`](https://github.com/CartoDB/odbc_fdw), which was archived
  on 2026-01-05;
- carried forward by **Devrim Gündüz** as
  [`devrimgunduz/odbc_fdw`](https://github.com/devrimgunduz/odbc_fdw), the
  source of PGDG's `odbc_fdw_18` yum package;
- **derived here from `devrimgunduz/odbc_fdw` at commit `ee741f5`, its tag
  `0.6.1`.**

Every copyright notice from that lineage is retained in the files that carry
it, and `LICENSE` is byte-identical to what we received. `Copyright (c) 2026,
Softinent` is added *beside* those notices in the files we substantially
modify, never in place of them. That is the licence's one condition, and it is
not a formality — do not "tidy" any of it away.

The five defect fixes and the zero-column import refusal are candidates for
upstreaming, and we intend to offer them. They are not offered yet, and nothing
here waits on that: issues are disabled on `devrimgunduz/odbc_fdw`, so a pull
request is the only channel there, and these fixes are load-bearing for a
production warehouse today.

Changes to this repository go to Softinent, not upstream. If you have arrived
here looking for stock `odbc_fdw`, the two repositories above are it.

---

## Installing

```sh
# Debian/Ubuntu build dependencies: PostgreSQL server headers, and unixODBC.
apt-get install -y build-essential postgresql-server-dev-18 unixodbc-dev

make USE_PGXS=1
sudo make install USE_PGXS=1
```

`USE_PGXS=1` is inert at this release — the Makefile includes
`$(PG_CONFIG) --pgxs` unconditionally — and is accepted so that the usual
invocation works. Point the build at a specific installation with
`PG_CONFIG=/path/to/pg_config`; on Debian and its derivatives that is
`/usr/lib/postgresql/18/bin/pg_config`, not anything under `/usr/local`.

`SHLIB_LINK = -lodbc` links against the unixODBC **driver manager**, which is
all the build needs. The runtime package on Debian 13 is `libodbc2`
(`libodbc.so.2`); `libodbc1` does not exist there. A **driver** for the remote —
psqlODBC, FreeTDS, SAP's `libodbcHDB.so`, anything else — is loaded by the
driver manager at connect time, so it is not needed to build, nor to run
`CREATE EXTENSION`, and its absence surfaces only at the first foreign scan
as `[unixODBC][Driver Manager] Can't open lib`.

Drivers must be registered in `/etc/odbcinst.ini`. `odbcinst -q -d` lists what
the driver manager can actually see, which is the only check that reads that
file the way a connection will.

Then, per database:

```sql
CREATE EXTENSION odbc_fdw;
```

### Docker-only development

Docker is the supported development environment. It fixes the PostgreSQL major,
compiler, PGXS headers and unixODBC versions at the same values used for the
release target; no host PostgreSQL installation is needed.

```sh
make docker-build  # build the PostgreSQL 18 development image
make docker-shell  # open a shell with this checkout mounted at /workspace
make docker-test   # compile, install and run the credential-free ODBC smoke test
```

`docker-test` starts a disposable PostgreSQL 18 instance and reaches a second
database in that instance through Debian's psqlODBC driver — a real ODBC remote,
so the whole path is exercised rather than only the parts reachable without one.
It checks that the built library loads, that `IMPORT FOREIGN SCHEMA` works, that
a scan returns the expected values, that the validator refuses a malformed
ceiling at DDL time, that each of the three ceilings refuses at its boundary
*while the same scan succeeds under the other two*, that a foreign table cannot
raise a ceiling set on its server, and that a rescanned foreign scan restarts.
It also carries a deliberately-invalid C symbol control, which is what makes the
success of `CREATE EXTENSION` evidence that symbol resolution was checked rather
than assumed.

Two honest caveats. The smoke test needs no credentials, but **building the
image needs network access to SAP**, because the development image bakes the HANA
client described below — there is no offline build. And upstream's `test/`
regression harness is not part of any of this; see Testing at the end.

### Optional HANA 2.0 probe

The HANA suite is opt-in and never contacts a tenant during the normal smoke
test. The Docker development image **does** bake SAP HANA Client 2.29.25 during
its build: only `libodbcHDB.so` and `libSQLDBCHDB.so`, fetched over HTTPS and
verified against pinned archive and per-library SHA-256 values for `amd64` and
`arm64`. Copy `.env.example` to `.env` and add the tenant connection details
plus the dedicated existing `HANA_SCHEMA`. The gitignored `.env` is never copied
into the Docker build context or image.

```sh
cp .env.example .env
# Edit .env locally, then create or replace only ODBC_FDW_* fixture tables:
make docker-hana-seed
make docker-hana
# Remove just those fixture tables when finished:
make docker-hana-clean
```

The seed never creates or drops `HANA_SCHEMA`; it creates, replaces or removes
only its `ODBC_FDW_DATA_TYPES`, `ODBC_FDW_LARGE_VALUES` and `ODBC_FDW_SINGLE_ROW`
tables. Give the configured account rights only on that dedicated test schema.

The suite creates a disposable local PostgreSQL instance and uses the HDBODBC
driver registered in the development image. It checks direct case-insensitive
column binding, schema+table qualification, `IMPORT FOREIGN SCHEMA`, `sql_query`,
NULLs, numeric/date/time/timestamp values, Unicode, a 12 KB NCLOB, BLOB bytes,
and a correlated rescan. It also checks DDL-time invalid-limit rejection, all
three resource ceilings, and the zero-column import refusal. It prints only
assertion names and pass/fail results, never the connection string, password or
tenant values. The suite sets `ENCRYPT=true` when requested but deliberately
sets `SSLVALIDATECERTIFICATE=false`, matching the known-working encrypted probe
configuration; it does not establish certificate validation.

---

## Usage

Connection state is spread across three objects and concatenated when a
foreign table is read: the **server**, the **user mapping** for the connecting
role, and the **foreign table** itself.

### The `odbc_` prefix — read this before naming any option

An option named `odbc_<something>` is **passed straight through to the ODBC
connection string** as a driver attribute. It is not interpreted by this
extension at all.

```sql
CREATE SERVER src FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
  odbc_driver     'PostgreSQL Unicode',   -- becomes DRIVER=...
  odbc_servername '10.0.0.5',             -- becomes servername=...
  odbc_port       '5432');
```

Three consequences that are easy to get wrong, all measured:

1. **The prefix is matched case-sensitively.** `is_odbc_attribute` compares it
   with `strncmp`, so a name whose *prefix* carries capitals is not recognised
   as a connection attribute. On a server or a user mapping that is refused
   outright (`ERROR: invalid option "ODBC_UID"`); on a **foreign table** it is
   accepted **silently**, because a table's options double as column mappings,
   so the name simply becomes one and does nothing.
2. **PostgreSQL folds an unquoted option name to lower case before this
   wrapper sees it**, so `odbc_DRIVER` and `odbc_driver` are the same option and
   both work. The case-sensitivity above therefore only bites when the name is
   double-quoted — `"ODBC_SERVERNODE"` is refused, `odbc_SERVERNODE` is not.
   Writing every name in lower case sidesteps the whole question.
3. `DSN`, `DRIVER`, `UID` and `PWD` are normalised to upper case on the way to
   the driver regardless. Any other attribute reaches the driver spelled as it
   is stored, so a driver wanting case-sensitive attribute names needs the
   option name double-quoted: `OPTIONS ("odbc_ServerName" '10.0.0.5')`.

An attribute *value* containing `=` or `;` needs curly braces:
`OPTIONS ("odbc_PWD" '{xyz=abc}')`.

**Our own options are deliberately NOT `odbc_`-prefixed**, and that is a
correctness requirement rather than a style choice: a prefixed name would be
handed to the driver instead of being read here. Do not add one that is.

### Credentials

Put them in a user mapping, so they are chosen by the connecting PostgreSQL
role:

```sql
CREATE USER MAPPING FOR someone SERVER src
  OPTIONS (odbc_uid 'remote_login', odbc_pwd 'secret');
```

Any attribute may legally be set on any of the three objects, but a credential
should only ever go here. A **server**'s options are readable by every role
(`pg_foreign_server.srvoptions`) and travel in every `pg_dump`; a user
mapping's are blanked for anyone but the server's owner
(`pg_user_mappings.umoptions`). Since ODBC accepts `UID` and `PWD` in the
connection string, a server option can legally *be* a password — which is why
this wrapper offers no generic `option key=value` pass-through and why our
ceilings refuse credential-shaped names.

### Pointing a foreign table at the remote

| option | where | description |
| --- | --- | --- |
| `schema` | table, import | remote schema to read from |
| `table` | table, import | remote table; also the local name for a `sql_query` table |
| `sql_query` | table, import | SQL to run instead of reading `table`, in the remote's own dialect |
| `sql_count` | table | SQL to count rows, for planner estimates |
| `prefix` | import | prefix for the names of imported foreign tables |
| `dsn` | server | Data Source Name, if you use one |
| `driver` | server | driver name, if you do not |
| `encoding` | server, table | remote encoding, named as PostgreSQL names it |

Anything else on a foreign table that is not one of ours and not `odbc_`-prefixed
is taken as a **column name mapping**. That is why an unrecognised table option
is silently accepted, and why our option names are claimed explicitly before
that fallthrough.

```sql
CREATE FOREIGN TABLE ext.orders (
    id      integer,
    label   text,
    created timestamp)
  SERVER src
  OPTIONS (schema 'sales', "table" 'orders');
```

`IMPORT FOREIGN SCHEMA` reads the remote's own metadata instead:

```sql
IMPORT FOREIGN SCHEMA sales LIMIT TO ("Orders") FROM SERVER src INTO ext;
```

**Double-quote the names in `LIMIT TO`.** PostgreSQL folds an unquoted
identifier to lower case before this wrapper is reached, and against a remote
that folds *up* — SAP HANA, Oracle, DB2 — the folded name does not exist there.
The names in `LIMIT TO` are taken verbatim from the parsed statement and are
**not** checked against the remote, unlike the enumerated and `EXCEPT` paths,
which build their list from `SQLTables`. Upstream therefore accepted a name the
remote had never had and created a foreign table with no columns; this release
refuses that (see below), but it can only diagnose — the name is already folded
by the time it arrives, so nothing here can recover what was meant.

---

## Our options: resource ceilings

Three of them, all intended for a shared warehouse where a foreign table points
at somebody else's production database:

| option | unit | default | refuses |
| --- | --- | --- | --- |
| `max_field_size` | bytes | `0` (unlimited) | any single field value larger than this |
| `max_row_count` | rows | `0` (unlimited) | a scan returning more rows than this |
| `max_result_size` | bytes | `0` (unlimited) | a scan retrieving more than this in total |

```sql
CREATE SERVER src FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
  odbc_driver 'HDBODBC', odbc_servernode 'host:30015',
  max_field_size  '1048576',      -- 1 MiB in any one value
  max_row_count   '10000000',
  max_result_size '2147483648');  -- 2 GiB across the whole scan
```

`max_result_size` exists because the other two do not compose into a bound on
the whole result: 200 columns of 1KB across 10,000,000 rows violates neither.
It is the ceiling on the product. Measured — a scan with `max_field_size 1000`
and `max_row_count 5000` both satisfied still retrieved 221,786 bytes; the same
scan with `max_result_size 50000` is refused at 50,054, and the error names the
running total.

Rules that apply to every one of them, and to any added later:

- **Valid on a foreign server and on a foreign table**, not on a user mapping.
- **Non-negative integer**, no unit suffixes. `0` means unlimited and is the
  default, so a configuration that sets none behaves exactly as it did before
  these existed.
- **Validated at DDL time**, in the validator, so `CREATE SERVER` and
  `CREATE FOREIGN TABLE` refuse a bad value instead of reporting success and
  failing later in an unrelated query:
  `ERROR: option "max_row_count" requires a non-negative integer, got "lots"`.
- **Tightest wins.** A table may lower a ceiling its server sets; it can never
  raise one. `0` on a table does not lift a server's ceiling. This is
  deliberately not the last-wins resolution upstream uses for every other
  option: a ceiling that can be raised from the object it constrains is not a
  ceiling, and folding to the minimum also makes the outcome independent of the
  order in which the option lists happen to be concatenated.
- **They refuse rather than truncating.** Returning the first N rows of a
  larger result, or a shortened field, is a wrong answer, which is worse than
  no answer.
- **Per scan, not per query, session or transaction.** A query reading two
  foreign tables gets a fresh count for each, and a plan that rescans a foreign
  table — a correlated subquery, a nested loop — restarts the counters on each
  rescan. That is deliberate: a ceiling is a statement about how much one scan
  may return, and how many times a scan happens is the planner's choice rather
  than the operator's.

**What they do not do.** The ODBC driver runs **inside the PostgreSQL backend**.
A fault in the driver is a `SIGSEGV`, and PostgreSQL's response to a backend
dying on a signal is to SIGQUIT every other backend and replay WAL — so it is
crash recovery for **every session in every database on the instance**, not one
failed query. No option here changes that; only a process boundary would. These
ceilings bound what a runaway *remote* can make **this extension** allocate,
which makes such a remote survivable. They are not isolation and must not be
described as if they were.

Four more things they specifically do not bound, because a ceiling that reads as
protection it does not give is worse than none:

- **the backend's real memory high-water mark.** They count the bytes this
  extension retrieves into its own field buffer. A binary column is then
  hex-encoded to twice that, and the `StringInfo` and the heap tuple are further
  copies, so the footprint is a multiple of what is counted, not equal to it.
- **anything above the scan.** A sort, hash or tuplestore built from these rows
  is bounded by `work_mem`, not by these options.
- **time, or the number of round trips.** A scan can sit inside every ceiling and
  still take hours. `statement_timeout` is the tool for that, and it cannot
  interrupt a blocked driver call either — see fix 6 below.
- **the metadata paths.** `IMPORT FOREIGN SCHEMA`, `ODBCTablesList`,
  `ODBCTableSize` and `ODBCQuerySize` do their own reads and are not counted.

---

## What this release fixes relative to `ee741f5`

Four defects, each measured against a real SAP HANA 2.0 tenant, and the first
two independently reproduced against psqlODBC — so they are defects in the
wrapper, not quirks of one driver. The commit messages carry the measurements;
`git log` is the reference, and this is the summary.

1. **An empty catalog separator produced a malformed identifier.**
   `getNameQualifierChar` asks the driver for `SQL_CATALOG_NAME_SEPARATOR` and
   used the answer verbatim to join a *schema* to a table name. Those are not
   the same thing: a database with no catalogs may correctly report it empty,
   and HANA does. The emitted text was `"SYS""DUMMY"` — one identifier
   containing an escaped quote. Now defaults to `.`, in the one function both
   call sites use, so the failure cannot move one step later into the scan.

2. **`values[]` was undersized, misindexed and uninitialised.** It was
   `palloc`'d by the number of *result* columns while every write indexes it by
   position in the *foreign table*, and `BuildTupleFromCStrings` reads `natts`
   entries regardless — so a table with more columns than the query returns
   overran the allocation. And `palloc` does not zero, while a result column
   matching no table column is skipped, leaving its slot uninitialised for
   `BuildTupleFromCStrings` to dereference as a C string. That single read of
   undefined memory accounts for the whole original symptom set: correct row and
   column counts with wrong values — a literal arriving empty, a known `'X'`
   arriving NULL, an integer arriving `""`, schema names arriving as `\x03` —
   and an intermittent `SIGSEGV`. Now `palloc0` sized by `natts`, which makes an
   unmatched column a SQL NULL: the honest answer for a column the remote did
   not return.

3. **Result columns were matched to foreign-table columns case-sensitively.**
   PostgreSQL folds identifiers down, HANA and Oracle and DB2 fold up, and the
   code used `strcmp` — so a hand-written foreign table's columns could never
   match, and were dropped from the mapping with no error at all. Now
   `pg_strcasecmp`, PostgreSQL's own locale-independent ASCII compare.

4. **Three errors in the chunked `SQLGetData` loop.** A control-flow decision
   made by reading a chunk's last byte without regard for how many bytes the
   driver wrote — uninitialised heap for any value shorter than the chunk. An
   ODBC *indicator* (`SQL_NULL_DATA` = −1, `SQL_NO_TOTAL` = −4) added to a
   running length total unchecked, driving it negative and running a
   `strnlen(buffer, (size_t) -1)` on every NULL. And `SQL_NO_DATA` from a
   continuation call treated as failure, which broke **every** `TIMESTAMP`,
   with a bare "Reading data" error because `SQL_NO_DATA` carries no diagnostic
   record.

5. **`ReScanForeignScan` did nothing, so a rescanned foreign table returned no
   rows.** The callback's contract is that the scan restarts from its first row,
   and nothing else repositions an ODBC cursor — so the second and every later
   scan of the same node came back empty. Measured with a correlated subquery
   over three local rows: the first returned its value and the other two
   returned NULL, with no error, no warning and no notice. It hides behind a
   `Materialize` or `Memoize` node whenever the planner inserts one, so whether
   a query was wrong depended on a cost estimate. Now the statement is
   re-executed and the ceiling counters restart with the scan.

Plus, beyond the defects:

6. **A large single field is cancellable.** `CHECK_FOR_INTERRUPTS()` inside the
   chunked read, which is the one part of a scan PostgreSQL's own per-tuple
   check cannot reach. There is deliberately **no** check at the row boundary,
   and a comment in the source says so: `ExecScan` already checks once per
   tuple, measured three ways. This bounds the loop, not the driver — a driver
   blocking inside one `SQLGetData` still cannot be interrupted.

7. **The retrieval path is bounds-checked**, so a wrong length from a driver
   raises rather than corrupting memory: a negative buffer extent, a
   non-positive `BufferLength` passed to `SQLGetData`, impossible
   `resize_buffer` geometry, a 64-bit driver total truncating through `(int)`,
   a write at `buffer[-1]`, and `binary_to_hex` overflowing `int`. Refused
   rather than clamped throughout, because a length that has already gone wrong
   means the arithmetic is wrong, and reading a different amount than the driver
   was asked for would convert a detectable fault into a wrong answer.

8. **`IMPORT FOREIGN SCHEMA` refuses to create a zero-column foreign table.**
   `CREATE FOREIGN TABLE x () SERVER s` is something PostgreSQL accepts quite
   happily, so an import could report success and leave an object that fails
   only later, in somebody else's query, with an error about the remote rather
   than about the import. It costs no extra remote work — `SQLColumns` has
   already answered and the answer was being discarded — and the hint
   distinguishes a name that was quoted from one PostgreSQL may have folded.

---

## Known defects, not fixed here

Written down so they are not rediscovered in production. All three are
pre-existing behaviour from the lineage, all three were observed while building
this release, and none is fixed.

1. **A cancelled or failed scan leaks the remote connection.**
   `odbcEndForeignScan` is the only place the ODBC `env`/`dbc`/`stmt` handles
   are freed, and the executor does not call it when a scan errors out — so
   every error raised from inside a scan leaks a driver connection for the life
   of the backend. Measured: three cancelled scans left three additional
   sessions open on the remote. This is the one item here with a consequence on
   **somebody else's server** that nothing on ours reveals, and connection
   pooling makes it worse, because the backend outlives the client that caused
   the scan. The fix, if taken, is a transaction or resource-owner callback, the
   way `postgres_fdw` does it with `pgfdw_xact_callback`.

2. **Reading one field is quadratic in its length.** `resize_buffer` allocates
   and `memmove`s the whole accumulated value on *every* chunk, and chunks are
   capped at 8192 bytes, so an *n*-byte value costs on the order of
   *n²/16384* bytes of copying. Measured: a single 60,000,000-character NCLOB
   took about 10 seconds to read, almost none of it waiting on the network. The
   fix is to grow geometrically; the `TODO` already in the function says as much.

3. **`SQL_VARBINARY` (−3) is not mapped, so `VARBINARY` arrives as hex text.**
   `sql_data_type` maps only `SQL_LONGVARBINARY` (−4) to `bytea`, so a column
   the driver reports as `SQL_VARBINARY` falls through to the text path and the
   driver's hexadecimal *rendering* is stored as if it were the value. Measured:
   `CAST('ABCD' AS VARBINARY(10))` read back as `\x3431343234333434` — the ASCII
   of the string `"41424344"` — instead of `\x41424344`. `SQL_BINARY` (−2) is
   presumably affected the same way and was not tested. A silent wrong *type*,
   which is the same class as the defects above; unfixed only because changing a
   type mapping changes existing foreign tables and needs measuring against more
   than one driver.

---

## Versioning

**One string, in both namespaces.** The annotated git tag and
`default_version` in `odbc_fdw.control` are the same characters — `1.0.0` for
this release. Upstream let those two drift (tag `0.6.1`, `default_version`
`0.5.2`), which forces every consumer to carry both literals by hand and means
nothing readable from SQL can identify the build. That is over.

Ordinary semver from here, and **every release bumps it**:

| change | bump |
| --- | --- |
| a C-only fix | patch |
| a new option | minor |
| anything that changes existing behaviour | major |

Each bump renames the SQL script to `odbc_fdw--<new>.sql` and adds
`odbc_fdw--<prev>--<new>.sql` so that `ALTER EXTENSION odbc_fdw UPDATE` works.
For a C-only change that upgrade script is **empty**, and writing an empty file
is the right thing to do: the alternative is telling operators to
`DROP EXTENSION`, which `CASCADE`s away their foreign tables and every view
built over them.

`0.5.2` must never be declared again, by anything. A consumer gates on
`default_version` appearing in an allowlist of builds whose data path has been
measured correct, and stock upstream reports exactly `0.5.2` — so allowlisting
that string would admit the build with the wrong values alongside the one with
the right ones.

---

## Limitations

- Column, schema and table names are subject to PostgreSQL's
  [`NAMEDATALEN`](https://www.postgresql.org/docs/current/sql-syntax-lexical.html)
  limit of 63 bytes, and a longer name is **truncated with only a notice**.
- Read-only. There is no `INSERT`, `UPDATE` or `DELETE` path, and the wrapper
  pushes down nothing but the query you write in `sql_query`.
- Column types `IMPORT FOREIGN SCHEMA` can map, read from `sql_data_type`:
  `SQL_CHAR`, `SQL_WCHAR`, `SQL_VARCHAR`, `SQL_WVARCHAR`, `SQL_LONGVARCHAR`,
  `SQL_WLONGVARCHAR`, `SQL_DECIMAL`, `SQL_NUMERIC`, `SQL_INTEGER`, `SQL_REAL`,
  `SQL_FLOAT`, `SQL_DOUBLE`, `SQL_BIT`, `SQL_BOOLEAN`, `SQL_SMALLINT`, `SQL_TINYINT`,
  `SQL_BIGINT`, `SQL_DATE`, `SQL_TYPE_DATE`, `SQL_TIME`, `SQL_TYPE_TIME`,
  `SQL_TIMESTAMP`, `SQL_TYPE_TIMESTAMP`, `SQL_GUID` and `SQL_LONGVARBINARY`.
  Anything else is reported as a `NOTICE` and skipped. `SQL_BINARY` and
  `SQL_VARBINARY` are **not** in that list — their arms are commented out
  upstream with a `TODO` — which is the mechanism behind known defect 3 above.
  (`SQL_BIT` and `SQL_BOOLEAN` are missing from upstream's own README; both map
  to `boolean`.)
- Remote encodings are handled with the `encoding` option, for any encoding
  PostgreSQL supports and that is compatible with the local database, named as
  [PostgreSQL](https://www.postgresql.org/docs/current/multibyte.html) names it.

---

## Testing

`test/` is upstream's regression harness, and it **needs a live ODBC source** —
MySQL, SQL Server, Hive or PostgreSQL, registered in `odbcinst.ini`, with
fixtures loaded and a connector config that upstream's CI supplied from an
encrypted bundle. `make installcheck` and `make integration_tests` therefore do
not run on a workstation, and the `.travis.yml` and `.appveyor.yml` that drove
them belong to infrastructure we do not have. It is kept because it is the only
description of what a multi-driver test would check; it is not a gate.

What is runnable, and what this release was verified with, is in
[`CLAUDE.md`](CLAUDE.md): a `postgres:18-trixie` container plus
`postgresql-server-dev-18`, `unixodbc-dev` and `odbc-postgresql`, using
psqlODBC pointed back at the container's own PostgreSQL as a real ODBC remote.
