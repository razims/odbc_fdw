-- Values come from the environment, not psql argv, so the PDB credential never
-- appears in /proc/<pid>/cmdline.
\getenv oracle_dbq ORACLE_DBQ
\getenv oracle_user ORACLE_USER
\getenv oracle_password ORACLE_PASSWORD
\getenv oracle_schema ORACLE_SCHEMA

CREATE EXTENSION odbc_fdw;
CREATE SCHEMA probe;

CREATE SERVER oracle FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'Oracle 21 ODBC driver',
    odbc_dbq :'oracle_dbq',
    wide_char_mode 'wchar'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER oracle OPTIONS (
    odbc_uid :'oracle_user',
    odbc_pwd :'oracle_password'
);

CREATE SERVER oracle_server_field FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'Oracle 21 ODBC driver', odbc_dbq :'oracle_dbq',
    wide_char_mode 'wchar',
    max_field_size '100'
);
CREATE SERVER oracle_server_row FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'Oracle 21 ODBC driver', odbc_dbq :'oracle_dbq',
    wide_char_mode 'wchar',
    max_row_count '1'
);
CREATE SERVER oracle_server_result FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'Oracle 21 ODBC driver', odbc_dbq :'oracle_dbq',
    wide_char_mode 'wchar',
    max_result_size '1000'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER oracle_server_field OPTIONS (
    odbc_uid :'oracle_user', odbc_pwd :'oracle_password');
CREATE USER MAPPING FOR CURRENT_USER SERVER oracle_server_row OPTIONS (
    odbc_uid :'oracle_user', odbc_pwd :'oracle_password');
CREATE USER MAPPING FOR CURRENT_USER SERVER oracle_server_result OPTIONS (
    odbc_uid :'oracle_user', odbc_pwd :'oracle_password');

CREATE FOREIGN TABLE probe.direct_types (
    id integer,
    text_value text,
    integer_value integer,
    decimal_value numeric,
    date_value timestamp,
    timestamp_value timestamp,
    null_value text,
    unicode_value text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_DATA_TYPES',
    id 'ID', text_value 'TEXT_VALUE', integer_value 'INTEGER_VALUE',
    decimal_value 'DECIMAL_VALUE', date_value 'DATE_VALUE',
    timestamp_value 'TIMESTAMP_VALUE', null_value 'NULL_VALUE',
    unicode_value 'UNICODE_VALUE');

CREATE FOREIGN TABLE probe.direct_large (
    id integer,
    clob_value text,
    nclob_value text,
    blob_value bytea
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_LARGE_VALUES',
    id 'ID', clob_value 'CLOB_VALUE', nclob_value 'NCLOB_VALUE',
    blob_value 'BLOB_VALUE');

CREATE FOREIGN TABLE probe.rescan_source (
    id integer,
    payload text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_SINGLE_ROW', max_row_count '1',
    id 'ID', payload 'PAYLOAD');

CREATE FOREIGN TABLE probe.type_matrix (
    id integer,
    small_value smallint,
    integer_value integer,
    bigint_value bigint,
    decimal_value numeric,
    binary_float_value real,
    binary_double_value double precision,
    char_value text,
    nchar_value text,
    varchar_value text,
    nvarchar_value text,
    date_value timestamp,
    timestamp_value timestamp,
    clob_value text,
    nclob_value text,
    blob_value bytea,
    raw_value bytea
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_TYPE_MATRIX',
    id 'ID', small_value 'SMALL_VALUE', integer_value 'INTEGER_VALUE',
    bigint_value 'BIGINT_VALUE', decimal_value 'DECIMAL_VALUE',
    binary_float_value 'BINARY_FLOAT_VALUE', binary_double_value 'BINARY_DOUBLE_VALUE',
    char_value 'CHAR_VALUE', nchar_value 'NCHAR_VALUE', varchar_value 'VARCHAR_VALUE',
    nvarchar_value 'NVARCHAR_VALUE', date_value 'DATE_VALUE',
    timestamp_value 'TIMESTAMP_VALUE', clob_value 'CLOB_VALUE',
    nclob_value 'NCLOB_VALUE', blob_value 'BLOB_VALUE', raw_value 'RAW_VALUE');

CREATE FOREIGN TABLE probe.encoding_matrix (
    id integer,
    ascii_value text,
    cyrillic_value text,
    utf8_value text,
    combining_value text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_ENCODING_MATRIX',
    id 'ID', ascii_value 'ASCII_VALUE', cyrillic_value 'CYRILLIC_VALUE',
    utf8_value 'UTF8_VALUE', combining_value 'COMBINING_VALUE');

CREATE FOREIGN TABLE probe.json_values (
    id integer,
    json_value json,
    json_nclob_value jsonb
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'ODBC_FDW_JSON_VALUES',
    id 'ID', json_value 'JSON_VALUE', json_nclob_value 'JSON_NCLOB_VALUE');

CREATE FOREIGN TABLE probe.case_lower (
    upper_value integer,
    lower_value text,
    mixed_value text,
    spaced_value text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'odbc_fdw_lower_table',
    upper_value 'UPPER_VALUE', lower_value 'lower_value', mixed_value 'MixedValue',
    spaced_value 'Spaced Value');

CREATE FOREIGN TABLE probe.case_mixed (
    upper_value integer,
    lower_value text,
    mixed_value text,
    spaced_value text
) SERVER oracle OPTIONS (
    schema :'oracle_schema', table 'OdbcFdwMixedTable',
    upper_value 'UPPER_VALUE', lower_value 'lower_value', mixed_value 'MixedValue',
    spaced_value 'Spaced Value');

SELECT format(
    'SELECT "ID", "TEXT_VALUE" FROM %I.%I WHERE "ID" = 1',
    :'oracle_schema', 'ODBC_FDW_DATA_TYPES'
) AS oracle_sql_query \gset
CREATE FOREIGN TABLE probe.query_types (
    id integer,
    text_value text
) SERVER oracle OPTIONS (
    sql_query :'oracle_sql_query', id 'ID', text_value 'TEXT_VALUE');

CREATE SCHEMA imported;
IMPORT FOREIGN SCHEMA :"oracle_schema"
    LIMIT TO ("ODBC_FDW_DATA_TYPES", "ODBC_FDW_TYPE_MATRIX",
              "ODBC_FDW_ENCODING_MATRIX", "ODBC_FDW_JSON_VALUES")
    FROM SERVER oracle INTO imported;

CREATE SCHEMA imported_case;
IMPORT FOREIGN SCHEMA :"oracle_schema"
    LIMIT TO ("odbc_fdw_lower_table", "OdbcFdwMixedTable")
    FROM SERVER oracle INTO imported_case;

SELECT 'direct_scalar=' || CASE WHEN
    (SELECT count(*) FROM probe.direct_types) = 2 AND
    (SELECT text_value FROM probe.direct_types WHERE id = 1) = 'alpha' AND
    (SELECT integer_value FROM probe.direct_types WHERE id = 1) = 42 AND
    (SELECT decimal_value FROM probe.direct_types WHERE id = 1) = 123.4500 AND
    (SELECT date_value FROM probe.direct_types WHERE id = 1) = TIMESTAMP '2024-01-02 00:00:00'
    THEN 'ok' ELSE 'bad' END;

SELECT 'direct_timestamp=' || CASE WHEN
    (SELECT timestamp_value FROM probe.direct_types WHERE id = 1) = TIMESTAMP '2024-01-02 03:04:05' AND
    (SELECT timestamp_value FROM probe.direct_types WHERE id = 2) = TIMESTAMP '2024-12-31 23:59:59'
    THEN 'ok' ELSE 'bad' END;

SELECT 'direct_unicode_null=' || CASE WHEN
    (SELECT null_value IS NULL FROM probe.direct_types WHERE id = 1) AND
    (SELECT unicode_value FROM probe.direct_types WHERE id = 2) = '東京'
    THEN 'ok' ELSE 'bad' END;

SELECT 'import_types=' || CASE WHEN
    (SELECT count(*) FROM imported."ODBC_FDW_DATA_TYPES") = 2 AND
    (SELECT "TEXT_VALUE" FROM imported."ODBC_FDW_DATA_TYPES" WHERE "ID" = 2) = 'beta'
    THEN 'ok' ELSE 'bad' END;

SELECT 'type_matrix=' || CASE WHEN
    (SELECT small_value FROM probe.type_matrix WHERE id = 1) = -32768 AND
    (SELECT integer_value FROM probe.type_matrix WHERE id = 1) = 2147483647 AND
    (SELECT bigint_value FROM probe.type_matrix WHERE id = 1) = 922337203685477580 AND
    (SELECT decimal_value FROM probe.type_matrix WHERE id = 1) = 12345678901234.5678 AND
    (SELECT binary_float_value FROM probe.type_matrix WHERE id = 1) = 3.25::real AND
    (SELECT binary_double_value FROM probe.type_matrix WHERE id = 1) = 1234567.125 AND
    (SELECT rtrim(char_value) FROM probe.type_matrix WHERE id = 1) = 'abc' AND
    (SELECT rtrim(nchar_value) FROM probe.type_matrix WHERE id = 1) = '東京' AND
    (SELECT varchar_value FROM probe.type_matrix WHERE id = 1) = 'plain varchar' AND
    (SELECT nvarchar_value FROM probe.type_matrix WHERE id = 1) = 'Grüße 東京' AND
    (SELECT date_value FROM probe.type_matrix WHERE id = 1) = TIMESTAMP '2024-06-30 00:00:00' AND
    (SELECT timestamp_value FROM probe.type_matrix WHERE id = 1) = TIMESTAMP '2024-06-30 12:34:56' AND
    (SELECT clob_value FROM probe.type_matrix WHERE id = 1) = 'plain clob' AND
    (SELECT nclob_value FROM probe.type_matrix WHERE id = 1) = 'unicode 東京' AND
    (SELECT encode(blob_value, 'hex') FROM probe.type_matrix WHERE id = 1) = '00ff1020' AND
    (SELECT encode(raw_value, 'hex') FROM probe.type_matrix WHERE id = 1) = 'abcd1020'
    THEN 'ok' ELSE 'bad' END;

SELECT 'type_matrix_nulls=' || CASE WHEN
    (SELECT small_value IS NULL AND integer_value IS NULL AND bigint_value IS NULL
            AND decimal_value IS NULL AND binary_float_value IS NULL
            AND binary_double_value IS NULL AND char_value IS NULL AND nchar_value IS NULL
            AND varchar_value IS NULL AND nvarchar_value IS NULL AND date_value IS NULL
            AND timestamp_value IS NULL AND clob_value IS NULL AND nclob_value IS NULL
            AND blob_value IS NULL AND raw_value IS NULL
     FROM probe.type_matrix WHERE id = 2)
    THEN 'ok' ELSE 'bad' END;

SELECT 'import_type_matrix=' || CASE WHEN
    (SELECT "BIGINT_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 922337203685477580 AND
    (SELECT "NVARCHAR_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 'Grüße 東京' AND
    (SELECT encode("BLOB_VALUE", 'hex') FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = '00ff1020' AND
    (SELECT encode("RAW_VALUE", 'hex') FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 'abcd1020'
    THEN 'ok' ELSE 'bad' END;

SELECT 'ascii_text=' || CASE WHEN
    (SELECT ascii_value FROM probe.encoding_matrix WHERE id = 1) = 'The quick brown fox 123 !@#$' AND
    (SELECT "ASCII_VALUE" FROM imported."ODBC_FDW_ENCODING_MATRIX" WHERE "ID" = 1) = 'The quick brown fox 123 !@#$'
    THEN 'ok' ELSE 'bad' END;

SELECT 'cyrillic_text=' || CASE WHEN
    (SELECT cyrillic_value FROM probe.encoding_matrix WHERE id = 1) = 'Привет, мир — Ёжик' AND
    (SELECT "CYRILLIC_VALUE" FROM imported."ODBC_FDW_ENCODING_MATRIX" WHERE "ID" = 1) = 'Привет, мир — Ёжик'
    THEN 'ok' ELSE 'bad' END;

SELECT 'utf8_text=' || CASE WHEN
    (SELECT utf8_value FROM probe.encoding_matrix WHERE id = 1) = 'Grüße 東京 😀' AND
    (SELECT combining_value FROM probe.encoding_matrix WHERE id = 1) = convert_from(decode('65cc81', 'hex'), 'UTF8') AND
    (SELECT octet_length(combining_value) FROM probe.encoding_matrix WHERE id = 1) = 3 AND
    (SELECT "UTF8_VALUE" FROM imported."ODBC_FDW_ENCODING_MATRIX" WHERE "ID" = 1) = 'Grüße 東京 😀'
    THEN 'ok' ELSE 'bad' END;

SELECT 'json_direct=' || CASE WHEN
    (SELECT json_value::jsonb ->> 'owner' FROM probe.json_values WHERE id = 1) = 'София' AND
    (SELECT json_value::jsonb #>> '{tags,2}' FROM probe.json_values WHERE id = 1) = '😀' AND
    (SELECT json_nclob_value #>> '{document,title}' FROM probe.json_values WHERE id = 1) = 'Привет' AND
    (SELECT jsonb_array_length(json_nclob_value -> 'items') FROM probe.json_values WHERE id = 1) = 2
    THEN 'ok' ELSE 'bad' END;

SELECT 'json_import=' || CASE WHEN
    (SELECT "JSON_VALUE"::jsonb ->> 'owner' FROM imported."ODBC_FDW_JSON_VALUES" WHERE "ID" = 1) = 'София' AND
    (SELECT "JSON_NCLOB_VALUE"::jsonb #>> '{document,locale}' FROM imported."ODBC_FDW_JSON_VALUES" WHERE "ID" = 1) = 'ru_RU'
    THEN 'ok' ELSE 'bad' END;

SELECT 'json_nulls=' || CASE WHEN
    (SELECT json_value IS NULL AND json_nclob_value IS NULL FROM probe.json_values WHERE id = 2)
    THEN 'ok' ELSE 'bad' END;

SELECT 'direct_case_names=' || CASE WHEN
    (SELECT upper_value FROM probe.case_lower) = 1 AND
    (SELECT lower_value FROM probe.case_lower) = 'lower column' AND
    (SELECT mixed_value FROM probe.case_lower) = 'mixed column' AND
    (SELECT spaced_value FROM probe.case_lower) = 'space column' AND
    (SELECT upper_value FROM probe.case_mixed) = 2 AND
    (SELECT lower_value FROM probe.case_mixed) = 'lower mixed table' AND
    (SELECT mixed_value FROM probe.case_mixed) = 'mixed mixed table' AND
    (SELECT spaced_value FROM probe.case_mixed) = 'space mixed table'
    THEN 'ok' ELSE 'bad' END;

SELECT 'import_case_names=' || CASE WHEN
    (SELECT "UPPER_VALUE" FROM imported_case."odbc_fdw_lower_table") = 1 AND
    (SELECT "lower_value" FROM imported_case."odbc_fdw_lower_table") = 'lower column' AND
    (SELECT "MixedValue" FROM imported_case."odbc_fdw_lower_table") = 'mixed column' AND
    (SELECT "Spaced Value" FROM imported_case."odbc_fdw_lower_table") = 'space column' AND
    (SELECT "UPPER_VALUE" FROM imported_case."OdbcFdwMixedTable") = 2 AND
    (SELECT "lower_value" FROM imported_case."OdbcFdwMixedTable") = 'lower mixed table'
    THEN 'ok' ELSE 'bad' END;

SELECT 'sql_query=' || CASE WHEN
    (SELECT count(*) FROM probe.query_types) = 1 AND
    (SELECT text_value FROM probe.query_types WHERE id = 1) = 'alpha'
    THEN 'ok' ELSE 'bad' END;

SELECT 'parameter_in_out=' || CASE WHEN
    (SELECT string_agg(remote.text_value, ',' ORDER BY input.id)
     FROM (VALUES (1, 'alpha'::text), (2, 'beta'::text)) AS input(id, expected)
     CROSS JOIN LATERAL
        (SELECT text_value FROM probe.direct_types WHERE id = input.id) AS remote
     WHERE remote.text_value = input.expected) = 'alpha,beta'
    THEN 'ok' ELSE 'bad' END;

SELECT 'large_value=' || CASE WHEN
    (SELECT length(clob_value) FROM probe.direct_large WHERE id = 1) = 6000 AND
    (SELECT md5(clob_value) FROM probe.direct_large WHERE id = 1) = md5(repeat('x', 6000)) AND
    (SELECT nclob_value FROM probe.direct_large WHERE id = 1) = 'unicode 東京' AND
    (SELECT encode(blob_value, 'hex') FROM probe.direct_large WHERE id = 1) = '004142ff'
    THEN 'ok' ELSE 'bad' END;

SET enable_material = off;
SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT 'rescan=' || CASE WHEN
    (SELECT count(*) FROM (VALUES (1), (1)) AS outer_row(id)
     CROSS JOIN LATERAL
        (SELECT payload FROM probe.rescan_source WHERE id = outer_row.id) AS inner_row) = 2
    THEN 'ok' ELSE 'bad' END;
