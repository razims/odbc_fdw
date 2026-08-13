\getenv hana_schema HANA_SCHEMA
CREATE FOREIGN TABLE probe.limit_row (
    id integer,
    text_value text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_DATA_TYPES', max_row_count '1',
    id 'ID', text_value 'TEXT_VALUE');
SELECT count(*) FROM probe.limit_row;
