\getenv mysql_host MYSQL_HOST
\getenv mysql_port MYSQL_PORT
\getenv mysql_database MYSQL_DATABASE
\getenv mysql_user MYSQL_USER
\getenv mysql_password MYSQL_PASSWORD

CREATE EXTENSION odbc_fdw;
CREATE SCHEMA probe;

CREATE SERVER mysql FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'MySQL ODBC 9.7 Unicode Driver',
    odbc_server :'mysql_host', odbc_port :'mysql_port',
    odbc_database :'mysql_database', wide_char_mode 'wchar'
);
CREATE SERVER mysql_server_field FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'MySQL ODBC 9.7 Unicode Driver',
    odbc_server :'mysql_host', odbc_port :'mysql_port',
    odbc_database :'mysql_database', wide_char_mode 'wchar', max_field_size '100'
);
CREATE SERVER mysql_server_row FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'MySQL ODBC 9.7 Unicode Driver',
    odbc_server :'mysql_host', odbc_port :'mysql_port',
    odbc_database :'mysql_database', wide_char_mode 'wchar', max_row_count '1'
);
CREATE SERVER mysql_server_result FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'MySQL ODBC 9.7 Unicode Driver',
    odbc_server :'mysql_host', odbc_port :'mysql_port',
    odbc_database :'mysql_database', wide_char_mode 'wchar', max_result_size '1000'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER mysql OPTIONS (
    odbc_uid :'mysql_user', odbc_pwd :'mysql_password'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER mysql_server_field OPTIONS (
    odbc_uid :'mysql_user', odbc_pwd :'mysql_password'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER mysql_server_row OPTIONS (
    odbc_uid :'mysql_user', odbc_pwd :'mysql_password'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER mysql_server_result OPTIONS (
    odbc_uid :'mysql_user', odbc_pwd :'mysql_password'
);

CREATE FOREIGN TABLE probe.direct_types (
    id integer, text_value text, integer_value integer, decimal_value numeric,
    date_value date, time_value time, timestamp_value timestamp,
    null_value text, unicode_value text
) SERVER mysql OPTIONS (
    schema :'mysql_database', table 'ODBC_FDW_DATA_TYPES', id 'ID',
    text_value 'TEXT_VALUE', integer_value 'INTEGER_VALUE',
    decimal_value 'DECIMAL_VALUE', date_value 'DATE_VALUE', time_value 'TIME_VALUE',
    timestamp_value 'TIMESTAMP_VALUE', null_value 'NULL_VALUE',
    unicode_value 'UNICODE_VALUE'
);
CREATE FOREIGN TABLE probe.type_matrix (
    id integer, tiny_value smallint, unsigned_tiny_value smallint,
    small_value smallint, integer_value integer, bigint_value bigint,
    decimal_value numeric, float_value real, double_value double precision,
    boolean_value boolean, bit_value boolean, char_value text,
    varchar_value text, text_value text, longtext_value text, date_value date,
    time_value time, datetime_value timestamp, timestamp_value timestamp,
    year_value smallint, binary_value bytea, varbinary_value bytea,
    blob_value bytea, longblob_value bytea
) SERVER mysql OPTIONS (
    schema :'mysql_database', table 'ODBC_FDW_TYPE_MATRIX', id 'ID',
    tiny_value 'TINY_VALUE', unsigned_tiny_value 'UNSIGNED_TINY_VALUE',
    small_value 'SMALL_VALUE', integer_value 'INTEGER_VALUE',
    bigint_value 'BIGINT_VALUE', decimal_value 'DECIMAL_VALUE',
    float_value 'FLOAT_VALUE', double_value 'DOUBLE_VALUE',
    boolean_value 'BOOLEAN_VALUE', bit_value 'BIT_VALUE', char_value 'CHAR_VALUE',
    varchar_value 'VARCHAR_VALUE', text_value 'TEXT_VALUE',
    longtext_value 'LONGTEXT_VALUE', date_value 'DATE_VALUE', time_value 'TIME_VALUE',
    datetime_value 'DATETIME_VALUE', timestamp_value 'TIMESTAMP_VALUE',
    year_value 'YEAR_VALUE', binary_value 'BINARY_VALUE',
    varbinary_value 'VARBINARY_VALUE', blob_value 'BLOB_VALUE',
    longblob_value 'LONGBLOB_VALUE'
);
CREATE FOREIGN TABLE probe.large_values (id integer, text_value text, blob_value bytea)
SERVER mysql OPTIONS (
    schema :'mysql_database', table 'ODBC_FDW_LARGE_VALUES', id 'ID',
    text_value 'TEXT_VALUE', blob_value 'BLOB_VALUE'
);
CREATE FOREIGN TABLE probe.large_server_field (id integer, text_value text)
SERVER mysql_server_field OPTIONS (
    schema :'mysql_database', table 'ODBC_FDW_LARGE_VALUES', id 'ID', text_value 'TEXT_VALUE'
);
CREATE FOREIGN TABLE probe.direct_server_row (id integer, text_value text)
SERVER mysql_server_row OPTIONS (
    schema :'mysql_database', table 'ODBC_FDW_DATA_TYPES', id 'ID', text_value 'TEXT_VALUE'
);
CREATE FOREIGN TABLE probe.large_server_result (id integer, text_value text)
SERVER mysql_server_result OPTIONS (
    schema :'mysql_database', table 'ODBC_FDW_LARGE_VALUES', id 'ID', text_value 'TEXT_VALUE'
);
CREATE FOREIGN TABLE probe.rescan_source (id integer, payload text)
SERVER mysql OPTIONS (
    schema :'mysql_database', table 'ODBC_FDW_SINGLE_ROW', max_row_count '1',
    id 'ID', payload 'PAYLOAD'
);
CREATE FOREIGN TABLE probe.json_values (id integer, json_value jsonb)
SERVER mysql OPTIONS (
    schema :'mysql_database', table 'ODBC_FDW_JSON_VALUES', id 'ID', json_value 'JSON_VALUE'
);
CREATE FOREIGN TABLE probe.case_lower (
    upper_value integer, lower_value text, mixed_value text, spaced_value text
) SERVER mysql OPTIONS (
    schema :'mysql_database', table 'odbc_fdw_lower_table',
    upper_value 'UPPER_VALUE', lower_value 'lower_value',
    mixed_value 'MixedValue', spaced_value 'Spaced Value'
);
CREATE FOREIGN TABLE probe.case_mixed (
    upper_value integer, lower_value text, mixed_value text, spaced_value text
) SERVER mysql OPTIONS (
    schema :'mysql_database', table 'OdbcFdwMixedTable',
    upper_value 'UPPER_VALUE', lower_value 'lower_value',
    mixed_value 'MixedValue', spaced_value 'Spaced Value'
);
CREATE FOREIGN TABLE probe.query_types (id integer, text_value text)
SERVER mysql OPTIONS (
    table 'query_types',
    sql_query 'SELECT `ID`, `TEXT_VALUE` FROM `ODBC_FDW_DATA_TYPES` WHERE `ID` = 1',
    id 'ID', text_value 'TEXT_VALUE'
);

CREATE SCHEMA imported;
IMPORT FOREIGN SCHEMA ignored
    LIMIT TO ("ODBC_FDW_DATA_TYPES", "ODBC_FDW_TYPE_MATRIX", "ODBC_FDW_JSON_VALUES")
    FROM SERVER mysql INTO imported OPTIONS (schema '');
CREATE SCHEMA imported_case;
IMPORT FOREIGN SCHEMA ignored
    LIMIT TO ("odbc_fdw_lower_table", "OdbcFdwMixedTable")
    FROM SERVER mysql INTO imported_case OPTIONS (schema '');

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
    (SELECT tiny_value FROM probe.type_matrix WHERE id = 1) = 127 AND
    (SELECT unsigned_tiny_value FROM probe.type_matrix WHERE id = 1) = 255 AND
    (SELECT small_value FROM probe.type_matrix WHERE id = 1) = -32768 AND
    (SELECT integer_value FROM probe.type_matrix WHERE id = 1) = 2147483647 AND
    (SELECT bigint_value FROM probe.type_matrix WHERE id = 1) = 922337203685477580 AND
    (SELECT decimal_value FROM probe.type_matrix WHERE id = 1) = 12345678901234.5678 AND
    (SELECT float_value FROM probe.type_matrix WHERE id = 1) = 3.25::real AND
    (SELECT double_value FROM probe.type_matrix WHERE id = 1) = 1234567.125 AND
    (SELECT boolean_value AND bit_value FROM probe.type_matrix WHERE id = 1) AND
    (SELECT rtrim(char_value) FROM probe.type_matrix WHERE id = 1) = 'abc' AND
    (SELECT varchar_value FROM probe.type_matrix WHERE id = 1) = 'Grüße 東京' AND
    (SELECT longtext_value FROM probe.type_matrix WHERE id = 1) = 'long unicode Привет 東京' AND
    (SELECT year_value FROM probe.type_matrix WHERE id = 1) = 2024 AND
    (SELECT encode(binary_value, 'hex') FROM probe.type_matrix WHERE id = 1) = 'abcd0000' AND
    (SELECT encode(varbinary_value, 'hex') FROM probe.type_matrix WHERE id = 1) = '1020' AND
    (SELECT encode(longblob_value, 'hex') FROM probe.type_matrix WHERE id = 1) = '004142ff'
    THEN 'ok' ELSE 'bad' END;
SELECT 'type_matrix_nulls=' || CASE WHEN
    (SELECT tiny_value IS NULL AND unsigned_tiny_value IS NULL AND small_value IS NULL
            AND integer_value IS NULL AND bigint_value IS NULL AND decimal_value IS NULL
            AND float_value IS NULL AND double_value IS NULL AND boolean_value IS NULL
            AND bit_value IS NULL AND char_value IS NULL AND varchar_value IS NULL
            AND text_value IS NULL AND longtext_value IS NULL AND date_value IS NULL
            AND time_value IS NULL AND datetime_value IS NULL AND timestamp_value IS NULL
            AND year_value IS NULL AND binary_value IS NULL AND varbinary_value IS NULL
            AND blob_value IS NULL AND longblob_value IS NULL
     FROM probe.type_matrix WHERE id = 2)
    THEN 'ok' ELSE 'bad' END;
SELECT 'import_type_matrix=' || CASE WHEN
    (SELECT "BIGINT_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 922337203685477580 AND
    (SELECT "VARCHAR_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 'Grüße 東京' AND
    (SELECT encode("BLOB_VALUE", 'hex') FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = '00ff1020'
    THEN 'ok' ELSE 'bad' END;
SELECT 'json=' || CASE WHEN
    (SELECT json_value ->> 'owner' FROM probe.json_values WHERE id = 1) = 'София' AND
    (SELECT json_value #>> '{tags,2}' FROM probe.json_values WHERE id = 1) = '😀' AND
    (SELECT json_value IS NULL FROM probe.json_values WHERE id = 2)
    THEN 'ok' ELSE 'bad' END;
SELECT 'case_names=' || CASE WHEN
    (SELECT upper_value FROM probe.case_lower) = 1 AND
    (SELECT mixed_value FROM probe.case_lower) = 'mixed column' AND
    (SELECT spaced_value FROM probe.case_mixed) = 'space mixed table' AND
    (SELECT "MixedValue" FROM imported_case."odbc_fdw_lower_table") = 'mixed column'
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
