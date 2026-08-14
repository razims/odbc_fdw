\getenv oracle_schema ORACLE_SCHEMA
CREATE SCHEMA missing_import;
IMPORT FOREIGN SCHEMA :"oracle_schema" LIMIT TO ("ODBC_FDW_DOES_NOT_EXIST")
    FROM SERVER oracle INTO missing_import;
