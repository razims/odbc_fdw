#!/usr/bin/env bash
set -Eeuo pipefail

readonly pg_bin="$(dirname "${PG_CONFIG}")"
readonly test_root="$(mktemp -d)"
readonly pgdata="${test_root}/data"
readonly socket_dir="${test_root}/socket"
readonly port=55434
readonly source_dir="${test_root}/source"

cleanup() {
    if [[ -f "${pgdata}/postmaster.pid" ]]; then
        runuser -u postgres -- "${pg_bin}/pg_ctl" -D "${pgdata}" -m immediate stop >/dev/null 2>&1 || true
    fi
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail() {
    echo "Oracle probe: $*" >&2
    exit 1
}

require_value() {
    local name="$1"
    local value="${!name:-}"
    [[ -n "${value}" && "${value}" != 'replace-me' ]] \
        || fail "set ${name} in .env before running this probe"
}

psql_local() {
    psql -X -q -t -A -v ON_ERROR_STOP=1 -h "${socket_dir}" -p "${port}" -U postgres "$@"
}

for required in ORACLE_HOST ORACLE_PORT ORACLE_SERVICE ORACLE_USER ORACLE_PASSWORD ORACLE_SCHEMA; do
    require_value "${required}"
done
[[ "${ORACLE_PORT}" =~ ^[0-9]+$ ]] \
    && (( 10#${ORACLE_PORT} >= 1 && 10#${ORACLE_PORT} <= 65535 )) \
    || fail 'ORACLE_PORT must be an integer from 1 through 65535'
[[ "${ORACLE_SCHEMA}" =~ ^[A-Z][A-Z0-9_]*$ ]] \
    || fail 'ORACLE_SCHEMA must be a plain uppercase unquoted Oracle identifier'

[[ -f /opt/oracle/instantclient_21_23/libsqora.so.21.1 ]] \
    || fail 'the image does not contain Oracle Instant Client 21.23 ODBC'
odbcinst -q -d | grep -Fx '[Oracle 21 ODBC driver]' >/dev/null \
    || fail 'the image does not register [Oracle 21 ODBC driver]'

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

# Easy Connect targets the PDB service explicitly. Credentials remain in the
# environment and probe-oracle.sql reads them with \getenv rather than psql -v.
export ORACLE_DBQ="//${ORACLE_HOST}:${ORACLE_PORT}/${ORACLE_SERVICE}"

if ! probe_output="$(psql_local postgres -f /workspace/test/oracle/probe-oracle.sql 2>&1)"; then
    error_line="$(sed -n 's|.*probe-oracle.sql:\([0-9][0-9]*\): ERROR:.*|\1|p' <<<"${probe_output}")"
    error_line="${error_line%%$'\n'*}"
    error_kind="$(sed -n 's|.*ERROR:  \([^;]*\).*|\1|p' <<<"${probe_output}")"
    error_kind="${error_kind%%$'\n'*}"
    fail "probe SQL failed at line ${error_line:-unknown}: ${error_kind:-unexpected database error}"
fi

assertions=(
    direct_scalar direct_timestamp direct_unicode_null import_types
    type_matrix type_matrix_nulls import_type_matrix
    ascii_text cyrillic_text utf8_text json_direct json_import json_nulls
    direct_case_names import_case_names sql_query parameter_in_out large_value rescan
)
for assertion in "${assertions[@]}"; do
    grep -qxF "${assertion}=ok" <<<"${probe_output}" \
        || fail "the ${assertion} assertion did not pass"
done
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
    /workspace/test/oracle/oracle-invalid-limit.sql
expect_failure 'invalid max_field_size at DDL time' \
    'option "max_field_size" requires a non-negative integer' \
    /workspace/test/oracle/oracle-invalid-field-limit.sql
expect_failure 'invalid max_row_count at DDL time' \
    'option "max_row_count" requires a non-negative integer' \
    /workspace/test/oracle/oracle-invalid-row-limit.sql
expect_failure 'max_field_size' 'field value' \
    /workspace/test/oracle/oracle-max-field.sql
expect_failure 'max_row_count' 'scan returned more than 1 rows' \
    /workspace/test/oracle/oracle-max-row.sql
expect_failure 'max_result_size' 'exceeding max_result_size of 1000' \
    /workspace/test/oracle/oracle-max-result.sql
expect_failure 'server max_field_size is the tightest ceiling' 'max_field_size of 100' \
    /workspace/test/oracle/oracle-server-max-field.sql
expect_failure 'server max_row_count is the tightest ceiling' 'scan returned more than 1 rows' \
    /workspace/test/oracle/oracle-server-max-row.sql
expect_failure 'server max_result_size is the tightest ceiling' 'max_result_size of 1000' \
    /workspace/test/oracle/oracle-server-max-result.sql
expect_failure 'zero-column import refusal' 'remote table "ODBC_FDW_DOES_NOT_EXIST" was not found' \
    /workspace/test/oracle/oracle-zero-column.sql
expect_failure 'read-only DML refusal' 'cannot insert into foreign table' \
    /workspace/test/oracle/oracle-read-only.sql

leak_session() {
    psql -X -q -t -A -h "${socket_dir}" -p "${port}" -U postgres postgres
}

# Count real PDB sessions through V_$SESSION. This needs a direct grant to the
# dedicated test account. The held cursor is the instrument control proving the
# account can see another session before any zero-delta result is trusted.
#
# The foreign tables are created in their own backend, and the account's ability
# to SEE V_$SESSION is established separately, because the two failures are not
# the same thing. Without that split, an account lacking the grant fails the
# whole suite with a message about reading four counts, which reads as a leak
# regression and is not one -- it is a privilege the fixtures never had. The
# readings below still share ONE backend with the scans they measure, which is
# what the gate actually depends on.
leak_setup_stderr="$(mktemp)"
psql -X -q -t -A -h "${socket_dir}" -p "${port}" -U postgres postgres \
    -f /workspace/test/oracle/oracle-leak-setup.sql >/dev/null 2>"${leak_setup_stderr}" \
    || fail "the session-leak fixtures could not be created: $(awk '/^psql:.*ERROR:/ { sub(/^.*ERROR:  */, ""); print; exit }' "${leak_setup_stderr}")"
rm -f "${leak_setup_stderr}"

session_probe_stderr="$(mktemp)"
session_probe="$(echo 'SELECT session_count FROM probe.oracle_sessions;' \
    | leak_session 2>"${session_probe_stderr}")"
# The WHOLE diagnostic, not its first line: odbc_fdw reports its own message
# ("Executing ODBC query") and carries the driver's text on a continuation line,
# so ORA-00942 never appears where an ERROR:/DETAIL: parse would find it.
session_probe_err="$(cat "${session_probe_stderr}")"
session_probe_reason="$(awk '/^ERROR:/ { sub(/^ERROR:  */, ""); print; exit }' "${session_probe_stderr}")"
rm -f "${session_probe_stderr}"

if [[ ! "${session_probe}" =~ ^[0-9]+$ ]]; then
    # Only a visibility problem may skip. Anything else is a real failure and
    # must stay one, or this becomes a gate that disables itself under load.
    case "${session_probe_err}" in
        *ORA-00942*|*ORA-01031*|*42S02*|*"table or view does not exist"*|*"insufficient privileges"*)
            leak_summary=$'\n  session-leak gate SKIPPED: ORACLE_USER cannot read SYS.V_$SESSION.'
            leak_summary+=' Run GRANT SELECT ON SYS.V_$SESSION TO <ORACLE_USER>; as a DBA to enable it.'
            ;;
        *)
            fail "the session-leak gate could not read a session count: ${session_probe_reason:-no error reported}"
            ;;
    esac
fi

if [[ -z "${leak_summary:-}" ]]; then
leak_stderr="$(mktemp)"
leak_counts="$( {
    echo 'SELECT session_count FROM probe.oracle_sessions;'
    echo 'BEGIN;'
    echo 'DECLARE leak_held CURSOR FOR SELECT id FROM probe.leak_success;'
    echo 'SELECT session_count FROM probe.oracle_sessions;'
    echo 'CLOSE leak_held;'
    echo 'COMMIT;'
    for ((n = 0; n < 20; n++)); do
        echo 'SELECT count(*) FROM probe.leak_source;'
    done
    echo 'SELECT session_count FROM probe.oracle_sessions;'
    echo '\o /dev/null'
    for ((n = 0; n < 20; n++)); do
        echo 'SELECT count(*) FROM probe.leak_success;'
    done
    echo '\o'
    echo 'SELECT session_count FROM probe.oracle_sessions;'
} | leak_session 2>"${leak_stderr}" )"

leak_refusals="$(grep -c '^ERROR:  odbc_fdw: scan returned more than 1 rows' "${leak_stderr}" || true)"
leak_reason="$(awk '/^ERROR:/ { sub(/^ERROR:  */, ""); print; exit }' "${leak_stderr}")"
rm -f "${leak_stderr}"
mapfile -t leak_lines <<<"${leak_counts}"
[[ "${#leak_lines[@]}" -eq 4 ]] \
    || fail "${checks} pre-gate assertions passed; the session-leak gate could not read four Oracle session counts: ${leak_reason:-no error reported; grant SELECT ON V_\$SESSION directly to ORACLE_USER}"
[[ "${leak_lines[1]}" -gt "${leak_lines[0]}" ]] \
    || fail 'the Oracle session-leak gate could not see the deliberately held second connection'
checks=$(( checks + 1 ))
[[ "${leak_refusals}" -eq 20 ]] \
    || fail "the session-leak gate expected 20 refused scans, got ${leak_refusals}"
checks=$(( checks + 1 ))
refused_delta=$(( leak_lines[2] - leak_lines[0] ))
[[ "${refused_delta}" -eq 0 ]] \
    || fail "20 refused scans leaked ${refused_delta} Oracle sessions"
checks=$(( checks + 1 ))
success_delta=$(( leak_lines[3] - leak_lines[2] ))
[[ "${success_delta}" -eq 0 ]] \
    || fail "20 successful scans leaked ${success_delta} Oracle sessions"
checks=$(( checks + 1 ))

# A connection opened in a committing subtransaction is adopted by its parent;
# aborting that parent must still release it.
commit_stderr="$(mktemp)"
commit_counts="$( {
    echo 'SELECT session_count FROM probe.oracle_sessions;'
    echo "DO \$\$ BEGIN BEGIN PERFORM count(*) FROM probe.leak_success; EXCEPTION WHEN OTHERS THEN RAISE; END; RAISE EXCEPTION 'force outer transaction abort'; END \$\$;"
    echo 'SELECT session_count FROM probe.oracle_sessions;'
} | leak_session 2>"${commit_stderr}" )"
commit_errors="$(grep -c '^ERROR:' "${commit_stderr}" || true)"
commit_outer="$(grep -c 'force outer transaction abort' "${commit_stderr}" || true)"
rm -f "${commit_stderr}"
[[ "${commit_errors}" -eq 1 && "${commit_outer}" -eq 1 ]] \
    || fail 'the successful-subtransaction probe did not reach its deliberate outer abort'
[[ "$(grep -c . <<<"${commit_counts}")" -eq 2 ]] \
    || fail 'the successful-subtransaction probe could not read both Oracle session counts'
commit_delta=$(( $(tail -n 1 <<<"${commit_counts}") - $(head -n 1 <<<"${commit_counts}") ))
[[ "${commit_delta}" -eq 0 ]] \
    || fail "a committed subtransaction followed by an outer abort leaked ${commit_delta} Oracle sessions"
checks=$(( checks + 1 ))
fi

if [[ -n "${ORACLE_BULK_ROWS:-}" ]]; then
    [[ "${ORACLE_BULK_ROWS}" =~ ^[1-9][0-9]*$ ]] \
        || fail 'ORACLE_BULK_ROWS must be a positive integer'
    # This gate asserts that two bulk transfers leak no sessions, so it cannot
    # run without the same grant. Refused rather than skipped: the operator
    # asked for it explicitly.
    [[ -z "${leak_summary:-}" ]] \
        || fail 'ORACLE_BULK_ROWS needs the session-leak grant: GRANT SELECT ON SYS.V_$SESSION TO <ORACLE_USER>;'
    bulk_checksum=$(( ORACLE_BULK_ROWS * (ORACLE_BULK_ROWS + 1) / 2 ))
    bulk_rss="SELECT (string_to_array(pg_read_file('/proc/self/statm', 0, 128), ' '))[2]::bigint * 4096"
    bulk_scan="SELECT count(*) || '/' || sum(id)::bigint FROM probe.bulk"
    bulk_stderr="$(mktemp)"
    bulk_out="$( {
        cat /workspace/test/oracle/oracle-bulk-setup.sql
        echo 'SELECT count(*) FROM probe.direct_types;'
        echo 'SELECT session_count FROM probe.oracle_sessions;'
        echo "${bulk_scan};"
        echo "${bulk_rss};"
        echo "${bulk_scan};"
        echo "${bulk_rss};"
        echo 'SELECT session_count FROM probe.oracle_sessions;'
    } | leak_session 2>"${bulk_stderr}" )"
    bulk_reason="$(awk '/^ERROR:/ { sub(/^ERROR:  */, ""); print; exit }' "${bulk_stderr}")"
    rm -f "${bulk_stderr}"
    mapfile -t bulk_lines <<<"${bulk_out}"
    [[ "${#bulk_lines[@]}" -eq 7 ]] \
        || fail "the bulk probe produced ${#bulk_lines[@]} readings, expected 7: ${bulk_reason:-was ODBC_FDW_BULK seeded?}"
    for pass in 1 2; do
        [[ "${bulk_lines[$(( pass * 2 ))]}" == "${ORACLE_BULK_ROWS}/${bulk_checksum}" ]] \
            || fail "bulk pass ${pass} returned the wrong row count/checksum"
    done
    checks=$(( checks + 1 ))
    bulk_rss_growth=$(( bulk_lines[5] - bulk_lines[3] ))
    [[ "${bulk_rss_growth}" -lt 4194304 ]] \
        || fail "a repeated ${ORACLE_BULK_ROWS}-row transfer grew backend RSS by ${bulk_rss_growth} bytes"
    checks=$(( checks + 1 ))
    bulk_session_delta=$(( bulk_lines[6] - bulk_lines[1] ))
    [[ "${bulk_session_delta}" -eq 0 ]] \
        || fail "two bulk transfers leaked ${bulk_session_delta} Oracle sessions"
    checks=$(( checks + 1 ))
    bulk_summary=", ${ORACLE_BULK_ROWS}-row transfer steady to within ${bulk_rss_growth} bytes"
else
    bulk_summary=' (bulk transfer SKIPPED; set ORACLE_BULK_ROWS in .env to run it)'
fi

echo "Oracle 19c integration suite through Instant Client 21: passed (${checks} assertions)${bulk_summary}${leak_summary:-}"
