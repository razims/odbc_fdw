#!/usr/bin/env bash

probe_fail() {
    echo "${PROBE_NAME}: $*" >&2
    exit 1
}

probe_prepare() {
    local port="$1"

    PROBE_PG_BIN="$(dirname "${PG_CONFIG}")"
    PROBE_ROOT="$(mktemp -d)"
    PROBE_PGDATA="${PROBE_ROOT}/data"
    PROBE_SOCKET="${PROBE_ROOT}/socket"
    PROBE_SOURCE="${PROBE_ROOT}/source"
    PROBE_PORT="${port}"
    export PROBE_PG_BIN PROBE_ROOT PROBE_PGDATA PROBE_SOCKET PROBE_SOURCE PROBE_PORT
    trap probe_cleanup EXIT
}

probe_cleanup() {
    if [[ -n "${PROBE_PGDATA:-}" && -f "${PROBE_PGDATA}/postmaster.pid" ]]; then
        runuser -u postgres -- "${PROBE_PG_BIN}/pg_ctl" \
            -D "${PROBE_PGDATA}" -m immediate stop >/dev/null 2>&1 || true
    fi
    if [[ -n "${PROBE_ROOT:-}" ]]; then
        rm -rf "${PROBE_ROOT}"
    fi
}

probe_psql() {
    psql -X -q -t -A -v ON_ERROR_STOP=1 \
        -h "${PROBE_SOCKET}" -p "${PROBE_PORT}" -U postgres "$@"
}

probe_build_and_start() {
    mkdir -p "${PROBE_SOURCE}" "${PROBE_PGDATA}" "${PROBE_SOCKET}"
    cp -a /workspace/Makefile /workspace/odbc_fdw.control "${PROBE_SOURCE}/"
    cp -a /workspace/src /workspace/sql "${PROBE_SOURCE}/"
    make -C "${PROBE_SOURCE}" clean >/dev/null
    make -C "${PROBE_SOURCE}" USE_PGXS=1 PG_CONFIG="${PG_CONFIG}" >/dev/null
    make -C "${PROBE_SOURCE}" install USE_PGXS=1 PG_CONFIG="${PG_CONFIG}" >/dev/null

    chown -R postgres:postgres "${PROBE_ROOT}"
    runuser --preserve-environment -u postgres -- "${PROBE_PG_BIN}/initdb" \
        --no-locale --encoding=UTF8 --auth-local=trust --auth-host=trust \
        -D "${PROBE_PGDATA}" >/dev/null
    runuser --preserve-environment -u postgres -- "${PROBE_PG_BIN}/pg_ctl" \
        -D "${PROBE_PGDATA}" \
        -o "-k ${PROBE_SOCKET} -h 127.0.0.1 -p ${PROBE_PORT}" \
        -w start >/dev/null
}

probe_expect_failure() {
    local name="$1"
    local expected="$2"
    local sql="$3"
    local output

    if output="$(probe_psql postgres -c "${sql}" 2>&1)"; then
        probe_fail "${name} unexpectedly succeeded"
    fi
    grep -Fq "${expected}" <<<"${output}" \
        || probe_fail "${name} failed for an unexpected reason"
    checks=$(( checks + 1 ))
}

probe_require_driver() {
    local driver="$1"

    odbcinst -q -d | grep -Fx "[${driver}]" >/dev/null \
        || probe_fail "ODBC driver '${driver}' is not registered"
}
