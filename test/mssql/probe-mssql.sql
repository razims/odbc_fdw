\getenv mssql_host MSSQL_HOST
\getenv mssql_port MSSQL_PORT
\getenv mssql_database MSSQL_DATABASE
\getenv mssql_user MSSQL_USER
\getenv mssql_password MSSQL_PASSWORD
\set mssql_server :mssql_host ',' :mssql_port

CREATE EXTENSION odbc_fdw;
CREATE SCHEMA probe;

CREATE SERVER mssql FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'ODBC Driver 18 for SQL Server',
    odbc_server :'mssql_server', odbc_database :'mssql_database',
    odbc_encrypt 'yes', odbc_trustservercertificate 'yes',
    wide_char_mode 'wchar'
);
CREATE SERVER mssql_server_field FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'ODBC Driver 18 for SQL Server',
    odbc_server :'mssql_server', odbc_database :'mssql_database',
    odbc_encrypt 'yes', odbc_trustservercertificate 'yes',
    wide_char_mode 'wchar', max_field_size '100'
);
CREATE SERVER mssql_server_row FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'ODBC Driver 18 for SQL Server',
    odbc_server :'mssql_server', odbc_database :'mssql_database',
    odbc_encrypt 'yes', odbc_trustservercertificate 'yes',
    wide_char_mode 'wchar', max_row_count '1'
);
CREATE SERVER mssql_server_result FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'ODBC Driver 18 for SQL Server',
    odbc_server :'mssql_server', odbc_database :'mssql_database',
    odbc_encrypt 'yes', odbc_trustservercertificate 'yes',
    wide_char_mode 'wchar', max_result_size '1000'
);

CREATE USER MAPPING FOR CURRENT_USER SERVER mssql OPTIONS (
    odbc_uid :'mssql_user', odbc_pwd :'mssql_password'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER mssql_server_field OPTIONS (
    odbc_uid :'mssql_user', odbc_pwd :'mssql_password'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER mssql_server_row OPTIONS (
    odbc_uid :'mssql_user', odbc_pwd :'mssql_password'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER mssql_server_result OPTIONS (
    odbc_uid :'mssql_user', odbc_pwd :'mssql_password'
);

CREATE FOREIGN TABLE probe.direct_types (
    id integer, text_value text, integer_value integer, decimal_value numeric,
    date_value date, time_value time, timestamp_value timestamp,
    null_value text, unicode_value text
) SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_DATA_TYPES', id 'ID',
    text_value 'TEXT_VALUE', integer_value 'INTEGER_VALUE',
    decimal_value 'DECIMAL_VALUE', date_value 'DATE_VALUE', time_value 'TIME_VALUE',
    timestamp_value 'TIMESTAMP_VALUE', null_value 'NULL_VALUE',
    unicode_value 'UNICODE_VALUE'
);
CREATE FOREIGN TABLE probe.type_matrix (
    id integer, tiny_value smallint, small_value smallint,
    integer_value integer, bigint_value bigint, decimal_value numeric,
    real_value real, float_value double precision, bit_value boolean,
    char_value text, nchar_value text, varchar_value text, nvarchar_value text,
    text_value text, ntext_value text, date_value date, time_value time,
    datetime_value timestamp, smalldatetime_value timestamp, guid_value uuid,
    binary_value bytea, varbinary_value bytea, image_value bytea
) SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_TYPE_MATRIX', id 'ID',
    tiny_value 'TINY_VALUE', small_value 'SMALL_VALUE', integer_value 'INTEGER_VALUE',
    bigint_value 'BIGINT_VALUE', decimal_value 'DECIMAL_VALUE', real_value 'REAL_VALUE',
    float_value 'FLOAT_VALUE', bit_value 'BIT_VALUE', char_value 'CHAR_VALUE',
    nchar_value 'NCHAR_VALUE', varchar_value 'VARCHAR_VALUE',
    nvarchar_value 'NVARCHAR_VALUE', text_value 'TEXT_VALUE', ntext_value 'NTEXT_VALUE',
    date_value 'DATE_VALUE', time_value 'TIME_VALUE', datetime_value 'DATETIME_VALUE',
    smalldatetime_value 'SMALLDATETIME_VALUE', guid_value 'GUID_VALUE',
    binary_value 'BINARY_VALUE', varbinary_value 'VARBINARY_VALUE', image_value 'IMAGE_VALUE'
);
CREATE FOREIGN TABLE probe.large_values (id integer, text_value text, blob_value bytea)
SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_LARGE_VALUES', id 'ID',
    text_value 'TEXT_VALUE', blob_value 'BLOB_VALUE'
);
CREATE FOREIGN TABLE probe.large_server_field (id integer, text_value text)
SERVER mssql_server_field OPTIONS (
    schema 'dbo', table 'ODBC_FDW_LARGE_VALUES', id 'ID', text_value 'TEXT_VALUE'
);
CREATE FOREIGN TABLE probe.direct_server_row (id integer, text_value text)
SERVER mssql_server_row OPTIONS (
    schema 'dbo', table 'ODBC_FDW_DATA_TYPES', id 'ID', text_value 'TEXT_VALUE'
);
CREATE FOREIGN TABLE probe.large_server_result (id integer, text_value text)
SERVER mssql_server_result OPTIONS (
    schema 'dbo', table 'ODBC_FDW_LARGE_VALUES', id 'ID', text_value 'TEXT_VALUE'
);
CREATE FOREIGN TABLE probe.rescan_source (id integer, payload text)
SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_SINGLE_ROW', max_row_count '1',
    id 'ID', payload 'PAYLOAD'
);
CREATE FOREIGN TABLE probe.case_names (
    upper_value integer, lower_value text, mixed_value text, spaced_value text
) SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_CASE_NAMES', upper_value 'UPPER_VALUE',
    lower_value 'lower_value', mixed_value 'MixedValue', spaced_value 'Spaced Value'
);
CREATE FOREIGN TABLE probe.query_types (id integer, text_value text)
SERVER mssql OPTIONS (
    table 'query_types',
    sql_query 'SELECT [ID], [TEXT_VALUE] FROM [dbo].[ODBC_FDW_DATA_TYPES] WHERE [ID] = 1',
    id 'ID', text_value 'TEXT_VALUE'
);

CREATE SCHEMA imported;
IMPORT FOREIGN SCHEMA dbo
    LIMIT TO ("ODBC_FDW_DATA_TYPES", "ODBC_FDW_TYPE_MATRIX", "ODBC_FDW_CASE_NAMES")
    FROM SERVER mssql INTO imported;

SELECT 'direct_scalar=' || CASE WHEN
    (SELECT count(*) FROM probe.direct_types) = 2 AND
    (SELECT text_value FROM probe.direct_types WHERE id = 1) = 'alpha' AND
    (SELECT integer_value FROM probe.direct_types WHERE id = 1) = 42 AND
    (SELECT decimal_value FROM probe.direct_types WHERE id = 1) = 123.4500
    THEN 'ok' ELSE 'bad' END;
SELECT 'direct_temporal=' || CASE WHEN
    (SELECT date_value FROM probe.direct_types WHERE id = 1) = DATE '2024-01-02' AND
    (SELECT time_value FROM probe.direct_types WHERE id = 1) = TIME '03:04:05.123456' AND
    (SELECT timestamp_value FROM probe.direct_types WHERE id = 2) = TIMESTAMP '2024-12-31 23:59:59.654321'
    THEN 'ok' ELSE 'bad' END;
SELECT 'direct_unicode_null=' || CASE WHEN
    (SELECT null_value IS NULL FROM probe.direct_types WHERE id = 1) AND
    (SELECT unicode_value FROM probe.direct_types WHERE id = 2) = '東京'
    THEN 'ok' ELSE 'bad' END;
SELECT 'import_types=' || CASE WHEN
    (SELECT count(*) FROM imported."ODBC_FDW_DATA_TYPES") = 2 AND
    (SELECT "UNICODE_VALUE" FROM imported."ODBC_FDW_DATA_TYPES" WHERE "ID" = 2) = '東京'
    THEN 'ok' ELSE 'bad' END;
SELECT 'type_matrix=' || CASE WHEN
    (SELECT tiny_value FROM probe.type_matrix WHERE id = 1) = 255 AND
    (SELECT small_value FROM probe.type_matrix WHERE id = 1) = -32768 AND
    (SELECT integer_value FROM probe.type_matrix WHERE id = 1) = 2147483647 AND
    (SELECT bigint_value FROM probe.type_matrix WHERE id = 1) = 922337203685477580 AND
    (SELECT decimal_value FROM probe.type_matrix WHERE id = 1) = 12345678901234.5678 AND
    (SELECT real_value FROM probe.type_matrix WHERE id = 1) = 3.25::real AND
    (SELECT float_value FROM probe.type_matrix WHERE id = 1) = 1234567.125 AND
    (SELECT bit_value FROM probe.type_matrix WHERE id = 1) AND
    (SELECT rtrim(char_value) FROM probe.type_matrix WHERE id = 1) = 'abc' AND
    (SELECT rtrim(nchar_value) FROM probe.type_matrix WHERE id = 1) = '東京' AND
    (SELECT nvarchar_value FROM probe.type_matrix WHERE id = 1) = 'Grüße 東京' AND
    (SELECT ntext_value FROM probe.type_matrix WHERE id = 1) = 'long unicode Привет 東京' AND
    (SELECT guid_value FROM probe.type_matrix WHERE id = 1) = '01234567-89ab-cdef-0123-456789abcdef'::uuid AND
    (SELECT encode(binary_value, 'hex') FROM probe.type_matrix WHERE id = 1) = 'abcd0000' AND
    (SELECT encode(varbinary_value, 'hex') FROM probe.type_matrix WHERE id = 1) = '1020' AND
    (SELECT encode(image_value, 'hex') FROM probe.type_matrix WHERE id = 1) = '004142ff'
    THEN 'ok' ELSE 'bad' END;
SELECT 'type_matrix_nulls=' || CASE WHEN
    (SELECT tiny_value IS NULL AND small_value IS NULL AND integer_value IS NULL
            AND bigint_value IS NULL AND decimal_value IS NULL AND real_value IS NULL
            AND float_value IS NULL AND bit_value IS NULL AND char_value IS NULL
            AND nchar_value IS NULL AND varchar_value IS NULL AND nvarchar_value IS NULL
            AND text_value IS NULL AND ntext_value IS NULL AND date_value IS NULL
            AND time_value IS NULL AND datetime_value IS NULL AND smalldatetime_value IS NULL
            AND guid_value IS NULL AND binary_value IS NULL AND varbinary_value IS NULL
            AND image_value IS NULL
     FROM probe.type_matrix WHERE id = 2)
    THEN 'ok' ELSE 'bad' END;
SELECT 'import_type_matrix=' || CASE WHEN
    (SELECT "BIGINT_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 922337203685477580 AND
    (SELECT "NVARCHAR_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 'Grüße 東京' AND
    (SELECT encode("IMAGE_VALUE", 'hex') FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = '004142ff'
    THEN 'ok' ELSE 'bad' END;
SELECT 'case_names=' || CASE WHEN
    (SELECT upper_value FROM probe.case_names) = 1 AND
    (SELECT lower_value FROM probe.case_names) = 'lower column' AND
    (SELECT mixed_value FROM probe.case_names) = 'mixed column' AND
    (SELECT spaced_value FROM probe.case_names) = 'space column' AND
    (SELECT "MixedValue" FROM imported."ODBC_FDW_CASE_NAMES") = 'mixed column'
    THEN 'ok' ELSE 'bad' END;
SELECT 'sql_query=' || CASE WHEN
    (SELECT count(*) FROM probe.query_types) = 1 AND
    (SELECT text_value FROM probe.query_types) = 'alpha'
    THEN 'ok' ELSE 'bad' END;
SELECT 'parameter_in_out=' || CASE WHEN
    (SELECT string_agg(remote.text_value, ',' ORDER BY input.id)
     FROM (VALUES (1, 'alpha'::text), (2, 'beta'::text)) input(id, expected)
     CROSS JOIN LATERAL
         (SELECT text_value FROM probe.direct_types WHERE id = input.id) remote
     WHERE remote.text_value = input.expected) = 'alpha,beta'
    THEN 'ok' ELSE 'bad' END;
SELECT 'large_value=' || CASE WHEN
    (SELECT length(text_value) FROM probe.large_values) = 6000 AND
    (SELECT md5(text_value) FROM probe.large_values) = md5(repeat('x', 6000)) AND
    (SELECT encode(blob_value, 'hex') FROM probe.large_values) = '004142ff'
    THEN 'ok' ELSE 'bad' END;
SET enable_material = off;
SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT 'rescan=' || CASE WHEN
    (SELECT count(*) FROM (VALUES (1), (1)) outer_row(id)
     CROSS JOIN LATERAL
         (SELECT payload FROM probe.rescan_source WHERE id = outer_row.id) inner_row) = 2
    THEN 'ok' ELSE 'bad' END;
