#!/usr/bin/env bash
set -Eeuo pipefail
fail() {
    echo "HANA cleanup: $*" >&2
    exit 1
}

require_value() {
    local name="$1"
    local value="${!name:-}"
    [[ -n "${value}" && "${value}" != 'replace-me' ]] || fail "set ${name} in .env before cleanup"
}

validate_schema() {
    [[ "${HANA_SCHEMA}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || fail 'HANA_SCHEMA must be a plain unquoted HANA identifier'
}

for required in HANA_HOST HANA_PORT HANA_DATABASE HANA_USER HANA_PASSWORD HANA_SCHEMA HANA_ENCRYPT; do
    require_value "${required}"
done

validate_schema

# awk reading ENVIRON rather than sed with the value in argv; see seed-hana.sh.
awk '{ gsub(/@SCHEMA@/, ENVIRON["HANA_SCHEMA"]); print }' \
    /workspace/test/hana/clean-hana.sql \
    | hana-exec
echo 'HANA cleanup: ODBC_FDW_* fixture tables removed'
