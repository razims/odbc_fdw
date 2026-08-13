\getenv hana_schema HANA_SCHEMA
CREATE FOREIGN TABLE probe.server_limit_row (
    id integer,
    text_value text
) SERVER hana_server_row OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_DATA_TYPES', max_row_count '2',
    id 'ID', text_value 'TEXT_VALUE');
SELECT count(*) FROM probe.server_limit_row;
