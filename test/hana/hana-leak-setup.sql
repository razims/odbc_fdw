-- Foreign tables for the connection-leak gate.
--
-- In their own file because the gate has to run this setup, the scans it
-- measures, and both counts inside ONE psql session: the ODBC handles are held
-- by the backend that leaked them and are released when that backend exits, so
-- a per-statement `psql -c` would tidy away the very thing being counted.
\getenv hana_schema HANA_SCHEMA
\getenv hana_test_application HANA_TEST_APPLICATION

-- Build the remote SQL locally so psql quotes the per-run marker as one SQL
-- literal while the FDW still receives the complete query as its sql_query
-- option value.
-- M_SESSION_CONTEXT, not M_CONNECTIONS. The marker is set as the HANA session
-- variable APPLICATION (see odbc_sessionvariable_application on the server),
-- and a session variable surfaces as a KEY/VALUE row in M_SESSION_CONTEXT --
-- M_CONNECTIONS has no column carrying it. Selecting a column that does not
-- exist makes the whole count query fail, which the harness sees as "could not
-- read" rather than as a leak; that is the guard working, but the query has to
-- be right for the gate to measure anything at all.
--
-- The marker is unique per run, so no user or client filter is needed: nothing
-- else on the tenant can be carrying this value.
SELECT format(
    'SELECT COUNT(*) AS "SESSION_COUNT" FROM "SYS"."M_SESSION_CONTEXT" WHERE "KEY" = ''APPLICATION'' AND "VALUE" = %L',
    :'hana_test_application'
) AS hana_session_query \gset

-- The tenant's own view of what a leak costs. M_SESSION_CONTEXT is read through
-- the wrapper under test, which is sound for a DELTA: the counting scan's own
-- connection carries the marker too, so it is a constant that appears in both
-- measurements. Requires the probe user to be able to see sessions other than
-- its own in SYS.M_SESSION_CONTEXT -- which is the whole point, and is exactly
-- what the gate would silently lose if it could not.
CREATE FOREIGN TABLE probe.hana_sessions (
    session_count bigint
) SERVER hana OPTIONS (
    sql_query :'hana_session_query',
    session_count 'SESSION_COUNT');

-- A scan that is always refused, by the tightest ceiling available. Every error
-- raised from inside a scan unwinds past odbcEndForeignScan, so before the
-- handle-lifetime fix this leaked one tenant session per execution.
CREATE FOREIGN TABLE probe.leak_source (
    id integer,
    text_value text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_DATA_TYPES', max_row_count '1',
    id 'ID', text_value 'TEXT_VALUE');

-- The same source without a ceiling. This opens a connection successfully in
-- a committing subtransaction; the harness then aborts its parent to verify
-- that ownership was correctly adopted and released.
CREATE FOREIGN TABLE probe.leak_success (
    id integer,
    text_value text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_DATA_TYPES',
    id 'ID', text_value 'TEXT_VALUE');
