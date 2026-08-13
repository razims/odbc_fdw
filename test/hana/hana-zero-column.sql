\getenv hana_schema HANA_SCHEMA
CREATE SCHEMA missing_import;
IMPORT FOREIGN SCHEMA :"hana_schema" LIMIT TO ("ODBC_FDW_DOES_NOT_EXIST")
    FROM SERVER hana INTO missing_import;
