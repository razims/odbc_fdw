\getenv oracle_schema ORACLE_SCHEMA
CREATE FOREIGN TABLE probe.server_limit_row (
    id integer,
    text_value text
) SERVER oracle_server_row OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_DATA_TYPES', max_row_count '2',
    id 'ID', text_value 'TEXT_VALUE');
SELECT count(*) FROM probe.server_limit_row;
