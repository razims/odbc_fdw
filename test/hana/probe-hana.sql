-- Read every value from the ENVIRONMENT, not from psql's argv. `-v name=value`
-- would put the tenant's password in /proc/<pid>/cmdline, which is world
-- readable; \getenv (psql 15+) reads /proc/<pid>/environ, which is not.
\getenv hana_servernode HANA_SERVERNODE
\getenv hana_database HANA_DATABASE
\getenv hana_user HANA_USER
\getenv hana_password HANA_PASSWORD
\getenv hana_encrypt HANA_ENCRYPT
\getenv hana_schema HANA_SCHEMA
\getenv hana_test_application HANA_TEST_APPLICATION

CREATE EXTENSION odbc_fdw;
CREATE SCHEMA probe;

CREATE SERVER hana FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'HDBODBC',
    odbc_servernode :'hana_servernode',
    odbc_databasename :'hana_database',
    odbc_encrypt :'hana_encrypt',
    odbc_sslvalidatecertificate 'false',
    "odbc_sessionVariable:APPLICATION" :'hana_test_application'
);

CREATE USER MAPPING FOR CURRENT_USER SERVER hana OPTIONS (
    odbc_uid :'hana_user',
    odbc_pwd :'hana_password'
);

CREATE SERVER hana_server_field FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'HDBODBC',
    odbc_servernode :'hana_servernode',
    odbc_databasename :'hana_database',
    odbc_encrypt :'hana_encrypt',
    odbc_sslvalidatecertificate 'false',
    max_field_size '100'
);

CREATE SERVER hana_server_row FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'HDBODBC',
    odbc_servernode :'hana_servernode',
    odbc_databasename :'hana_database',
    odbc_encrypt :'hana_encrypt',
    odbc_sslvalidatecertificate 'false',
    max_row_count '1'
);

CREATE SERVER hana_server_result FOREIGN DATA WRAPPER odbc_fdw OPTIONS (
    odbc_driver 'HDBODBC',
    odbc_servernode :'hana_servernode',
    odbc_databasename :'hana_database',
    odbc_encrypt :'hana_encrypt',
    odbc_sslvalidatecertificate 'false',
    max_result_size '1000'
);

CREATE USER MAPPING FOR CURRENT_USER SERVER hana_server_field OPTIONS (
    odbc_uid :'hana_user',
    odbc_pwd :'hana_password'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER hana_server_row OPTIONS (
    odbc_uid :'hana_user',
    odbc_pwd :'hana_password'
);
CREATE USER MAPPING FOR CURRENT_USER SERVER hana_server_result OPTIONS (
    odbc_uid :'hana_user',
    odbc_pwd :'hana_password'
);

CREATE FOREIGN TABLE probe.direct_types (
    id integer,
    text_value text,
    integer_value integer,
    decimal_value numeric,
    date_value date,
    time_value time,
    timestamp_value timestamp,
    null_value text,
    unicode_value text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_DATA_TYPES',
    id 'ID', text_value 'TEXT_VALUE', integer_value 'INTEGER_VALUE',
    decimal_value 'DECIMAL_VALUE', date_value 'DATE_VALUE', time_value 'TIME_VALUE',
    timestamp_value 'TIMESTAMP_VALUE', null_value 'NULL_VALUE', unicode_value 'UNICODE_VALUE');

CREATE FOREIGN TABLE probe.direct_large (
    id integer,
    nclob_value text,
    blob_value bytea
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_LARGE_VALUES',
    id 'ID', nclob_value 'NCLOB_VALUE', blob_value 'BLOB_VALUE');

CREATE FOREIGN TABLE probe.rescan_source (
    id integer,
    payload text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_SINGLE_ROW', max_row_count '1',
    id 'ID', payload 'PAYLOAD');

CREATE FOREIGN TABLE probe.type_matrix (
    id integer,
    tiny_value smallint,
    small_value smallint,
    integer_value integer,
    bigint_value bigint,
    decimal_value numeric,
    real_value real,
    double_value double precision,
    boolean_value boolean,
    char_value text,
    nchar_value text,
    varchar_value text,
    nvarchar_value text,
    date_value date,
    time_value time,
    timestamp_value timestamp,
    seconddate_value timestamp,
    clob_value text,
    nclob_value text,
    blob_value bytea
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_TYPE_MATRIX',
    id 'ID', tiny_value 'TINY_VALUE', small_value 'SMALL_VALUE',
    integer_value 'INTEGER_VALUE', bigint_value 'BIGINT_VALUE',
    decimal_value 'DECIMAL_VALUE', real_value 'REAL_VALUE', double_value 'DOUBLE_VALUE',
    boolean_value 'BOOLEAN_VALUE', char_value 'CHAR_VALUE', nchar_value 'NCHAR_VALUE',
    varchar_value 'VARCHAR_VALUE', nvarchar_value 'NVARCHAR_VALUE', date_value 'DATE_VALUE',
    time_value 'TIME_VALUE', timestamp_value 'TIMESTAMP_VALUE',
    seconddate_value 'SECONDDATE_VALUE', clob_value 'CLOB_VALUE', nclob_value 'NCLOB_VALUE',
    blob_value 'BLOB_VALUE');

CREATE FOREIGN TABLE probe.encoding_matrix (
    id integer,
    ascii_value text,
    cyrillic_value text,
    utf8_value text,
    combining_value text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_ENCODING_MATRIX',
    id 'ID', ascii_value 'ASCII_VALUE', cyrillic_value 'CYRILLIC_VALUE',
    utf8_value 'UTF8_VALUE', combining_value 'COMBINING_VALUE');

CREATE FOREIGN TABLE probe.json_values (
    id integer,
    json_value json,
    json_nclob_value jsonb
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_JSON_VALUES',
    id 'ID', json_value 'JSON_VALUE', json_nclob_value 'JSON_NCLOB_VALUE');

CREATE FOREIGN TABLE probe.case_lower (
    upper_value integer,
    lower_value text,
    mixed_value text,
    spaced_value text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'odbc_fdw_lower_table',
    upper_value 'UPPER_VALUE', lower_value 'lower_value', mixed_value 'MixedValue',
    spaced_value 'Spaced Value');

CREATE FOREIGN TABLE probe.case_mixed (
    upper_value integer,
    lower_value text,
    mixed_value text,
    spaced_value text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'OdbcFdwMixedTable',
    upper_value 'UPPER_VALUE', lower_value 'lower_value', mixed_value 'MixedValue',
    spaced_value 'Spaced Value');

SELECT format(
    'SELECT "ID", "TEXT_VALUE" FROM %I.%I WHERE "ID" = 1',
    :'hana_schema', 'ODBC_FDW_DATA_TYPES'
) AS hana_sql_query \gset

CREATE FOREIGN TABLE probe.query_types (
    id integer,
    text_value text
) SERVER hana OPTIONS (
    sql_query :'hana_sql_query', id 'ID', text_value 'TEXT_VALUE');

CREATE SCHEMA imported;
IMPORT FOREIGN SCHEMA :"hana_schema" LIMIT TO ("ODBC_FDW_DATA_TYPES", "ODBC_FDW_TYPE_MATRIX", "ODBC_FDW_ENCODING_MATRIX", "ODBC_FDW_JSON_VALUES")
    FROM SERVER hana INTO imported;

CREATE FOREIGN TABLE probe.float_matrix (
    id integer, dbl double precision, rl real
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_FLOAT_MATRIX',
    id 'ID', dbl 'DBL', rl 'RL'
);
CREATE FOREIGN TABLE probe.float_matrix_text (
    id integer, dbl text, rl text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_FLOAT_MATRIX',
    id 'ID', dbl 'DBL', rl 'RL'
);
CREATE FOREIGN TABLE probe.wide_decimal (
    id integer, d38_2 numeric(38,2), d38_0 numeric(38,0), d18_4 numeric(18,4)
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_WIDE_DECIMAL',
    id 'ID', d38_2 'D38_2', d38_0 'D38_0', d18_4 'D18_4'
);
CREATE FOREIGN TABLE probe.wide_decimal_text (
    id integer, d38_2 text, d38_0 text, d18_4 text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_WIDE_DECIMAL',
    id 'ID', d38_2 'D38_2', d38_0 'D38_0', d18_4 'D18_4'
);
CREATE FOREIGN TABLE probe.money_text (
    id integer, label text,
    d1_0 text,
    d9_2 text,
    d15_2 text,
    d18_4 text,
    d19_4 text,
    d28_6 text,
    d30_0 text,
    d31_0 text,
    d32_0 text,
    d34_2 text,
    d38_0 text,
    d38_2 text
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_MONEY_MATRIX', id 'ID', label 'LABEL',
    d1_0 'D1_0',
    d9_2 'D9_2',
    d15_2 'D15_2',
    d18_4 'D18_4',
    d19_4 'D19_4',
    d28_6 'D28_6',
    d30_0 'D30_0',
    d31_0 'D31_0',
    d32_0 'D32_0',
    d34_2 'D34_2',
    d38_0 'D38_0',
    d38_2 'D38_2'
);
CREATE FOREIGN TABLE probe.money_numeric (
    id integer, label text,
    d1_0 numeric(1,0),
    d9_2 numeric(9,2),
    d15_2 numeric(15,2),
    d18_4 numeric(18,4),
    d19_4 numeric(19,4),
    d28_6 numeric(28,6),
    d30_0 numeric(30,0),
    d31_0 numeric(31,0),
    d32_0 numeric(32,0),
    d34_2 numeric(34,2),
    d38_0 numeric(38,0),
    d38_2 numeric(38,2)
) SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_MONEY_MATRIX', id 'ID', label 'LABEL',
    d1_0 'D1_0',
    d9_2 'D9_2',
    d15_2 'D15_2',
    d18_4 'D18_4',
    d19_4 'D19_4',
    d28_6 'D28_6',
    d30_0 'D30_0',
    d31_0 'D31_0',
    d32_0 'D32_0',
    d34_2 'D34_2',
    d38_0 'D38_0',
    d38_2 'D38_2'
);
CREATE FOREIGN TABLE probe.charset_matrix (id integer, script_name text, value text)
SERVER hana OPTIONS (
    schema :'hana_schema', table 'ODBC_FDW_CHARSET_MATRIX', id 'ID',
    script_name 'SCRIPT_NAME', value 'VALUE'
);
CREATE FOREIGN TABLE probe.nclob_sizes (id integer, chars integer, v text, c text)
SERVER hana OPTIONS (schema :'hana_schema', table 'ODBC_FDW_NCLOB_SIZES',
    wide_char_mode 'wchar', id 'ID', chars 'CHARS', v 'V', c 'C');
-- Truth computed BY HANA and transferred as ASCII hex, so the comparison cannot
-- be corrupted by the same path it is checking.
SELECT format(
    'SELECT "ID", LENGTH("V") AS "HANA_CHARS", LENGTH(TO_BINARY("V")) AS "HANA_BYTES", '
    'LOWER(BINTOHEX(HASH_MD5(TO_BINARY("V")))) AS "HANA_MD5" FROM %I."ODBC_FDW_NCLOB_SIZES"',
    :'hana_schema') AS nclob_truth_query \gset
CREATE FOREIGN TABLE probe.nclob_truth (id integer, hana_chars integer, hana_bytes integer, hana_md5 text)
SERVER hana OPTIONS (table 'nclob_truth', sql_query :'nclob_truth_query',
  id 'ID', hana_chars 'HANA_CHARS', hana_bytes 'HANA_BYTES', hana_md5 'HANA_MD5');

CREATE SCHEMA imported_scale;
IMPORT FOREIGN SCHEMA :"hana_schema" LIMIT TO ("ODBC_FDW_SCALE_MATRIX")
    FROM SERVER hana INTO imported_scale;

CREATE SCHEMA imported_case;
IMPORT FOREIGN SCHEMA :"hana_schema" LIMIT TO ("odbc_fdw_lower_table", "OdbcFdwMixedTable")
    FROM SERVER hana INTO imported_case;

SELECT 'direct_scalar=' || CASE WHEN
    (SELECT count(*) FROM probe.direct_types) = 2 AND
    (SELECT text_value FROM probe.direct_types WHERE id = 1) = 'alpha' AND
    (SELECT integer_value FROM probe.direct_types WHERE id = 1) = 42 AND
    (SELECT decimal_value FROM probe.direct_types WHERE id = 1) = 123.4500 AND
    (SELECT date_value FROM probe.direct_types WHERE id = 1) = DATE '2024-01-02'
    THEN 'ok' ELSE 'bad' END;

SELECT 'direct_time=' || CASE WHEN
    (SELECT time_value FROM probe.direct_types WHERE id = 1) = TIME '03:04:05'
    THEN 'ok' ELSE 'bad' END;

SELECT 'direct_timestamp=' || CASE WHEN
    (SELECT timestamp_value FROM probe.direct_types WHERE id = 1) = TIMESTAMP '2024-01-02 03:04:05' AND
    (SELECT timestamp_value FROM probe.direct_types WHERE id = 2) = TIMESTAMP '2024-12-31 23:59:59'
    THEN 'ok' ELSE 'bad' END;

-- Drivers disagree on one cosmetic point: some render a value below 1 without
-- its leading zero. Normalised on BOTH sides rather than baking one driver's
-- spelling in; it cannot hide truncation, which removes characters from the
-- RIGHT and never the optional zero before the point.
CREATE FUNCTION norm_decimal(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT regexp_replace(t, '^(-?)0\.', '\1.') $$;

SELECT 'money_text=' || CASE WHEN (
    SELECT count(*) FROM (
        SELECT m.id, c.col, c.got FROM probe.money_text m
        CROSS JOIN LATERAL (VALUES
                    ('d1_0', m.d1_0),
                    ('d9_2', m.d9_2),
                    ('d15_2', m.d15_2),
                    ('d18_4', m.d18_4),
                    ('d19_4', m.d19_4),
                    ('d28_6', m.d28_6),
                    ('d30_0', m.d30_0),
                    ('d31_0', m.d31_0),
                    ('d32_0', m.d32_0),
                    ('d34_2', m.d34_2),
                    ('d38_0', m.d38_0),
                    ('d38_2', m.d38_2)
        ) AS c(col, got)
    ) g
    JOIN (VALUES
            (1,'d1_0','9'),
            (1,'d9_2','9999999.99'),
            (1,'d15_2','9999999999999.99'),
            (1,'d18_4','99999999999999.9999'),
            (1,'d19_4','999999999999999.9999'),
            (1,'d28_6','9999999999999999999999.999999'),
            (1,'d30_0','999999999999999999999999999999'),
            (1,'d31_0','9999999999999999999999999999999'),
            (1,'d32_0','99999999999999999999999999999999'),
            (1,'d34_2','99999999999999999999999999999999.99'),
            (1,'d38_0','99999999999999999999999999999999999999'),
            (1,'d38_2','999999999999999999999999999999999999.99'),
            (2,'d1_0','-9'),
            (2,'d9_2','-9999999.99'),
            (2,'d15_2','-9999999999999.99'),
            (2,'d18_4','-99999999999999.9999'),
            (2,'d19_4','-999999999999999.9999'),
            (2,'d28_6','-9999999999999999999999.999999'),
            (2,'d30_0','-999999999999999999999999999999'),
            (2,'d31_0','-9999999999999999999999999999999'),
            (2,'d32_0','-99999999999999999999999999999999'),
            (2,'d34_2','-99999999999999999999999999999999.99'),
            (2,'d38_0','-99999999999999999999999999999999999999'),
            (2,'d38_2','-999999999999999999999999999999999999.99'),
            (3,'d1_0','1'),
            (3,'d9_2','0.01'),
            (3,'d15_2','0.01'),
            (3,'d18_4','0.0001'),
            (3,'d19_4','0.0001'),
            (3,'d28_6','0.000001'),
            (3,'d30_0','1'),
            (3,'d31_0','1'),
            (3,'d32_0','1'),
            (3,'d34_2','0.01'),
            (3,'d38_0','1'),
            (3,'d38_2','0.01'),
            (4,'d1_0','0'),
            (4,'d9_2','0.00'),
            (4,'d15_2','0.00'),
            (4,'d18_4','0.0000'),
            (4,'d19_4','0.0000'),
            (4,'d28_6','0.000000'),
            (4,'d30_0','0'),
            (4,'d31_0','0'),
            (4,'d32_0','0'),
            (4,'d34_2','0.00'),
            (4,'d38_0','0'),
            (4,'d38_2','0.00'),
            (5,'d1_0','1'),
            (5,'d9_2','1234.56'),
            (5,'d15_2','1234.56'),
            (5,'d18_4','1234.5678'),
            (5,'d19_4','1234.5678'),
            (5,'d28_6','1234.567890'),
            (5,'d30_0','1234'),
            (5,'d31_0','1234'),
            (5,'d32_0','1234'),
            (5,'d34_2','1234.56'),
            (5,'d38_0','1234'),
            (5,'d38_2','1234.56')
        ) AS e(id, col, want) ON e.id = g.id AND e.col = g.col
    WHERE norm_decimal(g.got) IS DISTINCT FROM norm_decimal(e.want)) = 0
    AND (SELECT count(*) FROM probe.money_text) = 6
    THEN 'ok' ELSE 'bad' END;

SELECT 'money_numeric=' || CASE WHEN
    (SELECT d38_2 FROM probe.money_numeric WHERE label = 'max_negative') = numeric '-999999999999999999999999999999999999.99' AND
    (SELECT d32_0 FROM probe.money_numeric WHERE label = 'max_negative') = numeric '-99999999999999999999999999999999' AND
    (SELECT d38_2 FROM probe.money_numeric WHERE label = 'smallest_unit') = numeric '0.01' AND
    (SELECT sum(d38_2) FROM probe.money_numeric) = numeric '1234.57' AND
    (SELECT d38_2 IS NULL AND d1_0 IS NULL AND d30_0 IS NULL
     FROM probe.money_numeric WHERE label = 'nulls')
    THEN 'ok' ELSE 'bad' END;

SELECT 'charset_matrix=' || CASE WHEN (
    SELECT count(*) FROM probe.charset_matrix c
    JOIN (VALUES
            (1,chr(65)||chr(66)||chr(67)||chr(49)||chr(50)||chr(33)),
            (2,chr(99)||chr(97)||chr(102)||chr(233)||chr(32)||chr(220)||chr(223)||chr(241)),
            (3,chr(268)||chr(345)||chr(337)||chr(382)||chr(322)||chr(7865)),
            (4,chr(917)||chr(955)||chr(955)||chr(940)||chr(948)||chr(945)),
            (5,chr(1055)||chr(1088)||chr(1080)||chr(1074)||chr(1077)||chr(1090)),
            (6,chr(1329)||chr(1377)||chr(1397)||chr(1381)||chr(1408)),
            (7,chr(1513)||chr(1500)||chr(1493)||chr(1501)),
            (8,chr(1605)||chr(1585)||chr(1581)||chr(1576)||chr(1575)),
            (9,chr(1828)||chr(1824)||chr(1835)||chr(1808)),
            (10,chr(1931)||chr(1960)||chr(1928)||chr(1964)||chr(1920)||chr(1960)),
            (11,chr(2002)||chr(2014)||chr(1999)),
            (12,chr(2344)||chr(2350)||chr(2360)||chr(2381)||chr(2340)||chr(2375)),
            (13,chr(2489)||chr(2509)||chr(2479)||chr(2494)||chr(2482)||chr(2507)),
            (14,chr(2616)||chr(2596)||chr(2623)||chr(2616)||chr(2637)||chr(2608)||chr(2624)),
            (15,chr(2997)||chr(2979)||chr(3007)||chr(2965)||chr(3021)||chr(2965)||chr(2990)||chr(3021)),
            (16,chr(3112)||chr(3118)||chr(3128)||chr(3149)||chr(3093)||chr(3134)||chr(3120)||chr(3074)),
            (17,chr(3521)||chr(3530)||chr(3515)||chr(3539)),
            (18,chr(3626)||chr(3623)||chr(3633)||chr(3626)||chr(3604)||chr(3637)),
            (19,chr(3754)||chr(3760)||chr(3738)||chr(3762)||chr(3725)||chr(3732)||chr(3765)),
            (20,chr(3926)||chr(3851)||chr(3921)||chr(3962)),
            (21,chr(4121)||chr(4100)||chr(4154)||chr(4153)||chr(4098)||chr(4124)||chr(4140)),
            (22,chr(4306)||chr(4304)||chr(4315)||chr(4304)||chr(4320)||chr(4335)),
            (23,chr(4656)||chr(4619)||chr(4637)),
            (24,chr(5091)||chr(5043)||chr(5033)),
            (25,chr(6023)||chr(6040)||chr(6042)||chr(6070)||chr(6038)||chr(6047)||chr(6076)||chr(6042)),
            (26,chr(6176)||chr(6199)||chr(6178)||chr(6184)),
            (27,chr(12371)||chr(12435)||chr(12395)||chr(12385)||chr(12399)),
            (28,chr(12459)||chr(12479)||chr(12459)||chr(12490)),
            (29,chr(21271)||chr(20140)||chr(26481)||chr(20140)),
            (30,chr(50504)||chr(45397)||chr(54616)||chr(49464)||chr(50836)),
            (31,chr(11612)||chr(11568)||chr(11618)),
            (32,chr(42240)||chr(42251)||chr(42273)),
            (33,chr(101)||chr(769)||chr(7885)||chr(768)),
            (34,chr(1575)||chr(1604)||chr(1593)||chr(32)||chr(65)||chr(66)||chr(67)),
            (35,chr(128512)||chr(128640)),
            (36,chr(119070)||chr(119074)),
            (37,chr(134071)||chr(173746)),
            (38,chr(125184)||chr(125217)),
            (39,chr(128105)||chr(8205)||chr(128187)),
            (40,chr(128077)||chr(127997))
        ) AS e(id, want) ON e.id = c.id
    WHERE c.value IS DISTINCT FROM e.want) = 0
    AND (SELECT count(*) FROM probe.charset_matrix) = 40
    AND (SELECT length(value) FROM probe.charset_matrix WHERE script_name = 'supp_emoji') = 2
    AND (SELECT octet_length(value) FROM probe.charset_matrix WHERE script_name = 'supp_emoji') = 8
    AND (SELECT length(value) FROM probe.charset_matrix WHERE script_name = 'emoji_zwj') = 3
    AND (SELECT length(value) FROM probe.charset_matrix WHERE script_name = 'combining') = 4
    THEN 'ok' ELSE 'bad' END;

-- Multi-byte LOBs compared against HANA's own MD5 of its own bytes, through a
-- table carrying wide_char_mode 'wchar'. That option is REQUIRED here and the
-- table above is the negative control: the same NCLOB read through the default
-- SQL_C_CHAR comes back truncated at its CHARACTER count, SQL_SUCCESS, no
-- warning -- 1000 bytes of a 1666-byte value. An ASCII LOB never shows it,
-- because a character count and a byte count agree for ASCII.
SELECT 'nclob_sizes=' || CASE WHEN (
    SELECT count(*) FROM probe.nclob_sizes s JOIN probe.nclob_truth t USING (id)
    WHERE md5(s.v) IS DISTINCT FROM t.hana_md5
       OR length(s.v) IS DISTINCT FROM t.hana_chars
       OR octet_length(s.v) IS DISTINCT FROM t.hana_bytes) = 0
    AND (SELECT count(*) FROM probe.nclob_sizes) = 3
    AND (SELECT length(c) FROM probe.nclob_sizes WHERE id = 3) = 20000
    THEN 'ok' ELSE 'bad' END;

-- An imported column whose remote scale is unstated must not be constrained to
-- scale 0. Predicted from the metadata above: SMALLDECIMAL and unconstrained
-- DECIMAL import as bare numeric and keep their fractions, while DECIMAL(18,4)
-- and DECIMAL(38,0) keep their modifiers -- the second is a real scale of zero
-- and proves the fix distinguishes the two rather than dropping all modifiers.
SELECT 'import_scale=' || CASE WHEN
    (SELECT "SD_VALUE" FROM imported_scale."ODBC_FDW_SCALE_MATRIX" WHERE "ID" = 1)
        = numeric '3.14159' AND
    (SELECT "DFREE_VALUE" FROM imported_scale."ODBC_FDW_SCALE_MATRIX" WHERE "ID" = 1)
        = numeric '2.718281828459045' AND
    (SELECT "SD_VALUE" FROM imported_scale."ODBC_FDW_SCALE_MATRIX" WHERE "ID" = 2)
        = numeric '-0.00001' AND
    (SELECT "D18_4" FROM imported_scale."ODBC_FDW_SCALE_MATRIX" WHERE "ID" = 2)
        = numeric '-1.5' AND
    (SELECT "D38_0" FROM imported_scale."ODBC_FDW_SCALE_MATRIX" WHERE "ID" = 2)
        = numeric '-7' AND
    (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
      WHERE attrelid = 'imported_scale."ODBC_FDW_SCALE_MATRIX"'::regclass
        AND attname = 'SD_VALUE') = 'numeric' AND
    (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
      WHERE attrelid = 'imported_scale."ODBC_FDW_SCALE_MATRIX"'::regclass
        AND attname = 'D38_0') = 'numeric(38,0)'
    THEN 'ok' ELSE 'bad' END;

SELECT 'wide_decimal=' || CASE WHEN
    (SELECT d38_2 FROM probe.wide_decimal_text WHERE id = 1) = '999999999999999999999999999999999999.99' AND
    (SELECT d38_2 FROM probe.wide_decimal_text WHERE id = 2) = '-999999999999999999999999999999999999.99' AND
    (SELECT d38_0 FROM probe.wide_decimal_text WHERE id = 2) = '-99999999999999999999999999999999999999' AND
    (SELECT d18_4 FROM probe.wide_decimal_text WHERE id = 2) = '-12345678901234.5678' AND
    (SELECT d38_2 FROM probe.wide_decimal WHERE id = 2) = -999999999999999999999999999999999999.99 AND
    (SELECT d38_0 FROM probe.wide_decimal WHERE id = 2) = -99999999999999999999999999999999999999
    THEN 'ok' ELSE 'bad' END;

SELECT 'float_roundtrip=' || CASE WHEN
    (SELECT dbl FROM probe.float_matrix WHERE id = 1) = double precision '0.12345678901234566' AND
    (SELECT dbl FROM probe.float_matrix WHERE id = 2) = double precision '1.7976931348623157e308' AND
    (SELECT dbl FROM probe.float_matrix WHERE id = 3) = double precision '-1.7976931348623157e308' AND
    (SELECT dbl FROM probe.float_matrix WHERE id = 4) = double precision '2.2250738585072014e-308' AND
    (SELECT rl FROM probe.float_matrix WHERE id = 1) = real '3.25' AND
    (SELECT rl IS NULL FROM probe.float_matrix WHERE id = 2) AND
    (SELECT rl IS NULL FROM probe.float_matrix WHERE id = 3) AND
    (SELECT rl IS NULL FROM probe.float_matrix WHERE id = 4)
    THEN 'ok' ELSE 'bad' END;

SELECT 'float_text=' || CASE WHEN
    (SELECT dbl FROM probe.float_matrix_text WHERE id = 1) = '0.12345678901234566' AND
    (SELECT dbl FROM probe.float_matrix_text WHERE id = 2) = '1.7976931348623157e+308' AND
    (SELECT rl FROM probe.float_matrix_text WHERE id = 1) = '3.25'
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
    (SELECT tiny_value FROM probe.type_matrix WHERE id = 1) = 127 AND
    (SELECT small_value FROM probe.type_matrix WHERE id = 1) = -32768 AND
    (SELECT integer_value FROM probe.type_matrix WHERE id = 1) = 2147483647 AND
    (SELECT bigint_value FROM probe.type_matrix WHERE id = 1) = 922337203685477580 AND
    (SELECT decimal_value FROM probe.type_matrix WHERE id = 1) = 12345678901234.5678 AND
    (SELECT real_value FROM probe.type_matrix WHERE id = 1) = 3.25::real AND
    (SELECT double_value FROM probe.type_matrix WHERE id = 1) = 1234567.125 AND
    (SELECT boolean_value FROM probe.type_matrix WHERE id = 1) AND
    (SELECT rtrim(char_value) FROM probe.type_matrix WHERE id = 1) = 'abc' AND
    (SELECT rtrim(nchar_value) FROM probe.type_matrix WHERE id = 1) = '東京' AND
    (SELECT varchar_value FROM probe.type_matrix WHERE id = 1) = 'plain varchar' AND
    (SELECT nvarchar_value FROM probe.type_matrix WHERE id = 1) = 'Grüße 東京' AND
    (SELECT date_value FROM probe.type_matrix WHERE id = 1) = DATE '2024-06-30' AND
    (SELECT time_value FROM probe.type_matrix WHERE id = 1) = TIME '12:34:56' AND
    (SELECT timestamp_value FROM probe.type_matrix WHERE id = 1) = TIMESTAMP '2024-06-30 12:34:56' AND
    (SELECT seconddate_value FROM probe.type_matrix WHERE id = 1) = TIMESTAMP '2024-06-30 12:34:56' AND
    (SELECT clob_value FROM probe.type_matrix WHERE id = 1) = 'plain clob' AND
    (SELECT nclob_value FROM probe.type_matrix WHERE id = 1) = 'unicode 東京' AND
    (SELECT encode(blob_value, 'hex') FROM probe.type_matrix WHERE id = 1) = '00ff1020'
    THEN 'ok' ELSE 'bad' END;

SELECT 'type_matrix_nulls=' || CASE WHEN
    (SELECT tiny_value IS NULL AND small_value IS NULL AND integer_value IS NULL AND bigint_value IS NULL
            AND decimal_value IS NULL AND real_value IS NULL AND double_value IS NULL AND boolean_value IS NULL
            AND char_value IS NULL AND nchar_value IS NULL AND varchar_value IS NULL AND nvarchar_value IS NULL
            AND date_value IS NULL AND time_value IS NULL AND timestamp_value IS NULL AND seconddate_value IS NULL
            AND clob_value IS NULL AND nclob_value IS NULL AND blob_value IS NULL
     FROM probe.type_matrix WHERE id = 2)
    THEN 'ok' ELSE 'bad' END;

SELECT 'import_type_matrix=' || CASE WHEN
    (SELECT "BIGINT_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 922337203685477580 AND
    (SELECT "BOOLEAN_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) AND
    (SELECT "NVARCHAR_VALUE" FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 'Grüße 東京'
    THEN 'ok' ELSE 'bad' END;

-- Version 1.0.1 maps SQL_BINARY, SQL_VARBINARY, and SQL_LONGVARBINARY to
-- bytea. Verify both fixed-width and variable-width payload preservation.
SELECT 'import_binary=' || CASE WHEN
    (SELECT encode("BINARY_VALUE", 'hex')
       FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = 'abcd' AND
    (SELECT encode("VARBINARY_VALUE", 'hex')
       FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 1) = '1020' AND
    (SELECT "BINARY_VALUE" IS NULL AND "VARBINARY_VALUE" IS NULL
       FROM imported."ODBC_FDW_TYPE_MATRIX" WHERE "ID" = 2)
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
    (SELECT json_value::jsonb ->> 'count' FROM probe.json_values WHERE id = 1) = '42' AND
    (SELECT json_nclob_value #>> '{document,title}' FROM probe.json_values WHERE id = 1) = 'Привет' AND
    (SELECT jsonb_array_length(json_nclob_value -> 'items') FROM probe.json_values WHERE id = 1) = 2 AND
    (SELECT json_nclob_value ->> 'unicode' FROM probe.json_values WHERE id = 1) = 'Grüße 東京 😀'
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
    (SELECT "lower_value" FROM imported_case."OdbcFdwMixedTable") = 'lower mixed table' AND
    (SELECT "MixedValue" FROM imported_case."OdbcFdwMixedTable") = 'mixed mixed table' AND
    (SELECT "Spaced Value" FROM imported_case."OdbcFdwMixedTable") = 'space mixed table'
    THEN 'ok' ELSE 'bad' END;

SELECT 'sql_query=' || CASE WHEN
    (SELECT count(*) FROM probe.query_types) = 1 AND
    (SELECT text_value FROM probe.query_types WHERE id = 1) = 'alpha'
    THEN 'ok' ELSE 'bad' END;

-- A correlated local value is a PostgreSQL Param. It must remain local (this
-- FDW pushes down only Var = Const) while each rescan returns the matching
-- remote output row.
SELECT 'parameter_in_out=' || CASE WHEN
    (SELECT string_agg(remote.text_value, ',' ORDER BY input.id)
     FROM (VALUES (1, 'alpha'::text), (2, 'beta'::text)) AS input(id, expected)
     CROSS JOIN LATERAL
        (SELECT text_value FROM probe.direct_types WHERE id = input.id) AS remote
     WHERE remote.text_value = input.expected) = 'alpha,beta'
    THEN 'ok' ELSE 'bad' END;

SELECT 'large_value=' || CASE WHEN
    (SELECT length(nclob_value) FROM probe.direct_large WHERE id = 1) = 12000 AND
    (SELECT md5(nclob_value) FROM probe.direct_large WHERE id = 1) = md5(repeat('x', 12000)) AND
    (SELECT encode(blob_value, 'hex') FROM probe.direct_large WHERE id = 1) = '41424344'
    THEN 'ok' ELSE 'bad' END;

SET enable_material = off;
SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT 'rescan=' || CASE WHEN
    (SELECT count(*) FROM (VALUES (1), (1)) AS outer_row(id)
     CROSS JOIN LATERAL
        (SELECT payload FROM probe.rescan_source WHERE id = outer_row.id) AS inner_row) = 2
    THEN 'ok' ELSE 'bad' END;
