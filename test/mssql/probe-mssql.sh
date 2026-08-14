#!/usr/bin/env bash
set -Eeuo pipefail

PROBE_NAME='SQL Server probe'
source /workspace/test/common/probe-lib.sh

for required in MSSQL_HOST MSSQL_PORT MSSQL_DATABASE MSSQL_USER MSSQL_PASSWORD; do
    [[ -n "${!required:-}" ]] || probe_fail "${required} is not set"
done
probe_prepare 55437
probe_require_driver 'ODBC Driver 18 for SQL Server'

export ODBC_TEST_CONNECTION_STRING="DRIVER={ODBC Driver 18 for SQL Server};SERVER=${MSSQL_HOST},${MSSQL_PORT};DATABASE=${MSSQL_DATABASE};UID=${MSSQL_USER};PWD=${MSSQL_PASSWORD};Encrypt=yes;TrustServerCertificate=yes;"
odbc-exec < /workspace/test/mssql/seed-mssql.sql

probe_build_and_start
if ! probe_output="$(probe_psql postgres -f /workspace/test/mssql/probe-mssql.sql 2>&1)"; then
    if [[ -n "${PROBE_DEBUG:-}" ]]; then printf '%s\n' "${probe_output}" >&2; fi
    error_line="$(sed -n 's|.*probe-mssql.sql:\([0-9][0-9]*\): ERROR:.*|\1|p' <<<"${probe_output}")"
    error_line="${error_line%%$'\n'*}"
    error_kind="$(sed -n 's|.*ERROR:  \([^;]*\).*|\1|p' <<<"${probe_output}")"
    error_kind="${error_kind%%$'\n'*}"
    probe_fail "probe SQL failed at line ${error_line:-unknown}: ${error_kind:-unexpected database error}"
fi

assertions=(
    direct_scalar direct_temporal direct_unicode_null import_types type_matrix
    type_matrix_nulls import_type_matrix case_names sql_query wide_decimal wide_decimal_scale0 parameter_in_out
    large_value rescan
)
for assertion in "${assertions[@]}"; do
    if ! grep -qxF "${assertion}=ok" <<<"${probe_output}"; then
        if [[ -n "${PROBE_DEBUG:-}" ]]; then printf '%s\n' "${probe_output}" >&2; fi
        probe_fail "the ${assertion} assertion did not pass"
    fi
done
checks=${#assertions[@]}

probe_expect_failure 'invalid max_result_size at DDL time' 'requires a non-negative integer' \
    "ALTER SERVER mssql OPTIONS (ADD max_result_size '-1')"
probe_expect_failure 'max_field_size' 'field value' \
    "ALTER FOREIGN TABLE probe.large_values OPTIONS (ADD max_field_size '100'); SELECT text_value FROM probe.large_values"
probe_expect_failure 'max_row_count' 'scan returned more than 1 rows' \
    "ALTER FOREIGN TABLE probe.direct_types OPTIONS (ADD max_row_count '1'); SELECT count(*) FROM probe.direct_types"
probe_expect_failure 'max_result_size' 'exceeding max_result_size of 1000' \
    "ALTER FOREIGN TABLE probe.large_values OPTIONS (ADD max_result_size '1000'); SELECT text_value FROM probe.large_values"
probe_expect_failure 'server max_field_size is tightest' 'max_field_size of 100' \
    "SELECT text_value FROM probe.large_server_field"
probe_expect_failure 'server max_row_count is tightest' 'scan returned more than 1 rows' \
    "SELECT count(*) FROM probe.direct_server_row"
probe_expect_failure 'server max_result_size is tightest' 'max_result_size of 1000' \
    "SELECT text_value FROM probe.large_server_result"
probe_expect_failure 'zero-column import refusal' 'was not found' \
    "IMPORT FOREIGN SCHEMA dbo LIMIT TO (\"ODBC_FDW_DOES_NOT_EXIST\") FROM SERVER mssql INTO imported"
probe_expect_failure 'read-only DML refusal' 'cannot insert into foreign table' \
    "INSERT INTO probe.rescan_source VALUES (2, 'write')"

echo "SQL Server 2025 Express integration suite through Microsoft ODBC Driver 18.6.2.1: passed (${checks} assertions)"
