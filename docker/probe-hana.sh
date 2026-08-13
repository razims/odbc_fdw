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

for required in \
    HANA_HOST HANA_PORT HANA_DATABASE HANA_USER HANA_PASSWORD HANA_SCHEMA \
    HANA_TABLE HANA_VALUE_COLUMN HANA_EXPECTED_ROW_COUNT HANA_EXPECTED_VALUE \
    HANA_ENCRYPT; do
    require_value "${required}"
done

[[ -f /opt/sap/hdbclient/libodbcHDB.so ]] \
    || fail 'the image does not contain the baked SAP HANA ODBC driver'
odbcinst -q -d | grep -Fx '[HDBODBC]' >/dev/null \
    || fail 'the image does not register the baked HDBODBC driver'

mkdir -p "${source_dir}"
cp -a /workspace/Makefile /workspace/odbc_fdw.c /workspace/odbc_fdw.control \
    /workspace/odbc_fdw--*.sql "${source_dir}/"
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

probe_output="$(psql_local postgres \
    -f /workspace/docker/probe-hana.sql)"

expected_output="row_count=${HANA_EXPECTED_ROW_COUNT}
value=${HANA_EXPECTED_VALUE}"
if [[ "${probe_output}" != "${expected_output}" ]]; then
    # Report WHICH half disagreed, never the values. One of them is a row from
    # somebody's production tenant and the other is in .env; printing either
    # would put tenant data into a terminal, a CI log or a pasted transcript.
    grep -qxF "row_count=${HANA_EXPECTED_ROW_COUNT}" <<<"${probe_output}" \
        || echo 'HANA probe: the imported row count did not match HANA_EXPECTED_ROW_COUNT' >&2
    grep -qxF "value=${HANA_EXPECTED_VALUE}" <<<"${probe_output}" \
        || echo 'HANA probe: the sample value did not match HANA_EXPECTED_VALUE' >&2
    fail 'the tenant did not return what .env says it holds'
fi

echo 'HANA probe: passed'
