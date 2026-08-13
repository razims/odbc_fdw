-- Foreign table for the optional bulk transfer gate. Its own file so the
-- schema name reaches psql through \getenv rather than through argv, where
-- /proc/<pid>/cmdline would expose a tenant value for the life of the call.
\getenv hana_schema HANA_SCHEMA

CREATE FOREIGN TABLE probe.bulk (
    id integer,
    label text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_BULK',
    id 'ID', label 'LABEL');
