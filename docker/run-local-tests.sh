#!/usr/bin/env bash
set -Eeuo pipefail

readonly pg_bin="$(dirname "${PG_CONFIG}")"
readonly test_root="$(mktemp -d)"
readonly pgdata="${test_root}/data"
readonly socket_dir="${test_root}/socket"
readonly port=55432
readonly source_dir="${test_root}/source"

cleanup() {
    if [[ -f "${pgdata}/postmaster.pid" ]]; then
        runuser -u postgres -- "${pg_bin}/pg_ctl" -D "${pgdata}" -m immediate stop >/dev/null 2>&1 || true
    fi
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail() {
    echo "local ODBC smoke test: $*" >&2
    exit 1
}

psql_local() {
    psql -X -v ON_ERROR_STOP=1 -h "${socket_dir}" -p "${port}" -U postgres "$@"
}

mkdir -p "${source_dir}"
cp -a /workspace/Makefile /workspace/odbc_fdw.control \
    /workspace/odbc_fdw--*.sql "${source_dir}/"
cp -a /workspace/src "${source_dir}/src"
make -C "${source_dir}" clean
make -C "${source_dir}" USE_PGXS=1 PG_CONFIG="${PG_CONFIG}"
make -C "${source_dir}" install USE_PGXS=1 PG_CONFIG="${PG_CONFIG}"

odbcinst -q -d | grep -Fx '[PostgreSQL Unicode]' >/dev/null \
    || fail 'the Debian psqlODBC driver was not registered as [PostgreSQL Unicode]'

mkdir -p "${pgdata}" "${socket_dir}"
chown -R postgres:postgres "${test_root}"
runuser -u postgres -- "${pg_bin}/initdb" \
    --no-locale --encoding=UTF8 --auth-local=trust --auth-host=trust \
    -D "${pgdata}" >/dev/null
runuser -u postgres -- "${pg_bin}/pg_ctl" -D "${pgdata}" \
    -o "-k ${socket_dir} -h 127.0.0.1 -p ${port}" -w start >/dev/null

psql_local postgres <<'SQL'
CREATE DATABASE remotedb;
CREATE DATABASE fdwtest;
SQL

psql_local remotedb <<'SQL'
CREATE TABLE public.small (
    id integer PRIMARY KEY,
    label text NOT NULL,
    big text NOT NULL
);
INSERT INTO public.small VALUES
    (1, 'first', repeat('x', 10000)),
    (2, 'second', 'small value');

CREATE TABLE public.case_distinct ("A" integer, "a" integer);
INSERT INTO public.case_distinct VALUES (1, 2);

CREATE TABLE public.drop_test (a integer, b integer);
INSERT INTO public.drop_test VALUES (1, 2);

CREATE TABLE public.quoted_identifier ("a""b" integer);
INSERT INTO public.quoted_identifier VALUES (7);

CREATE TABLE public.binary_values (
    id integer PRIMARY KEY,
    payload bytea NOT NULL
);
INSERT INTO public.binary_values VALUES (1, decode('004142ff', 'hex'));

CREATE TABLE public.qual_values (value text PRIMARY KEY);
INSERT INTO public.qual_values VALUES (E'back\\slash''quote');

CREATE TABLE public.explain_audit (called integer NOT NULL);
CREATE FUNCTION public.explain_probe() RETURNS integer
LANGUAGE sql VOLATILE
AS 'INSERT INTO public.explain_audit VALUES (1) RETURNING 1';
SQL

psql_local fdwtest <<'SQL'
CREATE EXTENSION odbc_fdw;
CREATE SCHEMA ext;
CREATE SERVER loopback FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'PostgreSQL Unicode',
    odbc_servername '127.0.0.1',
    odbc_port '55432',
    odbc_database 'remotedb'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER loopback OPTIONS (odbc_uid 'postgres');
CREATE USER MAPPING FOR PUBLIC SERVER loopback OPTIONS (odbc_uid 'postgres');
IMPORT FOREIGN SCHEMA public LIMIT TO ("small") FROM SERVER loopback INTO ext;

CREATE FOREIGN TABLE ext.case_distinct ("A" integer, "a" integer)
SERVER loopback OPTIONS (
    sql_query 'SELECT "A", "a" FROM public.case_distinct');

CREATE FOREIGN TABLE ext.drop_test (a integer, b integer)
SERVER loopback OPTIONS (schema 'public', table 'drop_test');
ALTER FOREIGN TABLE ext.drop_test DROP COLUMN b;

CREATE FOREIGN TABLE ext.explain_probe (id integer)
SERVER loopback OPTIONS (
    sql_query 'SELECT public.explain_probe() AS id');

CREATE FOREIGN TABLE ext.qual_values (value text)
SERVER loopback OPTIONS (schema 'public', table 'qual_values');

CREATE ROLE driver_attacker;
GRANT USAGE ON FOREIGN SERVER loopback TO driver_attacker;
CREATE ROLE helper_attacker;
SQL

[[ "$(psql_local fdwtest -Atqc 'SELECT string_agg(label, chr(44) ORDER BY id) FROM ext.small')" == 'first,second' ]] \
    || fail 'the loopback ODBC scan returned unexpected values'

# Result names that differ only by case must bind to their exact local columns.
# A first-match pg_strcasecmp maps both to "A", overwrites 1 with 2, and leaves
# "a" NULL: the silent wrong answer this assertion exists for.
[[ "$(psql_local fdwtest -AtF '|' -qc 'SELECT "A", "a" FROM ext.case_distinct')" == '1|2' ]] \
    || fail 'case-distinct result columns were collapsed onto one local column'

# Dropped attributes remain in a TupleDesc but must not be named in the remote
# SELECT list. PostgreSQL's internal dropped-column placeholder does not exist
# on the remote.
[[ "$(psql_local fdwtest -Atqc 'SELECT a FROM ext.drop_test')" == '1' ]] \
    || fail 'a dropped foreign-table column remained in the remote query'

# Every identifier emitted by IMPORT, and then by the scan it creates, must
# survive an embedded double quote.
psql_local fdwtest -c 'IMPORT FOREIGN SCHEMA public LIMIT TO ("quoted_identifier") FROM SERVER loopback INTO ext' >/dev/null
[[ "$(psql_local fdwtest -Atqc 'SELECT "a""b" FROM ext.quoted_identifier')" == '7' ]] \
    || fail 'a quoted remote identifier was not imported and scanned exactly'

# SQL_VARBINARY/SQL_BINARY must be treated as bytes rather than as the ASCII
# rendering of hexadecimal text.
psql_local fdwtest -c 'IMPORT FOREIGN SCHEMA public LIMIT TO ("binary_values") FROM SERVER loopback INTO ext' >/dev/null
[[ "$(psql_local fdwtest -Atqc "SELECT pg_typeof(payload)::text || '/' || encode(payload, 'hex') FROM ext.binary_values")" == 'bytea/004142ff' ]] \
    || fail 'a binary ODBC value was not imported and returned as bytea'

# A plain EXPLAIN must not connect to or execute the remote query. The function
# behind this table makes any accidental execution externally visible.
psql_local fdwtest -c 'EXPLAIN SELECT * FROM ext.explain_probe' >/dev/null
[[ "$(psql_local remotedb -Atqc 'SELECT count(*) FROM public.explain_audit')" == '0' ]] \
    || fail 'plain EXPLAIN executed a remote query'

# SQLTables is executed once, then fetched to exhaustion. Re-executing it before
# every fetch returns the first row repeatedly until rowLimit is reached.
table_list="$(psql_local fdwtest -AtF '|' -qc "SELECT schema, name FROM ODBCTablesList('loopback', 100) ORDER BY 1, 2")"
[[ "$(wc -l <<<"${table_list}" | tr -d ' ')" -eq "$(sort -u <<<"${table_list}" | wc -l | tr -d ' ')" ]] \
    || fail 'ODBCTablesList repeated a catalog row instead of advancing its cursor'
grep -qxF 'public|small' <<<"${table_list}" \
    || fail 'ODBCTablesList did not return the expected remote table'

# Bound parameters, not remote-dialect string interpolation. This value carries
# both characters whose interaction makes cross-dialect escaping unsafe.
[[ "$(psql_local fdwtest -Atqc "SELECT count(*) FROM ext.qual_values WHERE value = E'back\\\\slash''quote'")" == '1' ]] \
    || fail 'a text equality predicate with quotes and backslashes was mishandled'

# DRIVER/DSN decide which shared library unixODBC loads. Every spelling and
# every catalog context must retain the superuser boundary.
if psql_local fdwtest -c "SET ROLE driver_attacker; CREATE USER MAPPING FOR driver_attacker SERVER loopback OPTIONS (odbc_driver '/tmp/not-an-odbc-driver.so')" >/dev/null 2>&1; then
    fail 'a non-superuser created an odbc_driver user-mapping option'
fi

# The SQL helpers are explicit remote access and must enforce server USAGE even
# if a PUBLIC mapping exists. Function EXECUTE is checked separately below.
psql_local fdwtest -c "GRANT EXECUTE ON FUNCTION ODBCQuerySize(text, text) TO helper_attacker" >/dev/null
if psql_local fdwtest -c "SET ROLE helper_attacker; SELECT ODBCQuerySize('loopback', 'SELECT * FROM public.small')" >/dev/null 2>&1; then
    fail 'ODBCQuerySize bypassed foreign-server USAGE through a PUBLIC mapping'
fi
psql_local fdwtest -c "REVOKE EXECUTE ON FUNCTION ODBCQuerySize(text, text) FROM helper_attacker" >/dev/null

[[ "$(psql_local fdwtest -Atqc "SELECT has_function_privilege('helper_attacker', 'ODBCQuerySize(text,text)', 'EXECUTE')")" == 'f' ]] \
    || fail 'ODBCQuerySize retained its default PUBLIC EXECUTE privilege'

if psql_local fdwtest -c "CREATE FUNCTION missing_symbol() RETURNS void AS '\$libdir/odbc_fdw', 'no_such_symbol' LANGUAGE C" >/dev/null 2>&1; then
    fail 'CREATE EXTENSION symbol-resolution negative control unexpectedly succeeded'
fi

if psql_local fdwtest -c "CREATE SERVER invalid_limit FOREIGN DATA WRAPPER odbc_fdw OPTIONS (max_row_count 'not-a-number')" >/dev/null 2>&1; then
    fail 'the validator accepted an invalid max_row_count'
fi

psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (ADD max_field_size '10')" >/dev/null
if psql_local fdwtest -c 'SELECT big FROM ext.small' >/dev/null 2>&1; then
    fail 'max_field_size did not refuse the oversized field'
fi

psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (DROP max_field_size, ADD max_row_count '1')" >/dev/null
if psql_local fdwtest -c 'SELECT count(*) FROM ext.small' >/dev/null 2>&1; then
    fail 'max_row_count did not refuse the second row'
fi

# max_result_size, and the pair is the point: the same scan must PASS with both
# other ceilings satisfied and FAIL only once the aggregate ceiling is set.
# Without the passing half this asserts nothing about WHICH ceiling refused.
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (SET max_row_count '100', ADD max_field_size '20000')" >/dev/null
psql_local fdwtest -c 'SELECT count(*) FROM ext.small' >/dev/null \
    || fail 'a scan within max_field_size and max_row_count was refused'
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (ADD max_result_size '1000')" >/dev/null
if psql_local fdwtest -c 'SELECT count(*) FROM ext.small' >/dev/null 2>&1; then
    fail 'max_result_size did not refuse a scan over its aggregate ceiling'
fi

# Tightest wins: a foreign table must not be able to raise its server's ceiling.
psql_local fdwtest <<'SQL' >/dev/null
ALTER SERVER loopback OPTIONS (ADD max_row_count '1');
ALTER FOREIGN TABLE ext.small OPTIONS (DROP max_result_size, SET max_row_count '1000000');
SQL
if psql_local fdwtest -c 'SELECT count(*) FROM ext.small' >/dev/null 2>&1; then
    fail 'a foreign table raised a ceiling set on its server'
fi

# ReScanForeignScan must restart the scan. A correlated subquery over two local
# rows has to find a remote row twice; a no-op rescan returns the first and NULL.
psql_local fdwtest <<'SQL' >/dev/null
ALTER SERVER loopback OPTIONS (DROP max_row_count);
ALTER FOREIGN TABLE ext.small OPTIONS (DROP max_row_count, DROP max_field_size);
CREATE TABLE two_rows (id integer);
INSERT INTO two_rows VALUES (1), (2);
SQL
[[ "$(psql_local fdwtest -Atqc "SELECT string_agg(x, chr(44) ORDER BY id) FROM (SELECT t.id, (SELECT s.label FROM ext.small s WHERE s.id = t.id) AS x FROM two_rows t) q")" == 'first,second' ]] \
    || fail 'a rescanned foreign scan did not restart, so later scans returned no rows'

# A remote query that returns NO rows, which is not the same thing as a local
# qual that filters every row away: this one is a sql_query, so the emptiness
# happens on the remote and SQLFetch returns SQL_NO_DATA on the very first call.
# It is the negative control for refusing a FAILED fetch -- the refusal must not
# also refuse a legitimately empty result set.
psql_local fdwtest -c "CREATE FOREIGN TABLE ext.empty_rows (id integer, label text) SERVER loopback OPTIONS (sql_query 'SELECT id, label FROM public.small WHERE id < 0')" >/dev/null
[[ "$(psql_local fdwtest -Atqc 'SELECT count(*) FROM ext.empty_rows')" == '0' ]] \
    || fail 'an empty remote result set did not scan cleanly'

# ---------------------------------------------------------------------------
# Resource leaks.
#
# Every ceiling above exists in order to RAISE, and an error raised from inside
# a scan unwinds past odbcEndForeignScan -- PortalCleanup skips ExecutorEnd for
# a failed portal -- so nothing frees the ODBC env/dbc handles or the remote
# session behind them. psqlODBC points back at this same instance, so a leaked
# session is a visible client backend on `remotedb`, and pg_stat_activity is
# cluster-wide, so one fdwtest session can count them.
#
# This MUST run inside a single psql session. The handles are held by the
# backend that leaked them and go away when it exits, so a per-statement
# `psql -c` would tidy up the very thing being measured.
# ---------------------------------------------------------------------------

readonly remote_sessions="SELECT count(*) FROM pg_stat_activity WHERE datname = 'remotedb' AND backend_type = 'client backend'"

psql_session() {
    # No ON_ERROR_STOP: the statements under test are meant to fail, and the
    # session has to survive them for the count afterwards to mean anything.
    psql -X -q -At -h "${socket_dir}" -p "${port}" -U postgres fdwtest
}

# Prints "<session delta> <error count>". The error count is what stops a delta
# of zero from passing when nothing actually ran.
leak_probe() {
    local statement="$1" repeats="$2" n counts errors stderr_file
    stderr_file="$(mktemp)"
    counts="$( {
        echo "${remote_sessions};"
        for ((n = 0; n < repeats; n++)); do echo "${statement}"; done
        echo "${remote_sessions};"
    } | psql_session 2>"${stderr_file}" )"
    errors="$(grep -c '^ERROR:' "${stderr_file}" || true)"
    rm -f "${stderr_file}"
    printf '%s %s\n' \
        "$(( $(tail -n 1 <<<"${counts}") - $(head -n 1 <<<"${counts}") ))" \
        "${errors}"
}

psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (ADD max_row_count '1')" >/dev/null
read -r refused_delta refused_errors <<<"$(leak_probe 'SELECT count(*) FROM ext.small;' 20)"
[[ "${refused_errors}" -eq 20 ]] \
    || fail "the leak probe expected 20 refused scans, got ${refused_errors}"
[[ "${refused_delta}" -eq 0 ]] \
    || fail "20 refused scans leaked ${refused_delta} remote sessions"

psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (DROP max_row_count)" >/dev/null
read -r ok_delta ok_errors <<<"$(leak_probe 'SELECT count(*) FROM ext.small;' 20)"
[[ "${ok_errors}" -eq 0 ]] \
    || fail "the leak probe's succeeding half raised ${ok_errors} errors"
[[ "${ok_delta}" -eq 0 ]] \
    || fail "20 successful scans leaked ${ok_delta} remote sessions"

# The subtransaction path. A PL/pgSQL block that swallows the ceiling error is
# an ordinary shape, and each iteration aborts a SUBtransaction, not the
# transaction -- so a cleanup hung only on the transaction would not fire until
# the outer one ends. The count is therefore taken while the outer transaction
# is STILL OPEN, which is the only position from which the difference shows.
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (ADD max_row_count '1')" >/dev/null
# The loop RAISEs a notice carrying how many iterations were actually caught,
# because `EXCEPTION WHEN OTHERS THEN NULL` swallows everything: without it a
# loop that failed on iteration 1, or one whose scans quietly SUCCEEDED because
# the ceiling regressed, both leave a delta of zero and pass.
subxact_stderr="$(mktemp)"
subxact_counts="$( {
    echo "${remote_sessions};"
    echo 'BEGIN;'
    # $m$ rather than a quoted literal: this is inside a bash single-quoted
    # string, which cannot contain an apostrophe, and inside SQL dollar quoting
    # that ends at the next $$.
    echo 'DO $$ DECLARE i int; caught int := 0; BEGIN FOR i IN 1..100 LOOP BEGIN PERFORM count(*) FROM ext.small; EXCEPTION WHEN OTHERS THEN caught := caught + 1; END; END LOOP; RAISE NOTICE $m$caught=%$m$, caught; END $$;'
    echo "${remote_sessions};"
    echo 'COMMIT;'
} | psql_session 2>"${subxact_stderr}" )"
subxact_caught="$(grep -c '^NOTICE:  caught=100$' "${subxact_stderr}" || true)"
rm -f "${subxact_stderr}"
[[ "${subxact_caught}" -eq 1 ]] \
    || fail 'the subtransaction leak probe did not refuse all 100 scans, so its delta measures nothing'
subxact_delta=$(( $(tail -n 1 <<<"${subxact_counts}") - $(head -n 1 <<<"${subxact_counts}") ))
[[ "${subxact_delta}" -eq 0 ]] \
    || fail "100 scans refused inside subtransactions leaked ${subxact_delta} remote sessions"
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (DROP max_row_count)" >/dev/null

# A successful subtransaction has a different callback ordering from the
# EXCEPTION path above. It must adopt the remote connection into its parent;
# then a later error in that parent must release it. Using COMMIT_SUB instead
# of PRE_COMMIT_SUB used to miss this exact sequence and leave the entry outside
# the top-level cleanup list.
commit_subxact_stderr="$(mktemp)"
commit_subxact_counts="$( {
    echo "${remote_sessions};"
    echo "DO \$\$ BEGIN BEGIN PERFORM count(*) FROM ext.small; EXCEPTION WHEN OTHERS THEN RAISE; END; RAISE EXCEPTION 'force outer transaction abort'; END \$\$;"
    echo "${remote_sessions};"
} | psql_session 2>"${commit_subxact_stderr}" )"
commit_subxact_errors="$(grep -c '^ERROR:' "${commit_subxact_stderr}" || true)"
# The error's IDENTITY, not merely its count. If the inner PERFORM fails, the
# EXCEPTION handler re-RAISEs it and the block still ends with exactly one
# error -- but it is the inner one, the subtransaction ABORTED rather than
# committed, and the PRE_COMMIT_SUB adoption this probe exists for never ran.
# Counting alone therefore passes on the very path it is meant to exclude.
commit_subxact_outer="$(grep -c 'force outer transaction abort' "${commit_subxact_stderr}" || true)"
rm -f "${commit_subxact_stderr}"
[[ "${commit_subxact_errors}" -eq 1 ]] \
    || fail "the successful-subtransaction probe expected one outer error, got ${commit_subxact_errors}"
[[ "${commit_subxact_outer}" -eq 1 ]] \
    || fail 'the successful-subtransaction probe failed inside its inner block, so the committing-subtransaction path was never exercised'
commit_subxact_delta=$(( $(tail -n 1 <<<"${commit_subxact_counts}") - $(head -n 1 <<<"${commit_subxact_counts}") ))
[[ "${commit_subxact_delta}" -eq 0 ]] \
    || fail "a successful subtransaction followed by an outer abort leaked ${commit_subxact_delta} remote sessions"

# Backend-side growth. The per-tuple path is reset by ExecScan on every tuple,
# so a succeeding scan should not move the backend's total at all; anything that
# does grow here is being allocated in a context that outlives the query, which
# is where a bookkeeping list for the handles would go wrong. Warm the caches
# first, because the first scans legitimately populate the relcache.
readonly backend_bytes='SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts'
readonly warm_loop='DO $$ DECLARE i int; BEGIN FOR i IN 1..20 LOOP PERFORM count(*) FROM ext.small; END LOOP; END $$;'
readonly work_loop='DO $$ DECLARE i int; BEGIN FOR i IN 1..200 LOOP PERFORM count(*) FROM ext.small; END LOOP; END $$;'
growth_stderr="$(mktemp)"
growth_counts="$( {
    echo "${warm_loop}"
    echo "${backend_bytes};"
    echo "${work_loop}"
    echo "${backend_bytes};"
} | psql_session 2>"${growth_stderr}" )"
# Neither loop handles exceptions, and the two readings are separate statements
# that survive one failing -- so an error inside work_loop would leave a growth
# of zero and report "200 successful scans" for scans that never ran.
growth_errors="$(grep -c '^ERROR:' "${growth_stderr}" || true)"
rm -f "${growth_stderr}"
[[ "${growth_errors}" -eq 0 ]] \
    || fail "the backend-growth probe raised ${growth_errors} errors, so its 200 scans did not all run"
growth=$(( $(tail -n 1 <<<"${growth_counts}") - $(head -n 1 <<<"${growth_counts}") ))
[[ "${growth}" -lt 1048576 ]] \
    || fail "200 successful scans grew the backend by ${growth} bytes"

# ---------------------------------------------------------------------------
# Bulk transfer: memory pressure at a size where a per-row defect is visible.
#
# Everything above runs on two rows, which establishes behaviour and nothing
# whatever about behaviour AT SIZE. A leak of a hundred bytes per row is
# invisible at two rows and is 100MB at a million, and the per-tuple reset that
# makes a scan bounded is exactly the kind of thing that holds for a short scan
# and fails for a long one.
#
# Resident set size, NOT pg_backend_memory_contexts: the ODBC driver is loaded
# into the backend and mallocs on its own account, so PostgreSQL's context
# accounting is blind to a driver-side leak and /proc/self/statm is not. Read
# with an explicit offset and length, because pg_read_file() without them stats
# the file first and /proc reports every file as zero bytes.
#
# The meaningful comparison is the SECOND pass against the THIRD, not either
# against the baseline: the first pass legitimately grows the backend by
# dlopen'ing the driver and filling the relcache. Two identical later passes
# should differ by almost nothing.
# ---------------------------------------------------------------------------

readonly bulk_rows=1000000
# sum(1..n) = n(n+1)/2. A count alone cannot tell a short scan from a scan that
# returned the wrong rows; the checksum can.
readonly bulk_checksum=$(( bulk_rows * (bulk_rows + 1) / 2 ))

psql_local remotedb -c "CREATE TABLE public.bulk AS SELECT g AS id, 'row-' || g AS label FROM generate_series(1, ${bulk_rows}) g" >/dev/null
psql_local fdwtest -c "CREATE FOREIGN TABLE ext.bulk (id integer, label text) SERVER loopback OPTIONS (schema 'public', table 'bulk')" >/dev/null

readonly backend_rss="SELECT (string_to_array(pg_read_file('/proc/self/statm', 0, 128), ' '))[2]::bigint * 4096"
readonly bulk_scan="SELECT count(*) || '/' || sum(id)::bigint FROM ext.bulk"

bulk_stderr="$(mktemp)"
bulk_out="$( {
    echo "${remote_sessions};"
    echo "${bulk_scan};"
    echo "${backend_rss};"
    echo "${bulk_scan};"
    echo "${backend_rss};"
    echo "${bulk_scan};"
    echo "${backend_rss};"
    echo "${remote_sessions};"
} | psql_session 2>"${bulk_stderr}" )"
# Quote the real error rather than guessing at one. A short reading count has
# many causes -- a driver error mid-scan, /proc unreadable -- and naming only
# one of them sends an operator after the wrong thing.
bulk_reason="$(awk '/^ERROR:/ { sub(/^ERROR:  */, ""); print; exit }' "${bulk_stderr}")"
rm -f "${bulk_stderr}"

mapfile -t bulk_lines <<<"${bulk_out}"
[[ "${#bulk_lines[@]}" -eq 8 ]] \
    || fail "the bulk probe produced ${#bulk_lines[@]} readings, expected 8: ${bulk_reason:-no error reported; is pg_read_file on /proc permitted?}"

for pass in 1 2 3; do
    [[ "${bulk_lines[$(( pass * 2 - 1 ))]}" == "${bulk_rows}/${bulk_checksum}" ]] \
        || fail "bulk pass ${pass} returned ${bulk_lines[$(( pass * 2 - 1 ))]}, expected ${bulk_rows}/${bulk_checksum}"
done

# 4 MiB. Measured on this harness, the delta between two identical million-row
# passes is 65,536 bytes -- a single block from the allocator, i.e. flat. The
# threshold is set 64x above that so it does not chase allocator noise across
# architectures, while still refusing anything that grows by as little as four
# bytes per row. A realistic defect here is a palloc that outlives its tuple,
# which is at least eight bytes a row and so at least 8MB at this size.
bulk_rss_growth=$(( bulk_lines[6] - bulk_lines[4] ))
[[ "${bulk_rss_growth}" -lt 4194304 ]] \
    || fail "a repeated ${bulk_rows}-row transfer grew the backend RSS by ${bulk_rss_growth} bytes between two identical passes"

bulk_session_delta=$(( bulk_lines[7] - bulk_lines[0] ))
[[ "${bulk_session_delta}" -eq 0 ]] \
    || fail "three ${bulk_rows}-row transfers leaked ${bulk_session_delta} remote sessions"

# The ceiling boundary at scale, both sides. Exactly bulk_rows must pass and
# one fewer must refuse; asserting only the refusal would not show that the
# ceiling counts rows rather than merely disliking large scans.
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.bulk OPTIONS (ADD max_row_count '${bulk_rows}')" >/dev/null
psql_local fdwtest -c 'SELECT count(*) FROM ext.bulk' >/dev/null \
    || fail "a max_row_count of exactly ${bulk_rows} refused a ${bulk_rows}-row scan"
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.bulk OPTIONS (SET max_row_count '$(( bulk_rows - 1 ))')" >/dev/null
if psql_local fdwtest -c 'SELECT count(*) FROM ext.bulk' >/dev/null 2>&1; then
    fail "a max_row_count of $(( bulk_rows - 1 )) allowed a ${bulk_rows}-row scan"
fi
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.bulk OPTIONS (DROP max_row_count)" >/dev/null

# Cancellation while the foreign cursor is active. A raw million-row transfer
# is faster than one second on some hosts, which turns a timeout assertion into
# a machine-speed test. pg_sleep is volatile and evaluated once per fetched
# row, so this cannot be optimised away or pushed to the remote; the timeout
# therefore fires after the scan has opened its ODBC connection and returned
# rows, regardless of host speed.
readonly bulk_cancel_scan="SELECT sum(id)::bigint FROM (SELECT id, pg_sleep(0.005) FROM ext.bulk) AS delayed"
cancel_stderr="$(mktemp)"
cancel_counts="$( {
    echo "${remote_sessions};"
    echo "SET statement_timeout = '1s';"
    echo "${bulk_cancel_scan};"
    echo 'RESET statement_timeout;'
    echo "${remote_sessions};"
} | psql_session 2>"${cancel_stderr}" )"
grep -q 'canceling statement due to statement timeout' "${cancel_stderr}" \
    || fail 'a 1s statement_timeout did not cancel an active foreign scan'
rm -f "${cancel_stderr}"
cancel_delta=$(( $(tail -n 1 <<<"${cancel_counts}") - $(head -n 1 <<<"${cancel_counts}") ))
[[ "${cancel_delta}" -eq 0 ]] \
    || fail "a cancelled active foreign scan leaked ${cancel_delta} remote sessions"

echo "local ODBC smoke test: passed (${bulk_rows}-row transfer steady between passes to within ${bulk_rss_growth} bytes)"
