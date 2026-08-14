\getenv oracle_schema ORACLE_SCHEMA
CREATE FOREIGN TABLE probe.bulk (
    id bigint,
    label text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_BULK',
    id 'ID', label 'LABEL');
