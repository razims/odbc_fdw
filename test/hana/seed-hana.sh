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
# awk reading ENVIRON, not sed with the value spliced into its command line:
# /proc/<pid>/cmdline is world-readable for the life of the call, so an argv
# substitution publishes the tenant's schema name to every uid on the host.
# /proc/<pid>/environ is readable only by the same uid. Same reasoning as
# probe-hana.sh's refusal to pass HANA_* through psql -v. Both names are
# validated as plain identifiers/integers above, so neither can carry an `&`
# or a backslash into the replacement text.
awk '{ gsub(/@SCHEMA@/, ENVIRON["HANA_SCHEMA"]); print }' \
    /workspace/test/hana/seed-hana.sql \
    | hana-exec
echo 'HANA seed: ODBC_FDW_* fixture tables recreated'

# The bulk fixture is opt-in, because a million rows across the network turns a
# seconds-long probe into a minutes-long one and leaves a correspondingly large
# table in the schema. Unset means not created, and the probe says so out loud
# rather than reporting a pass for a check that never ran.
if [[ -n "${HANA_BULK_ROWS:-}" ]]; then
    [[ "${HANA_BULK_ROWS}" =~ ^[1-9][0-9]*$ ]] \
        || fail 'HANA_BULK_ROWS must be a positive integer'
    awk '{ gsub(/@SCHEMA@/, ENVIRON["HANA_SCHEMA"]);
           gsub(/@ROWS@/, ENVIRON["HANA_BULK_ROWS"]); print }' \
        /workspace/test/hana/seed-hana-bulk.sql \
        | hana-exec
    echo "HANA seed: ODBC_FDW_BULK recreated with ${HANA_BULK_ROWS} rows"
fi
