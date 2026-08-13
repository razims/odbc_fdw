#!/usr/bin/env bash
set -Eeuo pipefail

readonly pg_bin="$(dirname "${PG_CONFIG}")"
readonly test_root="$(mktemp -d)"
readonly pgdata="${test_root}/data"
readonly socket_dir="${test_root}/socket"
readonly port=55432
readonly source_dir="${test_root}/source"

cleanup() {
    if [[ -f "${pgdata}/postmaster.pid" ]]; then
        runuser -u postgres -- "${pg_bin}/pg_ctl" -D "${pgdata}" -m immediate stop >/dev/null 2>&1 || true
    fi
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail() {
    echo "local ODBC smoke test: $*" >&2
    exit 1
}

psql_local() {
    psql -X -v ON_ERROR_STOP=1 -h "${socket_dir}" -p "${port}" -U postgres "$@"
}

mkdir -p "${source_dir}"
cp -a /workspace/Makefile /workspace/odbc_fdw.control \
    /workspace/odbc_fdw--*.sql "${source_dir}/"
cp -a /workspace/src "${source_dir}/src"
make -C "${source_dir}" clean
make -C "${source_dir}" USE_PGXS=1 PG_CONFIG="${PG_CONFIG}"
make -C "${source_dir}" install USE_PGXS=1 PG_CONFIG="${PG_CONFIG}"

odbcinst -q -d | grep -Fx '[PostgreSQL Unicode]' >/dev/null \
    || fail 'the Debian psqlODBC driver was not registered as [PostgreSQL Unicode]'

mkdir -p "${pgdata}" "${socket_dir}"
chown -R postgres:postgres "${test_root}"
runuser -u postgres -- "${pg_bin}/initdb" \
    --no-locale --encoding=UTF8 --auth-local=trust --auth-host=trust \
    -D "${pgdata}" >/dev/null
runuser -u postgres -- "${pg_bin}/pg_ctl" -D "${pgdata}" \
    -o "-k ${socket_dir} -h 127.0.0.1 -p ${port}" -w start >/dev/null

psql_local postgres <<'SQL'
CREATE DATABASE remotedb;
CREATE DATABASE fdwtest;
SQL

psql_local remotedb <<'SQL'
CREATE TABLE public.small (
    id integer PRIMARY KEY,
    label text NOT NULL,
    big text NOT NULL
);
INSERT INTO public.small VALUES
    (1, 'first', repeat('x', 10000)),
    (2, 'second', 'small value');
SQL

psql_local fdwtest <<'SQL'
CREATE EXTENSION odbc_fdw;
CREATE SCHEMA ext;
CREATE SERVER loopback FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'PostgreSQL Unicode',
    odbc_servername '127.0.0.1',
    odbc_port '55432',
    odbc_database 'remotedb'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER loopback OPTIONS (odbc_uid 'postgres');
IMPORT FOREIGN SCHEMA public LIMIT TO ("small") FROM SERVER loopback INTO ext;
SQL

[[ "$(psql_local fdwtest -Atqc 'SELECT string_agg(label, chr(44) ORDER BY id) FROM ext.small')" == 'first,second' ]] \
    || fail 'the loopback ODBC scan returned unexpected values'

if psql_local fdwtest -c "CREATE FUNCTION missing_symbol() RETURNS void AS '\$libdir/odbc_fdw', 'no_such_symbol' LANGUAGE C" >/dev/null 2>&1; then
    fail 'CREATE EXTENSION symbol-resolution negative control unexpectedly succeeded'
fi

if psql_local fdwtest -c "CREATE SERVER invalid_limit FOREIGN DATA WRAPPER odbc_fdw OPTIONS (max_row_count 'not-a-number')" >/dev/null 2>&1; then
    fail 'the validator accepted an invalid max_row_count'
fi

psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (ADD max_field_size '10')" >/dev/null
if psql_local fdwtest -c 'SELECT big FROM ext.small' >/dev/null 2>&1; then
    fail 'max_field_size did not refuse the oversized field'
fi

psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (DROP max_field_size, ADD max_row_count '1')" >/dev/null
if psql_local fdwtest -c 'SELECT count(*) FROM ext.small' >/dev/null 2>&1; then
    fail 'max_row_count did not refuse the second row'
fi

# max_result_size, and the pair is the point: the same scan must PASS with both
# other ceilings satisfied and FAIL only once the aggregate ceiling is set.
# Without the passing half this asserts nothing about WHICH ceiling refused.
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (SET max_row_count '100', ADD max_field_size '20000')" >/dev/null
psql_local fdwtest -c 'SELECT count(*) FROM ext.small' >/dev/null \
    || fail 'a scan within max_field_size and max_row_count was refused'
psql_local fdwtest -c "ALTER FOREIGN TABLE ext.small OPTIONS (ADD max_result_size '1000')" >/dev/null
if psql_local fdwtest -c 'SELECT count(*) FROM ext.small' >/dev/null 2>&1; then
    fail 'max_result_size did not refuse a scan over its aggregate ceiling'
fi

# Tightest wins: a foreign table must not be able to raise its server's ceiling.
psql_local fdwtest <<'SQL' >/dev/null
ALTER SERVER loopback OPTIONS (ADD max_row_count '1');
ALTER FOREIGN TABLE ext.small OPTIONS (DROP max_result_size, SET max_row_count '1000000');
SQL
if psql_local fdwtest -c 'SELECT count(*) FROM ext.small' >/dev/null 2>&1; then
    fail 'a foreign table raised a ceiling set on its server'
fi

# ReScanForeignScan must restart the scan. A correlated subquery over two local
# rows has to find a remote row twice; a no-op rescan returns the first and NULL.
psql_local fdwtest <<'SQL' >/dev/null
ALTER SERVER loopback OPTIONS (DROP max_row_count);
ALTER FOREIGN TABLE ext.small OPTIONS (DROP max_row_count, DROP max_field_size);
CREATE TABLE two_rows (id integer);
INSERT INTO two_rows VALUES (1), (2);
SQL
[[ "$(psql_local fdwtest -Atqc "SELECT string_agg(x, chr(44) ORDER BY id) FROM (SELECT t.id, (SELECT s.label FROM ext.small s WHERE s.id = t.id) AS x FROM two_rows t) q")" == 'first,second' ]] \
    || fail 'a rescanned foreign scan did not restart, so later scans returned no rows'

echo 'local ODBC smoke test: passed'
