\getenv oracle_schema ORACLE_SCHEMA
CREATE FOREIGN TABLE probe.limit_result (
    id integer,
    clob_value text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_LARGE_VALUES', max_result_size '1000',
    id 'ID', clob_value 'CLOB_VALUE');
SELECT clob_value FROM probe.limit_result;
