#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
    echo "Oracle seed: $*" >&2
    exit 1
}

require_value() {
    local name="$1"
    local value="${!name:-}"
    [[ -n "${value}" && "${value}" != 'replace-me' ]] \
        || fail "set ${name} in .env before seeding"
}

for required in ORACLE_HOST ORACLE_PORT ORACLE_SERVICE ORACLE_USER ORACLE_PASSWORD ORACLE_SCHEMA; do
    require_value "${required}"
done

[[ "${ORACLE_PORT}" =~ ^[0-9]+$ ]] \
    && (( 10#${ORACLE_PORT} >= 1 && 10#${ORACLE_PORT} <= 65535 )) \
    || fail 'ORACLE_PORT must be an integer from 1 through 65535'
[[ "${ORACLE_SCHEMA}" =~ ^[A-Z][A-Z0-9_]*$ ]] \
    || fail 'ORACLE_SCHEMA must be a plain uppercase unquoted Oracle identifier'

# Values travel through the environment rather than argv. Only the validated
# schema identifier is substituted into SQL; credentials are consumed directly
# by oracle-exec when it builds the ODBC connection string.
awk '{ gsub(/@SCHEMA@/, ENVIRON["ORACLE_SCHEMA"]); print }' \
    /workspace/test/oracle/seed-oracle.sql \
    | oracle-exec
echo 'Oracle seed: ODBC_FDW_* fixture tables recreated in the PDB'

if [[ -n "${ORACLE_BULK_ROWS:-}" ]]; then
    [[ "${ORACLE_BULK_ROWS}" =~ ^[1-9][0-9]*$ ]] \
        || fail 'ORACLE_BULK_ROWS must be a positive integer'
    awk '{ gsub(/@SCHEMA@/, ENVIRON["ORACLE_SCHEMA"]);
           gsub(/@ROWS@/, ENVIRON["ORACLE_BULK_ROWS"]); print }' \
        /workspace/test/oracle/seed-oracle-bulk.sql \
        | oracle-exec
    echo "Oracle seed: ODBC_FDW_BULK recreated with ${ORACLE_BULK_ROWS} rows"
fi
