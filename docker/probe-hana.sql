-- Read every value from the ENVIRONMENT, not from psql's argv. `-v name=value`
-- would put the tenant's password in /proc/<pid>/cmdline, which is world
-- readable; \getenv (psql 15+) reads /proc/<pid>/environ, which is not.
\getenv hana_servernode HANA_SERVERNODE
\getenv hana_database HANA_DATABASE
\getenv hana_user HANA_USER
\getenv hana_password HANA_PASSWORD
\getenv hana_encrypt HANA_ENCRYPT
\getenv hana_schema HANA_SCHEMA
\getenv hana_table HANA_TABLE
\getenv hana_value_column HANA_VALUE_COLUMN

CREATE EXTENSION odbc_fdw;
CREATE SCHEMA probe;

CREATE SERVER hana FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'HDBODBC',
    odbc_servernode :'hana_servernode',
    odbc_databasename :'hana_database',
    odbc_encrypt :'hana_encrypt'
);

CREATE USER MAPPING FOR CURRENT_USER SERVER hana OPTIONS (
    odbc_uid :'hana_user',
    odbc_pwd :'hana_password'
);

IMPORT FOREIGN SCHEMA :"hana_schema" LIMIT TO (:"hana_table")
    FROM SERVER hana INTO probe;

SELECT 'row_count=' || count(*) FROM probe.:"hana_table";
SELECT 'value=' || coalesce(:"hana_value_column"::text, '<NULL>')
    FROM probe.:"hana_table" LIMIT 1;
