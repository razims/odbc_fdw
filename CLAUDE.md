# CLAUDE.md

Instructions for working in this repository.

## What this is

Softinent's vendored **ODBC foreign-data wrapper for PostgreSQL**, derived from
`devrimgunduz/odbc_fdw` at commit `ee741f5` (its tag `0.6.1`), itself derived
from CartoDB's `odbc_fdw`. One C file does essentially all the work
(`odbc_fdw.c`, ~3000 lines) plus a control file, a SQL script and a PGXS
Makefile. There is no application here: it is a shared library loaded into a
PostgreSQL backend, so almost every mistake is a memory-safety mistake.

**Target: PostgreSQL 18.** That is the only major version this release has been
compiled and exercised against, and the only one the README claims. It is
consumed by Softinent's `dwh` warehouse, whose image clones this repository **by
tag** and asserts the commit — so a moved tag breaks that build, by design.

Read `README.md` first. It is the published documentation and the single
authority on behaviour; this file is for whoever is *changing* the code.

## Keep the documentation current

`README.md`, `NEWS.md` and this file are living documents. There is no test
suite that can run on a workstation (see Testing), so prose is a larger share of
the safety net here than it would be in an ordinary repository — a stale claim
gets trusted.

| Changed | Also update |
| --- | --- |
| an option added, renamed or removed | `valid_options[]`, `extract_odbcFdwOptions`, the validator, README's option table, this file |
| `default_version` | the SQL script's filename, `Makefile`'s `DATA`, a new `odbc_fdw--<prev>--<new>.sql`, `NEWS.md`, README's Versioning section, and the annotated tag |
| a defect fixed | README "What this release fixes", and remove it from "Known defects" if it was listed there |
| a defect found and not fixed | README "Known defects, not fixed here" — writing it down is the deliverable |
| a type mapping in `sql_data_type` | README's supported-types list |

## Invariants — do not "simplify" these

Each of these was a real defect, or the direct cause of one. They look like
oversights. They are not.

**An option name prefixed `odbc_` is passed STRAIGHT INTO the ODBC connection
string.** `is_odbc_attribute` recognises it and this extension never interprets
it. Consequences, all measured:

- The prefix is compared with `strncmp`, so it is **case-sensitive**. A name
  whose prefix carries capitals is not recognised as a connection attribute.
- What happens then depends entirely on context, and one arm is silent. On a
  **server**: `ERROR: invalid option "ODBC_SERVERNODE"`. On a **user mapping**:
  `ERROR: invalid option "ODBC_UID"`, hint `Valid options in this context are:
  <none>`. On a **foreign table**: **accepted silently**, because a table's
  options double as column-name mappings, so the name becomes one and does
  nothing.
- PostgreSQL folds an **unquoted** option name to lower case before the
  validator sees it, so `odbc_DRIVER` and `odbc_driver` are one option. The
  case-sensitivity above therefore only bites on a **double-quoted** name.
  Verified: `"ODBC_SERVERNODE"` is refused, `odbc_SERVERNODE` is accepted and
  stored as `odbc_servernode`; `"odbc_ServerName"` is accepted with its case
  preserved.

So: **never give one of our own options an `odbc_` prefix**, and never add a
generic `option key=value` pass-through. ODBC accepts `UID` and `PWD` in a
connection string, which means such an option can legally *be* a password — and
`pg_foreign_server.srvoptions` is readable by every role and travels in every
`pg_dump`, unlike a user mapping's options, which `pg_user_mappings` blanks for
anyone but the server's owner. Confirmed from the other side while building the
ceilings: `odbc_MAX_ROW_COUNT` on a server reached the driver, which ignored it,
and bounded nothing.

**Our option names must be claimed in `extract_odbcFdwOptions` BEFORE the
column-mapping fallthrough.** An unrecognised foreign-table option there is
taken for the name of a remote column. A new option that is registered in
`valid_options[]` but not claimed in extraction is therefore not
"silently ignored" — it becomes a column mapping and changes the query.

**Ceilings fold TIGHTEST WINS, never last-wins.** `odbcGetOptions` concatenates
table options, then server options, then user-mapping options, and extraction
assigns as it goes — so a plain assignment makes the **server's** value win by
position, and any reordering of those lists would let a **table raise** a
ceiling an operator set on the server. A ceiling that can be raised from the
object it constrains is not a ceiling. `apply_limit_option` folds to the
minimum, which also makes the outcome independent of that order, so it cannot
change if upstream reorders the concatenation. `0` means unlimited and therefore
**loses** to any positive value; it can never loosen a ceiling already in force.
Measured in all three directions: server 50 with a table asking 1000000 is
refused at 50, a table asking 10 is refused at 10, and a table asking 0 is still
refused at 50.

**Ceiling values are validated in the VALIDATOR, at DDL time.** They were not
at first, and it was measured: `max_row_count 'lots'`, `max_field_size '-1'` and
`max_field_size '100MB'` were all accepted by `CREATE SERVER` and
`CREATE FOREIGN TABLE`, with the complaint deferred to the first query — so the
DDL containing the mistake reported success and something unrelated failed
later. A ceiling nobody can tell they set wrongly is worse than no ceiling. The
validator's sink is per-option and discarded: only the parse and the range
matter there, not the folding.

**`max_field_size` is enforced in TWO places and both are required.** The check
inside the chunk loop bounds *memory* while the value is still being assembled,
so a runaway field is refused at ceiling-plus-one-chunk rather than after the
whole thing exists — but it runs *before* each chunk, so a value arriving in a
single chunk never reaches it. The check after the loop is the exact one, on the
value's real length. Measured both arms: a 12000-byte value against a ceiling of
5000 is caught mid-assembly (the message carries no length), a 100-byte value
against a ceiling of 10 is caught by the exact test (the message carries `100
bytes`).

**There is deliberately NO `CHECK_FOR_INTERRUPTS()` at the row boundary in
`odbcIterateForeignScan`, and a comment in the source says so.** This is a
measured negative result, not an omission: `ExecScan` already checks interrupts
once per tuple a scan node returns, and this FDW is only ever driven from there
(`odbcAnalyzeForeignTable` returns false, so `ANALYZE` does not sample, and
`IterateForeignScan` has no other caller). Measured against a live tenant with
`statement_timeout = 5s` on a 3,000,000-row scan and **no** check anywhere in
the extension, using three shapes that put the per-tuple loop in three different
places — `COPY` of every row, `count(*)`, and a non-pushed-down qual matching
nothing. All three were cancelled at 5s. Adding one there would be redundant. The
check that *is* needed is one level down, inside the chunked read, which is the
only part of a scan PostgreSQL cannot reach.

**Bad lengths are REFUSED, never clamped.** Every guard in the retrieval path
raises rather than reading a different amount than the driver was asked for. A
length that has already gone wrong means the arithmetic is wrong, and quietly
reading around it converts a detectable fault into a wrong answer — which is the
failure mode this repository exists to eliminate, not one to add.

**A ceiling is not isolation, and the README must never imply it is.** The ODBC
driver runs **inside the backend**. A fault in the driver is a `SIGSEGV`, and
PostgreSQL's `HandleChildCrash` SIGQUITs every other backend and replays WAL —
crash recovery for every session in every database on the instance. Only a
process boundary would change that. The ceilings bound what a runaway *remote*
can make *this extension* allocate, and nothing more. Say exactly that.

**`palloc` does not zero; `palloc0` does.** The single worst defect in this
lineage was one `palloc` whose slots were then read as C strings. Any array
handed to `BuildTupleFromCStrings` is sized by `natts` — the FOREIGN TABLE's
column count — and zeroed, because a result column that matches no table column
is skipped and its slot must be a SQL NULL rather than whatever was on the heap.

**Identifier comparison uses `pg_strcasecmp`, not `strcmp` and not
`strcasecmp`.** PostgreSQL folds unquoted identifiers **down**; SAP HANA, Oracle
and DB2 fold **up**. `strcmp` therefore never matched and dropped the column
silently. `strcasecmp` is locale-dependent and is the wrong tool for an
identifier; `pg_strcasecmp` is PostgreSQL's own locale-independent ASCII
compare, used throughout the backend for exactly this.

**`SQL_CATALOG_NAME_SEPARATOR` describes a CATALOG separator, and this code uses
it to join a SCHEMA to a table.** They are not the same thing, so a driver for a
database with no catalogs may correctly report it empty. Defaulted to `.` in
`getNameQualifierChar` rather than at a call site, so both places that build a
qualified name are covered — patching only one moves the failure one step later.

**`result_size` from `SQLGetData` is an INDICATOR, not always a length.**
`SQL_NULL_DATA` is −1 and `SQL_NO_TOTAL` is −4. Adding it to a running total
unchecked drove the total negative and ran `strnlen(buffer, (size_t) -1)`. Any
new arithmetic on a driver-reported length gets the same treatment: check the
sign, check the range, refuse.

**`ldd` proves that LINKED dependencies resolve, and nothing else.**
`odbc_fdw.so` links only the unixODBC **driver manager**; the actual driver is
`dlopen`ed by the driver manager at *connect* time. So a build can be clean, the
`.so` can load, `CREATE EXTENSION` can succeed, a server can be created — and
the first foreign scan still fails with `[unixODBC][Driver Manager] Can't open
lib`. `odbcinst -q -d` is the only check that reads `/etc/odbcinst.ini` the way
a connection will.

**Never assert an installed file with a glob.** `odbc_fdw--*.sql` matched the six
historical upgrade scripts whether or not the file `CREATE EXTENSION` needs was
built, so it was an assertion that could not fail for the reason it claimed.
Those scripts are gone, and any future check names the file it means.

## Licence and attribution — a condition, not a courtesy

The licence is an MIT-style grant permitting exactly what we are doing, on one
condition: the notice travels with the software. Meet it precisely.

- **`LICENSE` stays byte-identical.** Do not reword, relicense or move it.
- **Every existing copyright notice stays**, wherever it is: PostgreSQL Global
  Development Group 2011, CARTO (2016 in the Makefile, 2016–2018 in the control
  file, 2016–2020 in the SQL script), Zheng Yang and Gunnar "Nick" Bluth as
  authors in `odbc_fdw.c`, Devrim Gündüz in `LICENSE`.
- The files do **not** carry the same set of notices and must not be made
  uniform. `odbc_fdw.c` has no CARTO line; adding one would be inventing a
  notice on somebody else's behalf.
- **`Copyright (c) 2026, Softinent` goes BELOW** the existing lines, in files we
  substantially modify. Keep the year current for new work.
- The README states provenance in its own right. A cleanup pass that turns it
  into a footnote is a regression.

## Versioning

**One string, in both namespaces.** The annotated git tag and `default_version`
in `odbc_fdw.control` are the same characters. This release is `1.0.0`, with no
`v` prefix, because the tag has to be a string PostgreSQL will accept as an
extension version.

Upstream let the two drift — tag `0.6.1`, `default_version` `0.5.2` — and the
cost lands on the consumer twice: it must assert both literals by hand, because
`<ext>--<tag>.sql` would look for a file that does not exist; and nothing
readable from SQL can identify the build, because `pg_available_extensions`
cannot see a git tag. Do not reintroduce that gap.

Ordinary semver, and **every release bumps it**: patch for a C-only fix, minor
for a new option, major for a change to existing behaviour. Each bump renames
the SQL script and adds `odbc_fdw--<prev>--<new>.sql` — **empty** if nothing in
SQL changed, which is the honest artefact, because the alternative is telling an
operator to `DROP EXTENSION`, and that `CASCADE`s away their foreign tables and
every view built over them.

**`0.5.2` is forbidden as a version string, permanently, and the reason comes
from outside this repository.** `dwh` refuses to create a HANA source unless
`default_version` appears in an allowlist of builds whose data path has been
**measured** correct (`ODBC_FDW_DATA_OK` in `dwhlib/const.py`). Stock upstream
reports exactly `0.5.2` — tag 0.6.1, control file 0.5.2 — so allowlisting that
string would admit the build that returns wrong values alongside the build that
returns right ones, and a host on an older or rolled-back image would pass the
gate silently. `dwh`'s test suite forbids `"0.5.2"` from that allowlist
permanently. Any string we choose must not collide with it.

**Never rename the extension, the shared object, or the C entry points.**
`odbc_fdw`, `odbc_fdw.so`, `odbc_fdw_handler` and `odbc_fdw_validator` are an
interface: `dwh`'s image assertions, its `WRAPPERS` table and its `verify` checks
all key on those four names.

## Building

```sh
make USE_PGXS=1 PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
sudo make install USE_PGXS=1 PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

`USE_PGXS=1` is inert at this release (the Makefile includes `--pgxs`
unconditionally) and is kept because it is the documented invocation and a flag
that does nothing costs nothing.

**On Debian the PGDG paths apply, not `/usr/local`.** `pg_config` is at
`/usr/lib/postgresql/18/bin/pg_config`, pkglibdir `/usr/lib/postgresql/18/lib`,
sharedir `/usr/share/postgresql/18`. Only the *Alpine* PostgreSQL images build
from source into `/usr/local`. **The official `postgres:18-*` image ships the
server but no development headers**, so `postgresql-server-dev-18` is required
or `pg_config.h` and the pgxs makefiles are simply absent.

`unixodbc-dev` supplies `libodbc.so` and the ODBC headers for
`SHLIB_LINK = -lodbc`. The runtime package on Debian 13 is `libodbc2`;
`libodbc1` has no candidate there.

**Never suppress a warning to get a clean build.** The build is clean at
`-Wall` with PGXS's full flag set as of this release, and that is the baseline:
a new warning is a defect in the new code.

## Testing

**`test/` is upstream's harness and it needs a LIVE ODBC source** — MySQL, SQL
Server, Hive or PostgreSQL registered in `odbcinst.ini`, with fixtures loaded
and a connector config that upstream's CI decrypted from
`test/config/configs.tar.enc` using a key we do not have. So `make installcheck`
and `make integration_tests` do **not** run on a workstation, `REGRESS` cannot
be a gate here, and `.travis.yml` / `.appveyor.yml` describe infrastructure we
do not operate. Do not restructure any of it to make it pass; say it needs a
source instead. It is kept because it is the only description of what a
multi-driver test would cover.

**What IS runnable, with nothing but Docker.** psqlODBC pointed back at the
container's own PostgreSQL is a real ODBC remote, and it exercises the whole
path — validator, handler, `IMPORT FOREIGN SCHEMA`, the chunked read and the
ceilings:

```sh
# postgres:18-trixie + headers + driver manager + psqlODBC
apt-get install -y build-essential postgresql-server-dev-18 unixodbc-dev odbc-postgresql
odbcinst -q -d          # must list [PostgreSQL Unicode]
```

```sql
CREATE SERVER src FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
  odbc_driver 'PostgreSQL Unicode', odbc_servername '127.0.0.1',
  odbc_port '5432', odbc_database 'remotedb');
CREATE USER MAPPING FOR PUBLIC SERVER src
  OPTIONS (odbc_uid 'postgres', odbc_pwd '<throwaway>');
IMPORT FOREIGN SCHEMA rem LIMIT TO ("small") FROM SERVER src INTO ext;
```

Two things that harness establishes and no reasoning could:

- **The defects are not HANA-specific.** Against psqlODBC, stock `ee741f5`
  returns NULL for a correctly-declared column whose remote spelling is upper
  case, and a foreign table with more columns than its query returns
  **terminates the backend with signal 11** and takes the instance into crash
  recovery. Both are correct on this release. Keep that A/B in reach: build the
  base commit's `.so`, install it over ours, run the probe in a fresh session
  (each backend loads the library on first use), and reinstall.
- **A negative control for symbol resolution.** `CREATE EXTENSION` resolves
  `LANGUAGE C` symbols eagerly while `check_function_bodies` is on, which is
  what makes its success evidence. Prove the check is live before trusting it:
  `CREATE FUNCTION f() RETURNS void AS '$libdir/odbc_fdw', 'no_such_symbol'
  LANGUAGE C;` must fail with `could not find function`.

**A test must be able to fail, and a check must be able to fail for the RIGHT
reason.** Asserting `CREATE EXTENSION` succeeds proves nothing without the
negative control above; asserting a ceiling fires proves nothing unless the same
scan is also shown to succeed without it.

## Conventions

- **Measurements go in the commit body.** These messages are the only record of
  how several defects were diagnosed, and they are worth more than the diff. Say
  what was measured, how, and what it rules out — including negative results,
  which is why there is no interrupt check at the row boundary.
- **Label an inference as an inference.** "Presumably", "not tested", "read from
  the source but not run" are all acceptable; asserting an unverified claim is
  not. `SQL_BINARY` is documented as *presumably* affected by the
  `SQL_VARBINARY` defect because it was never tested.
- **Conventional Commits**: `type(scope)!: subject`, imperative, no trailing
  period, header ≤ 72 characters, then a blank line and a prose body wrapped at
  80. `!` and a `BREAKING CHANGE:` footer mean an existing installation needs an
  operator action.
- **Ported commits keep their original messages.** The nine commits from
  `ee741f5` to the first Softinent commit were cherry-picked, not rewritten.
- **Commits carry no AI attribution** — no `Co-Authored-By`, no "generated with"
  line. The provenance that matters is in the copyright headers and the README.
- **Keep the diff justifiable line by line.** Nothing is reformatted, restructured
  or tidied, deliberately, so that every divergence from upstream can be offered
  as a pull request on its own. Upstream's brace style and tabs are upstream's;
  match the surrounding code rather than the file you would have written.
- **Do not commit a credential, a hostname, or a schema name from any real
  system.** There is no tenant here and none is needed: the driver is loaded at
  connect time, so everything short of an actual remote query can be proven with
  psqlODBC. One inherited artefact is credential-shaped and is left alone
  because it is upstream's and undecryptable —
  `test/config/configs.tar.enc`, plus an AppVeyor `secure:` blob — but nothing
  new joins it.
