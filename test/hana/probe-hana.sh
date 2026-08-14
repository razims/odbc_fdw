#!/usr/bin/env bash
set -Eeuo pipefail

readonly pg_bin="$(dirname "${PG_CONFIG}")"
readonly test_root="$(mktemp -d)"
readonly pgdata="${test_root}/data"
readonly socket_dir="${test_root}/socket"
readonly port=55433
readonly source_dir="${test_root}/source"

cleanup() {
    if [[ -f "${pgdata}/postmaster.pid" ]]; then
        runuser -u postgres -- "${pg_bin}/pg_ctl" -D "${pgdata}" -m immediate stop >/dev/null 2>&1 || true
    fi
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail() {
    echo "HANA probe: $*" >&2
    exit 1
}

require_value() {
    local name="$1"
    local value="${!name:-}"
    [[ -n "${value}" && "${value}" != 'replace-me' ]] || fail "set ${name} in .env before running this probe"
}

psql_local() {
    psql -X -q -t -A -v ON_ERROR_STOP=1 -h "${socket_dir}" -p "${port}" -U postgres "$@"
}

for required in HANA_HOST HANA_PORT HANA_DATABASE HANA_USER HANA_PASSWORD HANA_SCHEMA HANA_ENCRYPT; do
    require_value "${required}"
done

[[ -f /opt/sap/hdbclient/libodbcHDB.so ]] \
    || fail 'the image does not contain the baked SAP HANA ODBC driver'
odbcinst -q -d | grep -Fx '[HDBODBC]' >/dev/null \
    || fail 'the image does not register the baked HDBODBC driver'

mkdir -p "${source_dir}"
cp -a /workspace/Makefile /workspace/odbc_fdw.control "${source_dir}/"
cp -a /workspace/src /workspace/sql "${source_dir}/"
make -C "${source_dir}" clean
make -C "${source_dir}" USE_PGXS=1 PG_CONFIG="${PG_CONFIG}"
make -C "${source_dir}" install USE_PGXS=1 PG_CONFIG="${PG_CONFIG}"

mkdir -p "${pgdata}" "${socket_dir}"

chown -R postgres:postgres "${test_root}"
runuser --preserve-environment -u postgres -- "${pg_bin}/initdb" \
    --no-locale --encoding=UTF8 --auth-local=trust --auth-host=trust \
    -D "${pgdata}" >/dev/null
runuser --preserve-environment -u postgres -- "${pg_bin}/pg_ctl" -D "${pgdata}" \
    -o "-k ${socket_dir} -h 127.0.0.1 -p ${port}" -w start >/dev/null

# The remaining HANA_* values are already in this process's environment, from
# compose's env_file, and probe-hana.sql reads them with \getenv. They are NOT
# passed with psql's -v: that puts them in the argv of the psql process, where
# /proc/<pid>/cmdline is world-readable for the life of the call, and one of them
# is the tenant's password. /proc/<pid>/environ is readable only by the same uid.
export HANA_SERVERNODE="${HANA_HOST}:${HANA_PORT}"
# HANA surfaces this session variable as a KEY/VALUE row in M_SESSION_CONTEXT,
# NOT as a column of M_CONNECTIONS, which has no client-application column at
# all. Measured against the tenant: the connection opened with
# odbc_sessionvariable_application reports APPLICATION=<marker> there. The
# marker scopes the connection-leak assertion to this one probe run even if the
# test account is shared with another job.
export HANA_TEST_APPLICATION="odbc-fdw-hana-probe-${RANDOM}-$$"

if ! probe_output="$(psql_local postgres -f /workspace/test/hana/probe-hana.sql 2>&1)"; then
    error_line="$(sed -n 's|.*probe-hana.sql:\([0-9][0-9]*\): ERROR:.*|\1|p' <<<"${probe_output}")"
    error_line="${error_line%%$'\n'*}"
    error_kind="$(sed -n 's|.*ERROR:  \([^;]*\).*|\1|p' <<<"${probe_output}")"
    error_kind="${error_kind%%$'\n'*}"
    unsupported_type="$(sed -n 's|.*Data type not supported (\([0-9-][0-9-]*\)) for column \([^ ]*\).*|\1/\2|p' <<<"${probe_output}")"
    unsupported_type="${unsupported_type%%$'\n'*}"
    if [[ -n "${unsupported_type}" ]]; then
        error_kind="${error_kind} (unsupported ODBC type/column ${unsupported_type})"
    fi
    fail "probe SQL failed at line ${error_line:-unknown}: ${error_kind:-unexpected database error}"
fi

assertions=(
    direct_scalar direct_time direct_timestamp direct_unicode_null import_types
    type_matrix type_matrix_nulls import_type_matrix import_binary
    ascii_text cyrillic_text utf8_text json_direct json_import json_nulls
    direct_case_names import_case_names sql_query parameter_in_out large_value
    wide_decimal float_roundtrip float_text import_scale
    money_text money_numeric charset_matrix
    rescan
)

for assertion in "${assertions[@]}"; do
    grep -qxF "${assertion}=ok" <<<"${probe_output}" \
        || fail "the ${assertion} assertion did not pass"
done

# Derived, not a literal. The count in the final line used to be typed by hand,
# so adding a check without editing it reported a number that was simply wrong.
checks=${#assertions[@]}

expect_failure() {
    local name="$1"
    local expected="$2"
    local script="$3"
    local output

    if output="$(psql_local postgres -f "${script}" 2>&1)"; then
        fail "${name} unexpectedly succeeded"
    fi
    grep -Fq "${expected}" <<<"${output}" \
        || fail "${name} failed for an unexpected reason"
    checks=$(( checks + 1 ))
}

expect_failure 'invalid ceiling at DDL time' \
    'option "max_result_size" requires a non-negative integer' \
    /workspace/test/hana/hana-invalid-limit.sql
expect_failure 'invalid max_field_size at DDL time' \
    'option "max_field_size" requires a non-negative integer' \
    /workspace/test/hana/hana-invalid-field-limit.sql
expect_failure 'invalid max_row_count at DDL time' \
    'option "max_row_count" requires a non-negative integer' \
    /workspace/test/hana/hana-invalid-row-limit.sql
expect_failure 'max_field_size' \
    'field value' \
    /workspace/test/hana/hana-max-field.sql
expect_failure 'max_row_count' \
    'scan returned more than 1 rows' \
    /workspace/test/hana/hana-max-row.sql
expect_failure 'max_result_size' \
    'exceeding max_result_size of 1000' \
    /workspace/test/hana/hana-max-result.sql
expect_failure 'server max_field_size is the tightest ceiling' \
    'max_field_size of 100' \
    /workspace/test/hana/hana-server-max-field.sql
expect_failure 'server max_row_count is the tightest ceiling' \
    'scan returned more than 1 rows' \
    /workspace/test/hana/hana-server-max-row.sql
expect_failure 'server max_result_size is the tightest ceiling' \
    'max_result_size of 1000' \
    /workspace/test/hana/hana-server-max-result.sql
expect_failure 'zero-column import refusal' \
    'remote table "ODBC_FDW_DOES_NOT_EXIST" was not found' \
    /workspace/test/hana/hana-zero-column.sql
expect_failure 'read-only DML refusal' \
    'cannot insert into foreign table' \
    /workspace/test/hana/hana-read-only.sql

# ---------------------------------------------------------------------------
# ODBC handles, and the tenant sessions behind them, must not outlive the
# transaction that opened them.
#
# The same gate as the credential-free loopback one in
# docker/run-local-tests.sh, but counted from the tenant's own monitoring views
# -- the only place that shows what a leak actually costs somebody else's
# server.
# Every expect_failure above raises from inside a scan, which is exactly the
# path that used to abandon a session.
#
# One psql session throughout, for the reason given in hana-leak-setup.sql.
# ---------------------------------------------------------------------------

leak_session() {
    # No ON_ERROR_STOP: the scans under test are meant to be refused, and the
    # session has to survive them for the second count to mean anything.
    psql -X -q -t -A -h "${socket_dir}" -p "${port}" -U postgres postgres
}

leak_stderr="$(mktemp)"
leak_counts="$( {
    cat /workspace/test/hana/hana-leak-setup.sql
    echo 'SELECT session_count FROM probe.hana_sessions;'
    # The instrument's own control: count the marker while a SECOND marked
    # connection is provably open. Anything below 2 means this gate is BLIND,
    # and then every delta below it is vacuous -- 0 says the APPLICATION session
    # variable never reached the tenant at all, 1 says the probe account can see
    # only its own row in M_SESSION_CONTEXT. Both look exactly like a clean run
    # without this check.
    #
    # A HELD CURSOR, and that is not arbitrary. The obvious formulation --
    #   SELECT (SELECT session_count FROM probe.hana_sessions)
    #     FROM probe.leak_success LIMIT 1
    # counts 1, measured. COUNT(*) is evaluated by the remote at SQLExecDirect,
    # which odbcBeginForeignScan issues during ExecutorStart, and InitPlan()
    # initialises es_subplanstates BEFORE the main plan tree -- so the counting
    # scan runs its remote query before the outer scan's connection exists.
    # DECLARE opens the cursor's portal, and the connection it holds lives until
    # CLOSE, so the next statement's count sees it: measured 2. No FETCH is
    # needed, and adding one only emits a row that would have to be skipped.
    echo 'BEGIN;'
    echo 'DECLARE leak_held CURSOR FOR SELECT id FROM probe.leak_success;'
    echo 'SELECT session_count FROM probe.hana_sessions;'
    echo 'CLOSE leak_held;'
    echo 'COMMIT;'
    for ((n = 0; n < 20; n++)); do
        echo 'SELECT count(*) FROM probe.leak_source;'
    done
    echo 'SELECT session_count FROM probe.hana_sessions;'
} | leak_session 2>"${leak_stderr}" )"

leak_refusals="$(grep -c '^ERROR:  odbc_fdw: scan returned more than 1 rows' "${leak_stderr}" || true)"
leak_reason="$(awk '/^ERROR:/ { sub(/^ERROR:  */, ""); print; exit }' "${leak_stderr}")"
rm -f "${leak_stderr}"

# Three readings, or the gate did not measure what it claims to. Distinguished
# from a real leak on purpose: a probe user who cannot read the monitoring view
# would otherwise look exactly like a clean run. The driver's own message is
# quoted because "could not read" on its own does not say whether the cause is a
# privilege, a wrong column name, or an unreachable tenant.
[[ "$(grep -c . <<<"${leak_counts}")" -eq 3 ]] \
    || fail "the session-leak gate could not read its HANA session counts: ${leak_reason:-no error reported}"

leak_visible="$(sed -n '2p' <<<"${leak_counts}")"
[[ "${leak_visible}" -ge 2 ]] \
    || fail "the session-leak gate counted ${leak_visible} marked sessions while two were open, so it cannot see a leak and every delta below it is vacuous"
checks=$(( checks + 1 ))

# The scans under test must actually have been REFUSED, which is the guard the
# loopback harness already carries. Without it, a renamed fixture or any other
# error on that path unwinds just as tidily and reports a delta of zero for
# scans that never reached the ceiling at all.
[[ "${leak_refusals}" -eq 20 ]] \
    || fail "the session-leak gate expected 20 scans refused by max_row_count, got ${leak_refusals}"
checks=$(( checks + 1 ))

leak_delta=$(( $(tail -n 1 <<<"${leak_counts}") - $(head -n 1 <<<"${leak_counts}") ))
[[ "${leak_delta}" -eq 0 ]] \
    || fail "20 refused scans leaked ${leak_delta} tenant sessions"
checks=$(( checks + 1 ))

# Match the successful-subtransaction path as well as the aborted one above:
# the remote connection is opened in the inner block, adopted by its parent on
# PRE_COMMIT_SUB, then must be released when the enclosing statement aborts.
commit_subxact_stderr="$(mktemp)"
commit_subxact_counts="$( {
    echo 'SELECT session_count FROM probe.hana_sessions;'
    echo "DO \$\$ BEGIN BEGIN PERFORM count(*) FROM probe.leak_success; EXCEPTION WHEN OTHERS THEN RAISE; END; RAISE EXCEPTION 'force outer transaction abort'; END \$\$;"
    echo 'SELECT session_count FROM probe.hana_sessions;'
} | leak_session 2>"${commit_subxact_stderr}" )"
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
[[ "$(grep -c . <<<"${commit_subxact_counts}")" -eq 2 ]] \
    || fail 'the successful-subtransaction probe could not read its two HANA session counts'
commit_subxact_delta=$(( $(tail -n 1 <<<"${commit_subxact_counts}") - $(head -n 1 <<<"${commit_subxact_counts}") ))
[[ "${commit_subxact_delta}" -eq 0 ]] \
    || fail "a successful subtransaction followed by an outer abort leaked ${commit_subxact_delta} tenant sessions"
checks=$(( checks + 1 ))

# ---------------------------------------------------------------------------
# Optional bulk transfer: memory pressure at a size where a per-row defect is
# visible, against the tenant rather than against the loopback.
#
# Opt-in through HANA_BULK_ROWS, because pulling a million rows across the
# network turns a seconds-long probe into a minutes-long one, and because the
# fixture is a correspondingly large table to leave in somebody's schema. The
# seed creates ODBC_FDW_BULK only when the same variable is set.
#
# Resident set size, NOT pg_backend_memory_contexts: libodbcHDB is loaded into
# the backend and mallocs on its own account, so PostgreSQL's context accounting
# cannot see a driver-side leak and /proc/self/statm can. This is the one
# instrument here that can observe SAP's code rather than only ours. Read with
# an explicit offset and length, because pg_read_file() without them stats the
# file first and /proc reports every file as zero bytes.
#
# The comparison is pass one against pass two, after a warm-up scan that loads
# the driver and fills the relcache -- otherwise the first pass is charged for
# work that happens once.
#
# Skipped LOUDLY when unset. A check that quietly does not run is worse than one
# that is absent, because the summary line still says "passed".
# ---------------------------------------------------------------------------

if [[ -n "${HANA_BULK_ROWS:-}" ]]; then
    [[ "${HANA_BULK_ROWS}" =~ ^[1-9][0-9]*$ ]] \
        || fail 'HANA_BULK_ROWS must be a positive integer'

    # sum(1..n) = n(n+1)/2. A row count alone cannot tell a short scan from one
    # that returned the wrong rows; the checksum can.
    bulk_checksum=$(( HANA_BULK_ROWS * (HANA_BULK_ROWS + 1) / 2 ))
    bulk_rss="SELECT (string_to_array(pg_read_file('/proc/self/statm', 0, 128), ' '))[2]::bigint * 4096"
    bulk_scan="SELECT count(*) || '/' || sum(id)::bigint FROM probe.bulk"

    bulk_stderr="$(mktemp)"
    bulk_out="$( {
        cat /workspace/test/hana/hana-bulk-setup.sql
        echo 'SELECT count(*) FROM probe.direct_types;'
        echo 'SELECT session_count FROM probe.hana_sessions;'
        echo "${bulk_scan};"
        echo "${bulk_rss};"
        echo "${bulk_scan};"
        echo "${bulk_rss};"
        echo 'SELECT session_count FROM probe.hana_sessions;'
    } | leak_session 2>"${bulk_stderr}" )"
    # Quote the real error rather than guessing at one. A short reading count
    # has many causes -- a driver error mid-scan, an unseeded fixture, /proc
    # unreadable -- and sending an operator to re-seed a table that exists is
    # worse than saying nothing.
    bulk_reason="$(awk '/^ERROR:/ { sub(/^ERROR:  */, ""); print; exit }' "${bulk_stderr}")"
    rm -f "${bulk_stderr}"

    mapfile -t bulk_lines <<<"${bulk_out}"
    [[ "${#bulk_lines[@]}" -eq 7 ]] \
        || fail "the bulk probe produced ${#bulk_lines[@]} readings, expected 7: ${bulk_reason:-no error reported; was ODBC_FDW_BULK seeded with HANA_BULK_ROWS set?}"

    for pass in 1 2; do
        [[ "${bulk_lines[$(( pass * 2 ))]}" == "${HANA_BULK_ROWS}/${bulk_checksum}" ]] \
            || fail "bulk pass ${pass} returned ${bulk_lines[$(( pass * 2 ))]}, expected ${HANA_BULK_ROWS}/${bulk_checksum}"
    done
    checks=$(( checks + 1 ))

    # 4 MiB. Measured between two identical million-row passes: 65,536 bytes
    # against loopback psqlODBC, 241,664 against a real HANA tenant through
    # libodbcHDB -- the difference is that driver's larger working set, not a
    # per-row cost, since 241,664 bytes over 1,000,000 rows is a quarter of a
    # byte a row. The threshold sits an order of magnitude above the larger of
    # the two, so it travels between drivers, while still refusing anything
    # that grows by as little as four bytes a row.
    bulk_rss_growth=$(( bulk_lines[5] - bulk_lines[3] ))
    [[ "${bulk_rss_growth}" -lt 4194304 ]] \
        || fail "a repeated ${HANA_BULK_ROWS}-row transfer grew the backend RSS by ${bulk_rss_growth} bytes between two identical passes"
    checks=$(( checks + 1 ))

    bulk_session_delta=$(( bulk_lines[6] - bulk_lines[1] ))
    [[ "${bulk_session_delta}" -eq 0 ]] \
        || fail "two ${HANA_BULK_ROWS}-row transfers leaked ${bulk_session_delta} tenant sessions"
    checks=$(( checks + 1 ))

    bulk_summary=", ${HANA_BULK_ROWS}-row transfer steady to within ${bulk_rss_growth} bytes"
else
    bulk_summary=' (bulk transfer SKIPPED; set HANA_BULK_ROWS in .env to run it)'
fi

echo "HANA integration suite: passed (${checks} assertions)${bulk_summary}"
