\getenv oracle_schema ORACLE_SCHEMA
CREATE FOREIGN TABLE probe.server_limit_result (
    id integer,
    clob_value text
) SERVER oracle_server_result OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_LARGE_VALUES', max_result_size '20000',
    id 'ID', clob_value 'CLOB_VALUE');
SELECT clob_value FROM probe.server_limit_result;
