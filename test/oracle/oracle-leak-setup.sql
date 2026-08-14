-- Run this file and every reading below it in one PostgreSQL backend. A new
-- psql process would close the leaked handles before they can be observed.
\getenv oracle_schema ORACLE_SCHEMA
\getenv oracle_user ORACLE_USER

-- The dedicated Oracle test user needs a direct SELECT grant on V_$SESSION.
-- The counting connection is included in every reading and is therefore a
-- constant; the gate compares deltas and proves visibility with a held cursor.
SELECT format(
    'SELECT COUNT(*) AS "SESSION_COUNT" FROM SYS.V_$SESSION WHERE "USERNAME" = UPPER(%L)',
    :'oracle_user'
) AS oracle_session_query \gset

CREATE FOREIGN TABLE probe.oracle_sessions (
    session_count bigint
) SERVER oracle OPTIONS (
    sql_query :'oracle_session_query', session_count 'SESSION_COUNT');

CREATE FOREIGN TABLE probe.leak_source (
    id integer,
    text_value text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_DATA_TYPES', max_row_count '1',
    id 'ID', text_value 'TEXT_VALUE');

CREATE FOREIGN TABLE probe.leak_success (
    id integer,
    text_value text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_DATA_TYPES',
    id 'ID', text_value 'TEXT_VALUE');
