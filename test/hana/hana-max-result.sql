\getenv hana_schema HANA_SCHEMA
CREATE FOREIGN TABLE probe.limit_result (
    id integer,
    nclob_value text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_LARGE_VALUES', max_result_size '1000',
    id 'ID', nclob_value 'NCLOB_VALUE');
SELECT nclob_value FROM probe.limit_result;
