#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
    echo "Oracle cleanup: $*" >&2
    exit 1
}

require_value() {
    local name="$1"
    local value="${!name:-}"
    [[ -n "${value}" && "${value}" != 'replace-me' ]] \
        || fail "set ${name} in .env before cleanup"
}

for required in ORACLE_HOST ORACLE_PORT ORACLE_SERVICE ORACLE_USER ORACLE_PASSWORD ORACLE_SCHEMA; do
    require_value "${required}"
done

[[ "${ORACLE_PORT}" =~ ^[0-9]+$ ]] \
    && (( 10#${ORACLE_PORT} >= 1 && 10#${ORACLE_PORT} <= 65535 )) \
    || fail 'ORACLE_PORT must be an integer from 1 through 65535'
[[ "${ORACLE_SCHEMA}" =~ ^[A-Z][A-Z0-9_]*$ ]] \
    || fail 'ORACLE_SCHEMA must be a plain uppercase unquoted Oracle identifier'

awk '{ gsub(/@SCHEMA@/, ENVIRON["ORACLE_SCHEMA"]); print }' \
    /workspace/test/oracle/clean-oracle.sql \
    | oracle-exec
echo 'Oracle cleanup: ODBC_FDW_* fixture tables removed from the PDB'
