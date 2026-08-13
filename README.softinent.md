# The `softinent` branch of odbc_fdw

This is a **maintained fork** of [`devrimgunduz/odbc_fdw`](https://github.com/devrimgunduz/odbc_fdw),
carrying fixes and additions that Softinent's PostgreSQL data warehouse needs in
order to read SAP HANA through `odbc_fdw`. It is consumed by the `dwh` project,
whose `postgres/Dockerfile` clones this repository at a **pinned commit** and
builds the extension from it.

Upstream's own `README.md` is untouched and still describes the extension itself.
This file describes only the fork.

## Base and shape of the delta

| | |
| --- | --- |
| Upstream | `https://github.com/devrimgunduz/odbc_fdw` (default branch `master`) |
| Based on tag | **`0.6.1`** = commit `ee741f5c1d3e4643c82e74ab190c985dc6a730d3` |
| Our branch | `softinent` |
| Consumed by `dwh` as | tag **`0.6.1+softinent.1`** — `+` is SemVer build metadata, i.e. "0.6.1 plus our changes" |
| Extension version | still `0.5.2` — upstream's tags do not match its `default_version`, and this fork does not change that |

The delta is meant to be **read**, not merely applied:

```bash
git log --oneline 0.6.1..softinent      # nine commits: eight changes, plus this file
git log -p 0.6.1..softinent             # with the code
git diff 0.6.1..softinent -- odbc_fdw.c # net effect on the only code file we touch
```

Every commit message carries the defect it addresses, the symptom **as measured
against a real SAP HANA 2.0 tenant**, why the fix is correct, and whether it is a
candidate for upstreaming. Those messages are the record — there are no patch
files and no separate design document. Keep it that way: if you change something
here, the commit message is where the reasoning goes.

Only `odbc_fdw.c` is modified. Nothing is reformatted, restructured or tidied,
deliberately, so that every line of divergence is justifiable. No environment of
ours is named anywhere in the branch — the one measured error message that
contained a schema name has it redacted, so this branch is safe to push to a
public remote and to attach to an upstream pull request.

## What is in the branch, in order

**Four defect fixes.** All four were found in one afternoon in roughly 2900 lines,
and all four are candidates for upstreaming — they are defects in upstream, not
local policy.

1. **`Default an empty catalog separator to '.' when qualifying a schema`**
   `SQL_CATALOG_NAME_SEPARATOR` describes how a *catalog* is joined to what
   follows it, so a schema-only database may correctly report it empty — HANA
   does. The emitted text was `"SYS""DUMMY"`, one identifier containing an
   escaped quote.
2. **`Size the values[] array by natts and zero it`**
   The tuple was built from an array sized by *result* columns but indexed by
   *foreign-table* position, and `palloc` does not zero. One read of
   uninitialised heap accounted for the entire original symptom set, including
   an intermittent SIGSEGV that took the whole instance into crash recovery.
3. **`Match result columns to foreign-table columns case-insensitively`**
   PostgreSQL folds unquoted identifiers down, HANA folds up, and the mapping
   used `strcmp`. Unmatched columns were dropped silently.
4. **`Fix the chunked SQLGetData loop: uninitialised reads, indicators, SQL_NO_DATA`**
   Three errors: a control-flow decision made on an uninitialised byte, an ODBC
   *indicator* added to a length total unchecked, and `SQL_NO_DATA` from a
   continuation call treated as failure (which broke every `TIMESTAMP`).

**Four additions.** These are the reason a fork exists rather than a patch set:
the first three are not fixes, and presenting them as fixes would misrepresent
them.

5. **`Make a large single field cancellable in the chunked read`**
   A `CHECK_FOR_INTERRUPTS()` inside the chunk loop. Note the *negative* result
   recorded in that commit: PostgreSQL's `ExecScan` already checks interrupts
   once per row, measured three ways, so there is deliberately **no** check at
   the row boundary and a comment says so. Candidate for upstreaming.
6. **`Bounds-check the buffer arithmetic in the retrieval path`**
   Invariant checks around the buffer arithmetic, so a bad length from a driver
   raises instead of corrupting memory. The commit names each thing that becomes
   impossible. Candidate for upstreaming.
7. **`Add max_field_size and max_row_count ceilings`**
   Two new options, valid on a server and on a table, defaulting to unlimited.
   **Not** for upstreaming: local policy, and the tightest-wins folding diverges
   from how upstream resolves every other option.
8. **`Refuse an import that would create a zero-column foreign table`**
   `IMPORT FOREIGN SCHEMA ... LIMIT TO` never checked its names against the
   remote, so a folded identifier produced a zero-column foreign table that
   PostgreSQL accepted and that failed only when queried. Candidate for
   upstreaming.

### The two new options

```sql
-- refuse any single field value larger than 1 MiB, and any scan over 10M rows
CREATE SERVER hana FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
  odbc_DRIVER 'HDBODBC', odbc_SERVERNODE 'host:30015', odbc_DATABASENAME 'DB',
  max_field_size '1048576',
  max_row_count  '10000000');
```

* Both accept a non-negative integer. `0` means **unlimited**, which is the
  default, so existing configurations are unaffected.
* Valid on `CREATE SERVER` and on `CREATE FOREIGN TABLE`.
* **Tightest wins.** A table cannot raise a ceiling set on its server; it can
  only lower it further. This is intentional — see commit 7.
* Values are validated at DDL time, not deferred to the first query.
* Names must **not** be prefixed `odbc_`: any option so named is passed straight
  through to the ODBC connection string as a driver attribute.

Neither option makes an in-backend ODBC driver safe. `libodbcHDB` runs inside
the backend, so a fault in the *driver* is still a SIGSEGV that takes every
session in every database into crash recovery. Only a process boundary gives
real isolation. These bound what a runaway *remote* can make the extension
allocate, and nothing more.

## Known defects we have NOT fixed

Written down so the next person does not rediscover them in production. All three
are pre-existing upstream behaviour, all three were observed while building this
branch, and none is fixed here.

### 1. A cancelled or failed scan leaks the remote connection

`odbcEndForeignScan` is the only place the ODBC `env`/`dbc`/`stmt` handles are
freed, and the executor does **not** call it when a scan errors out. Every error
raised from inside the scan therefore leaks a driver connection for the life of
the backend. This is not new — `check_return` has always thrown from the fetch
loop — but commit 5 makes cancellation a routine event rather than a rare one.

**Measured:** three cancelled scans left three additional HANA sessions open.

**Why it matters operationally:** a designer repeatedly cancelling a slow query
accumulates sessions on somebody else's production HANA, under one shared
credential, and nothing in `dwh` surfaces it — the count is only visible on the
remote, in `M_CONNECTIONS`. Under pgbouncer's transaction pooling the backend
outlives the client that caused the scan, so the leak persists well beyond the
session that produced it. This is the same class of problem as the
`keep_connections 'off'` setting `dwh` already applies to every `postgres_fdw`
server.

**The fix, if taken:** register cleanup on a transaction or resource-owner
callback, the way `postgres_fdw` does with `pgfdw_xact_callback`, rather than
relying on `EndForeignScan`. Deliberately not bundled into commit 5, so that
commit stays one idea.

### 2. Reading one field is quadratic in its length

`resize_buffer` allocates a new buffer and `memmove`s the whole accumulated value
on **every chunk**, and chunks are capped at `MAXIMUM_BUFFER_SIZE` (8192). So a
value of *n* bytes costs on the order of *n²/16384* bytes of copying.

**Measured:** a single 60,000,000-character NCLOB took about 10 seconds to read,
almost none of it waiting on the network.

**The fix, if taken:** grow geometrically instead of exactly — the `TODO` already
in `resize_buffer` says as much. Not fixed here because it is a performance
change, not a correctness one, and it would be the only commit on this branch not
driven by a measured defect in behaviour.

### 3. `SQL_VARBINARY` is not mapped, so VARBINARY arrives as hex TEXT

`sql_data_type` maps only `SQL_LONGVARBINARY` (`-4`) to `bytea`. HANA reports
`VARBINARY` as `SQL_VARBINARY` (`-3`), which falls through to the text path, so
the driver's hexadecimal *rendering* of the bytes is stored as if it were the
value.

**Measured:** `CAST('ABCD' AS VARBINARY(10))` into a `bytea` column arrives as
`\x3431343234333434` — the ASCII of the string `"41424344"` — instead of
`\x41424344`. A `BLOB` column, being `SQL_LONGVARBINARY`, is correct.

**Why it matters:** this is a silent wrong-*type*, the same class as the defects
commits 1–4 address. Nothing errors; the data is simply wrong, and doubled in
size. `SQL_BINARY` (`-2`) is presumably affected the same way and was not tested.

**The fix, if taken:** add `SQL_VARBINARY` and `SQL_BINARY` to the `bytea` arm of
`sql_data_type`. Out of scope here only because it was found late and needs its
own measurement against more than one driver — a wrapper is expected to work
against any ODBC source, and changing a type mapping changes existing foreign
tables.

## Upstream, and why this is a fork

There is effectively no upstream process to participate in:

* **GitHub issues are DISABLED** on `devrimgunduz/odbc_fdw` (verified via the
  API: `has_issues: false`). A **pull request is the only channel**; there is no
  way to file a bug report or ask a question.
* Two tags have ever been published, `0.6.0` and `0.6.1`.
* One maintainer — the PGDG *yum* repository maintainer, who packages
  `odbc_fdw_18` from this tree. Debian's apt repository ships no `odbc_fdw` for
  any PostgreSQL version, so a source build is required either way.
* Its parent, [`CartoDB/odbc_fdw`](https://github.com/CartoDB/odbc_fdw), was
  **archived on 2026-01-05**. This fork's inherited GitHub description still
  reads `[ARCHIVED]` although the repository itself is not.

So: commits 1–4, 5, 6 and 8 should be offered upstream as pull requests, ideally
one per commit, since each stands alone. Do not wait on them. Nothing in this
branch depends on upstream accepting anything, and the fixes are load-bearing
for the warehouse today.

## Rebasing onto a future upstream tag

The branch is a linear series of small commits on top of a tag, specifically so
that this is a rebase and not a merge.

```bash
git remote add upstream https://github.com/devrimgunduz/odbc_fdw.git   # if absent
git fetch upstream --tags

# read what changed upstream first -- especially odbcIterateForeignScan,
# resize_buffer, odbcImportForeignSchema and the option machinery, which is all
# this branch touches
git log --oneline 0.6.1..0.6.2 -- odbc_fdw.c
git diff 0.6.1..0.6.2 -- odbc_fdw.c

git switch -c softinent-0.6.2 softinent
git rebase --onto 0.6.2 0.6.1 softinent-0.6.2
```

Then, before trusting it:

1. **Check whether any of our commits landed upstream.** If one did, `git rebase`
   will report the conflict or drop the commit; either way, delete ours rather
   than keeping a near-duplicate, and say so in the branch history.
2. **Re-verify against a real tenant.** Every claim in these commit messages was
   measured, not reasoned about, and a rebase invalidates the measurement rather
   than the reasoning. The `dwh` repository's `docs/plans/hana-odbc-fdw.md`
   records what was measured and how.
3. **Rebuild the image and re-pin.** `ODBC_FDW_VERSION` and `ODBC_FDW_COMMIT` in
   `dwh`'s `postgres/Dockerfile` are one fact and must move together, and
   `assert-commit` in that Dockerfile is what enforces it. `compose.yaml` and
   `.env.example` carry the version too, and a stale value there **overrides the
   Dockerfile ARG and fails the build** — all three files move in one commit.

## What pinning this fork obsoletes in `dwh`

The `dwh` repository currently warns, correctly, that `odbc_fdw` returns the right
row and column counts with **wrong values**. That is true of upstream `0.6.1` and
false once this fork is pinned, so the commit that changes the pin is the commit
that must reverse those warnings. They are in:

* `README.md` — the odbc_fdw/HANA paragraph
* `RUNBOOK.md` — the "Foreign data" HANA note
* `CLAUDE.md` — the memory-corruption invariant, and the Phase 3 "ON HOLD" note
* `.env.example` — the `ODBC_FDW_VERSION` comment block
* `compose.yaml` — the `ODBC_FDW_VERSION` build-arg default
* `postgres/Dockerfile` — two comment blocks describing the corruption; these
  should be rewritten as "found and fixed in our fork", not deleted, because they
  record how it was diagnosed
* `docs/plans/hana-odbc-fdw.md` — the status header, the measured-symptoms table
  and the "why Phase 3 is on hold" section
* `dwhlib/cli.py`, `dwhlib/fdw.py`, `dwhlib/verify.py`, `tests/test_commander.py`
  — the runtime warnings and the test that deliberately reads no value from HANA
* Outline pages `07`, `08` and `09`, and the operator changelog

The three items under "Known defects we have NOT fixed" above should be recorded
in `docs/plans/hana-odbc-fdw.md` at the same time. They are the honest residue of
this work, and the handle leak in particular has an operational consequence on a
third party's server that no `dwh` command would reveal.

## Copyright

Upstream's licence (`LICENSE`, PostgreSQL licence) governs. The changes on this
branch are the work of **Softinent** and are offered under the same terms.
