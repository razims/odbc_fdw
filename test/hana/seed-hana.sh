#!/usr/bin/env bash
set -Eeuo pipefail
fail() {
    echo "HANA seed: $*" >&2
    exit 1
}

require_value() {
    local name="$1"
    local value="${!name:-}"
    [[ -n "${value}" && "${value}" != 'replace-me' ]] || fail "set ${name} in .env before seeding"
}

validate_schema() {
    [[ "${HANA_SCHEMA}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || fail 'HANA_SCHEMA must be a plain unquoted HANA identifier'
}

for required in HANA_HOST HANA_PORT HANA_DATABASE HANA_USER HANA_PASSWORD HANA_SCHEMA HANA_ENCRYPT; do
    require_value "${required}"
done

validate_schema

# hana-exec uses SQLDriverConnect with exactly the driver and connection options
# odbc_fdw uses. It reads credentials from environment, never from argv, and
# prints only a statement number and SQLSTATE on a failure.
sed "s/@SCHEMA@/${HANA_SCHEMA}/g" /workspace/test/hana/seed-hana.sql \
    | hana-exec
echo 'HANA seed: ODBC_FDW_* fixture tables recreated'
