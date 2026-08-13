\getenv hana_schema HANA_SCHEMA
CREATE FOREIGN TABLE probe.server_limit_result (
    id integer,
    nclob_value text
) SERVER hana_server_result OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_LARGE_VALUES', max_result_size '20000',
    id 'ID', nclob_value 'NCLOB_VALUE');
SELECT nclob_value FROM probe.server_limit_result;
