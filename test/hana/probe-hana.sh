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
cp -a /workspace/Makefile /workspace/odbc_fdw.control \
    /workspace/odbc_fdw--*.sql "${source_dir}/"
cp -a /workspace/src "${source_dir}/src"
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

for assertion in direct_scalar direct_time direct_timestamp direct_unicode_null import_types type_matrix type_matrix_nulls import_type_matrix import_binary_boundary ascii_text cyrillic_text utf8_text json_direct json_import json_nulls direct_case_names import_case_names sql_query parameter_in_out large_value rescan; do
    grep -qxF "${assertion}=ok" <<<"${probe_output}" \
        || fail "the ${assertion} assertion did not pass"
done

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

echo 'HANA integration suite: passed (32 assertions)'
