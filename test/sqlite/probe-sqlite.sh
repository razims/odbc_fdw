#!/usr/bin/env bash
set -Eeuo pipefail

PROBE_NAME='SQLite probe'
source /workspace/test/common/probe-lib.sh

probe_prepare 55435
probe_require_driver SQLite3

export SQLITE_DATABASE="${PROBE_ROOT}/odbc-fdw.sqlite"
sqlite3 "${SQLITE_DATABASE}" < /workspace/test/sqlite/seed-sqlite.sql
[[ "$(sqlite3 "${SQLITE_DATABASE}" 'SELECT sqlite_version();')" == '3.53.4' ]] \
    || probe_fail 'the fixture is not using SQLite 3.53.4'

probe_build_and_start

if ! probe_output="$(probe_psql postgres -f /workspace/test/sqlite/probe-sqlite.sql 2>&1)"; then
    if [[ -n "${PROBE_DEBUG:-}" ]]; then
        printf '%s\n' "${probe_output}" >&2
    fi
    error_line="$(sed -n 's|.*probe-sqlite.sql:\([0-9][0-9]*\): ERROR:.*|\1|p' <<<"${probe_output}")"
    error_line="${error_line%%$'\n'*}"
    error_kind="$(sed -n 's|.*ERROR:  \([^;]*\).*|\1|p' <<<"${probe_output}")"
    error_kind="${error_kind%%$'\n'*}"
    probe_fail "probe SQL failed at line ${error_line:-unknown}: ${error_kind:-unexpected database error}"
fi

assertions=(
    import_metadata direct_scalar direct_temporal direct_unicode_null import_types type_matrix
    type_matrix_nulls import_type_matrix json case_names sql_query
    parameter_in_out large_value rescan
)
for assertion in "${assertions[@]}"; do
    if ! grep -qxF "${assertion}=ok" <<<"${probe_output}"; then
        if [[ -n "${PROBE_DEBUG:-}" ]]; then
            printf '%s\n' "${probe_output}" >&2
        fi
        probe_fail "the ${assertion} assertion did not pass"
    fi
done
checks=${#assertions[@]}

probe_expect_failure 'invalid max_result_size at DDL time' \
    'requires a non-negative integer' \
    "ALTER SERVER sqlite OPTIONS (ADD max_result_size '-1')"
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
    "IMPORT FOREIGN SCHEMA ignored LIMIT TO (\"ODBC_FDW_DOES_NOT_EXIST\") FROM SERVER sqlite INTO imported OPTIONS (schema '')"
probe_expect_failure 'read-only DML refusal' 'cannot insert into foreign table' \
    "INSERT INTO probe.rescan_source VALUES (2, 'write')"

echo "SQLite 3.53.4 integration suite through SQLite ODBC 0.99991: passed (${checks} assertions)"
