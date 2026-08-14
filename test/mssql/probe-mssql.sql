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
-- Declared twice on purpose. The numeric declaration is what an operator would
-- write, and numeric(p,s) pads a short rendering back to scale with zeros, so
-- it can only catch a loss that changes the padded result. The text declaration
-- carries the bytes the wrapper actually produced, so a single lost character
-- is visible whatever its position.
CREATE FOREIGN TABLE probe.wide_decimal (
    id integer, d38_2 numeric(38,2), d18_4 numeric(18,4)
) SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_WIDE_DECIMAL', id 'ID',
    d38_2 'D38_2', d18_4 'D18_4'
);
CREATE FOREIGN TABLE probe.wide_decimal_text (
    id integer, d38_2 text, d18_4 text
) SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_WIDE_DECIMAL', id 'ID',
    d38_2 'D38_2', d18_4 'D18_4'
);
CREATE FOREIGN TABLE probe.wide_decimal_s0 (
    id integer, d38_0 numeric(38,0), d32_0 numeric(32,0)
) SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_WIDE_DECIMAL_S0', id 'ID',
    d38_0 'D38_0', d32_0 'D32_0'
);
CREATE FOREIGN TABLE probe.scripts (id integer, script_name text, value text)
SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_SCRIPTS', id 'ID',
    script_name 'SCRIPT_NAME', value 'VALUE'
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
) SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_MONEY_MATRIX', id 'ID', label 'LABEL',
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
) SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_MONEY_MATRIX', id 'ID', label 'LABEL',
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
SERVER mssql OPTIONS (
    schema 'dbo', table 'ODBC_FDW_CHARSET_MATRIX', id 'ID',
    script_name 'SCRIPT_NAME', value 'VALUE'
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
-- The SILENT case, asserted first and on its own.
--
-- Against 1.0.2 this returns 'bad' rather than an error: the driver reports 40
-- bytes for the negative decimal(38,2), delivers 38, and does not continue, so
-- the text column reads '-999999999999999999999999999999999999' and the numeric
-- column reads '-999999999999999999999999999999999999.00' -- the cents replaced
-- by zeros, with the right row count and no diagnostic anywhere. d18_4 is the
-- paired success case: it fits the old sizing and was always correct, so a
-- failure here is the fix breaking something rather than the defect surviving.
-- Drivers disagree on ONE cosmetic point: Microsoft ODBC Driver 18 renders a
-- value below 1 without its leading zero, as .01 rather than 0.01. That is a
-- rendering convention and not a loss, so it is normalised away on BOTH sides
-- rather than baked into the expected values, which would make this suite
-- assert one driver's spelling.
--
-- The normalisation cannot hide the defect these fixtures exist for. Truncation
-- removes characters from the RIGHT; this only touches an optional zero before
-- the decimal point, and leaves every digit and the sign untouched.
CREATE FUNCTION norm_decimal(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT regexp_replace(t, '^(-?)0\.', '\1.') $$;

-- Every declared precision and scale, at the extremes of each column's domain,
-- compared as TEXT so a single lost character is visible wherever it falls.
-- numeric(p,s) would pad a short rendering back to scale with zeros and show a
-- plausible amount instead of a missing digit.
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

-- The same values through numeric(p,s), which is what an operator declares, and
-- a SUM so a per-row corruption that survives the equality checks still moves an
-- aggregate. The all-NULL row proves NULL is not confused with zero.
SELECT 'money_numeric=' || CASE WHEN
    (SELECT d38_2 FROM probe.money_numeric WHERE label = 'max_negative') = numeric '-999999999999999999999999999999999999.99' AND
    (SELECT d32_0 FROM probe.money_numeric WHERE label = 'max_negative') = numeric '-99999999999999999999999999999999' AND
    (SELECT d38_2 FROM probe.money_numeric WHERE label = 'smallest_unit') = numeric '0.01' AND
    (SELECT sum(d38_2) FROM probe.money_numeric) = numeric '1234.57' AND
    (SELECT d38_2 IS NULL AND d1_0 IS NULL AND d30_0 IS NULL
     FROM probe.money_numeric WHERE label = 'nulls')
    THEN 'ok' ELSE 'bad' END;

-- Writing systems across the Unicode planes, compared against the same code
-- points assembled locally with chr() so this file stays ASCII and cannot itself
-- be re-encoded in transit. Character and byte lengths are asserted too: a
-- double encoding round-trips as text but changes octet_length.
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

SELECT 'wide_decimal=' || CASE WHEN
    (SELECT d38_2 FROM probe.wide_decimal_text WHERE id = 1) = '999999999999999999999999999999999999.99' AND
    (SELECT d38_2 FROM probe.wide_decimal_text WHERE id = 2) = '-999999999999999999999999999999999999.99' AND
    (SELECT d18_4 FROM probe.wide_decimal_text WHERE id = 2) = '-12345678901234.5678' AND
    (SELECT d38_2 FROM probe.wide_decimal WHERE id = 2) = -999999999999999999999999999999999999.99 AND
    (SELECT d18_4 FROM probe.wide_decimal WHERE id = 1) = 12345678901234.5678
    THEN 'ok' ELSE 'bad' END;
-- The LOUD case. Against 1.0.2 this aborts the scan with "Numeric value out of
-- range" instead of returning a value, so it is kept separate: an abort here
-- would otherwise stop the silent assertion above from ever being reported.
SELECT 'wide_decimal_scale0=' || CASE WHEN
    (SELECT d38_0 FROM probe.wide_decimal_s0 WHERE id = 2) = -99999999999999999999999999999999999999 AND
    (SELECT d32_0 FROM probe.wide_decimal_s0 WHERE id = 2) = -99999999999999999999999999999999 AND
    (SELECT d38_0 FROM probe.wide_decimal_s0 WHERE id = 1) = 99999999999999999999999999999999999999
    THEN 'ok' ELSE 'bad' END;
-- Wide retrieval across the scripts this distribution carries, compared against
-- the same code points assembled locally. chr() builds them from code point
-- numbers so this file stays ASCII and cannot itself be re-encoded in transit.
SELECT 'scripts=' || CASE WHEN
    (SELECT value FROM probe.scripts WHERE id = 1) =
        chr(1055)||chr(1088)||chr(1080)||chr(1074)||chr(1077)||chr(1090) AND
    (SELECT value FROM probe.scripts WHERE id = 2) = chr(21271)||chr(20140) AND
    (SELECT value FROM probe.scripts WHERE id = 3) =
        chr(128512)||chr(119070) AND
    (SELECT length(value) FROM probe.scripts WHERE id = 3) = 2 AND
    (SELECT octet_length(value) FROM probe.scripts WHERE id = 3) = 8 AND
    (SELECT value FROM probe.scripts WHERE id = 4) =
        chr(4656)||chr(4619)||chr(4637) AND
    (SELECT value FROM probe.scripts WHERE id = 5) =
        chr(7864)||' k'||chr(225)||chr(224)||'b'||chr(7885)||chr(768) AND
    (SELECT value FROM probe.scripts WHERE id = 6) =
        chr(2002)||chr(2014)||chr(1999) AND
    (SELECT value FROM probe.scripts WHERE id = 7) =
        chr(11612)||chr(11568)||chr(11618)
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
