DROP TABLE "@SCHEMA@"."ODBC_FDW_NCLOB_SIZES";
DROP TABLE "@SCHEMA@"."ODBC_FDW_MONEY_MATRIX";
DROP TABLE "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX";
DROP TABLE "@SCHEMA@"."ODBC_FDW_SCALE_MATRIX";
DROP TABLE "@SCHEMA@"."ODBC_FDW_FLOAT_MATRIX";
DROP TABLE "@SCHEMA@"."ODBC_FDW_WIDE_DECIMAL";
DROP TABLE "@SCHEMA@"."ODBC_FDW_DATA_TYPES";
DROP TABLE "@SCHEMA@"."ODBC_FDW_LARGE_VALUES";
DROP TABLE "@SCHEMA@"."ODBC_FDW_SINGLE_ROW";
DROP TABLE "@SCHEMA@"."ODBC_FDW_TYPE_MATRIX";
DROP TABLE "@SCHEMA@"."ODBC_FDW_ENCODING_MATRIX";
DROP TABLE "@SCHEMA@"."ODBC_FDW_JSON_VALUES";
DROP TABLE "@SCHEMA@"."odbc_fdw_lower_table";
DROP TABLE "@SCHEMA@"."OdbcFdwMixedTable";

CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_DATA_TYPES" (
    "ID"              INTEGER PRIMARY KEY,
    "TEXT_VALUE"      NVARCHAR(100),
    "INTEGER_VALUE"   INTEGER,
    "DECIMAL_VALUE"   DECIMAL(20, 4),
    "DATE_VALUE"      DATE,
    "TIME_VALUE"      TIME,
    "TIMESTAMP_VALUE" TIMESTAMP,
    "NULL_VALUE"      NVARCHAR(10),
    "UNICODE_VALUE"   NVARCHAR(100)
);

INSERT INTO "@SCHEMA@"."ODBC_FDW_DATA_TYPES" VALUES
    (1, 'alpha', 42, 123.4500, DATE '2024-01-02', TIME '03:04:05',
     TIMESTAMP '2024-01-02 03:04:05.0000000', NULL, 'Grüße');

INSERT INTO "@SCHEMA@"."ODBC_FDW_DATA_TYPES" VALUES
    (2, 'beta', -7, -0.0100, DATE '2024-12-31', TIME '23:59:59',
     TIMESTAMP '2024-12-31 23:59:59.0000000', 'present', '東京');

CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_LARGE_VALUES" (
    "ID"          INTEGER PRIMARY KEY,
    "NCLOB_VALUE" NCLOB,
    "BLOB_VALUE"  BLOB
);

INSERT INTO "@SCHEMA@"."ODBC_FDW_LARGE_VALUES" VALUES
    (1, TO_NCLOB('xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'), X'41424344');

CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_SINGLE_ROW" (
    "ID"      INTEGER PRIMARY KEY,
    "PAYLOAD" NVARCHAR(100)
);

INSERT INTO "@SCHEMA@"."ODBC_FDW_SINGLE_ROW" VALUES (1, 'rescan');

CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_TYPE_MATRIX" (
    "ID"               INTEGER PRIMARY KEY,
    "TINY_VALUE"       TINYINT,
    "SMALL_VALUE"      SMALLINT,
    "INTEGER_VALUE"    INTEGER,
    "BIGINT_VALUE"     BIGINT,
    "DECIMAL_VALUE"    DECIMAL(18, 4),
    "REAL_VALUE"       REAL,
    "DOUBLE_VALUE"     DOUBLE,
    "BOOLEAN_VALUE"    BOOLEAN,
    "CHAR_VALUE"       CHAR(6),
    "NCHAR_VALUE"      NCHAR(6),
    "VARCHAR_VALUE"    VARCHAR(100),
    "NVARCHAR_VALUE"   NVARCHAR(100),
    "DATE_VALUE"       DATE,
    "TIME_VALUE"       TIME,
    "TIMESTAMP_VALUE"  TIMESTAMP,
    "SECONDDATE_VALUE" SECONDDATE,
    "CLOB_VALUE"       CLOB,
    "NCLOB_VALUE"      NCLOB,
    "BLOB_VALUE"       BLOB,
    "BINARY_VALUE"     BINARY(4),
    "VARBINARY_VALUE"  VARBINARY(4)
);

INSERT INTO "@SCHEMA@"."ODBC_FDW_TYPE_MATRIX" VALUES
    (1, 127, -32768, 2147483647, 922337203685477580,
     12345678901234.5678, 3.25, 1234567.125, TRUE,
     'abc', '東京', 'plain varchar', 'Grüße 東京',
     DATE '2024-06-30', TIME '12:34:56', TIMESTAMP '2024-06-30 12:34:56.0000000',
     TO_SECONDDATE('2024-06-30 12:34:56'),
     TO_CLOB('plain clob'), TO_NCLOB('unicode 東京'), X'00FF1020', X'ABCD', X'1020');

INSERT INTO "@SCHEMA@"."ODBC_FDW_TYPE_MATRIX" VALUES
    (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_ENCODING_MATRIX" (
    "ID"              INTEGER PRIMARY KEY,
    "ASCII_VALUE"     VARCHAR(100),
    "CYRILLIC_VALUE"  NVARCHAR(100),
    "UTF8_VALUE"      NVARCHAR(100),
    "COMBINING_VALUE" NVARCHAR(100)
);

INSERT INTO "@SCHEMA@"."ODBC_FDW_ENCODING_MATRIX" VALUES
    (1, 'The quick brown fox 123 !@#$', 'Привет, мир — Ёжик', 'Grüße 東京 😀', 'é');

CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_JSON_VALUES" (
    "ID"               INTEGER PRIMARY KEY,
    "JSON_VALUE"       NVARCHAR(5000),
    "JSON_NCLOB_VALUE" NCLOB
);

INSERT INTO "@SCHEMA@"."ODBC_FDW_JSON_VALUES" VALUES
    (1,
     '{"owner":"София","tags":["ascii","東京","😀"],"active":true,"count":42}',
     TO_NCLOB('{"document":{"title":"Привет","locale":"ru_RU"},"items":[{"id":1},{"id":2}],"unicode":"Grüße 東京 😀"}'));

INSERT INTO "@SCHEMA@"."ODBC_FDW_JSON_VALUES" VALUES (2, NULL, NULL);

CREATE COLUMN TABLE "@SCHEMA@"."odbc_fdw_lower_table" (
    "UPPER_VALUE"  INTEGER,
    "lower_value"  NVARCHAR(100),
    "MixedValue"   NVARCHAR(100),
    "Spaced Value" NVARCHAR(100)
);

INSERT INTO "@SCHEMA@"."odbc_fdw_lower_table" VALUES
    (1, 'lower column', 'mixed column', 'space column');

CREATE COLUMN TABLE "@SCHEMA@"."OdbcFdwMixedTable" (
    "UPPER_VALUE"  INTEGER,
    "lower_value"  NVARCHAR(100),
    "MixedValue"   NVARCHAR(100),
    "Spaced Value" NVARCHAR(100)
);

INSERT INTO "@SCHEMA@"."OdbcFdwMixedTable" VALUES
    (2, 'lower mixed table', 'mixed mixed table', 'space mixed table');

-- Values that a driver's own TEXT rendering cannot carry, which is what the
-- scan used to depend on. The SAP client renders DOUBLE with 15 significant
-- digits, so the 17-digit value below came back as a DIFFERENT double and
-- DBL_MAX came back 1.79769313486232E+308 -- larger than DBL_MAX, which
-- PostgreSQL rejects as out of range. Both are exact once the binary value is
-- retrieved and formatted by PostgreSQL's own float output.
CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_FLOAT_MATRIX" (
    "ID"          INTEGER PRIMARY KEY,
    "DBL"         DOUBLE,
    "RL"          REAL
);
INSERT INTO "@SCHEMA@"."ODBC_FDW_FLOAT_MATRIX" VALUES
    (1, 0.12345678901234566, 3.25);
INSERT INTO "@SCHEMA@"."ODBC_FDW_FLOAT_MATRIX" VALUES
    (2, 1.7976931348623157E308, NULL);
INSERT INTO "@SCHEMA@"."ODBC_FDW_FLOAT_MATRIX" VALUES
    (3, -1.7976931348623157E308, NULL);
INSERT INTO "@SCHEMA@"."ODBC_FDW_FLOAT_MATRIX" VALUES
    (4, 2.2250738585072014E-308, NULL);

-- Decimals whose text rendering is longer than their precision. The sign and
-- the decimal point are the two characters a precision does not budget for, so
-- both signs are seeded; the negative is one character wider.
CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_WIDE_DECIMAL" (
    "ID"    INTEGER PRIMARY KEY,
    "D38_2" DECIMAL(38, 2),
    "D38_0" DECIMAL(38, 0),
    "D18_4" DECIMAL(18, 4)
);
INSERT INTO "@SCHEMA@"."ODBC_FDW_WIDE_DECIMAL" VALUES
    (1, 999999999999999999999999999999999999.99,
        99999999999999999999999999999999999999, 12345678901234.5678);
INSERT INTO "@SCHEMA@"."ODBC_FDW_WIDE_DECIMAL" VALUES
    (2, -999999999999999999999999999999999999.99,
        -99999999999999999999999999999999999999, -12345678901234.5678);

-- Decimal columns whose SCALE the driver does not state, beside ones where it
-- does. SQLColumns reports DECIMAL_DIGITS as NULL for a type whose scale is a
-- property of each value; importing that as scale 0 rounds the fraction away
-- at DDL time, which no later query can recover.
--
-- SD_VALUE and DFREE_VALUE are the unstated-scale cases, D18_4 and D38_0 the
-- stated ones -- D38_0 in particular is a genuine scale of zero and must keep
-- its numeric(38,0) mapping, so the fix cannot simply drop every modifier.
CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_SCALE_MATRIX" (
    "ID"          INTEGER PRIMARY KEY,
    "SD_VALUE"    SMALLDECIMAL,
    "DFREE_VALUE" DECIMAL,
    "D18_4"       DECIMAL(18,4),
    "D38_0"       DECIMAL(38,0)
);
INSERT INTO "@SCHEMA@"."ODBC_FDW_SCALE_MATRIX" VALUES
    (1, 3.14159, 2.718281828459045, 1.5000, 7);
INSERT INTO "@SCHEMA@"."ODBC_FDW_SCALE_MATRIX" VALUES
    (2, -0.00001, -0.000000000000001, -1.5000, -7);

-- Money matrix, mirroring the credential-free SQL Server one so the same
-- boundary is proved against the SAP driver: one column per DECLARED precision
-- and scale, rows at the extremes of each column's own domain in both signs.
CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_MONEY_MATRIX" (
    "ID"    INTEGER PRIMARY KEY,
    "LABEL" NVARCHAR(20),
    "D1_0" DECIMAL(1,0),
    "D9_2" DECIMAL(9,2),
    "D15_2" DECIMAL(15,2),
    "D18_4" DECIMAL(18,4),
    "D19_4" DECIMAL(19,4),
    "D28_6" DECIMAL(28,6),
    "D30_0" DECIMAL(30,0),
    "D31_0" DECIMAL(31,0),
    "D32_0" DECIMAL(32,0),
    "D34_2" DECIMAL(34,2),
    "D38_0" DECIMAL(38,0),
    "D38_2" DECIMAL(38,2)
);
INSERT INTO "@SCHEMA@"."ODBC_FDW_MONEY_MATRIX" VALUES
    (1, 'max_positive',
     9, 9999999.99, 9999999999999.99, 99999999999999.9999, 999999999999999.9999, 9999999999999999999999.999999, 999999999999999999999999999999, 9999999999999999999999999999999, 99999999999999999999999999999999, 99999999999999999999999999999999.99, 99999999999999999999999999999999999999, 999999999999999999999999999999999999.99);
INSERT INTO "@SCHEMA@"."ODBC_FDW_MONEY_MATRIX" VALUES
    (2, 'max_negative',
     -9, -9999999.99, -9999999999999.99, -99999999999999.9999, -999999999999999.9999, -9999999999999999999999.999999, -999999999999999999999999999999, -9999999999999999999999999999999, -99999999999999999999999999999999, -99999999999999999999999999999999.99, -99999999999999999999999999999999999999, -999999999999999999999999999999999999.99);
INSERT INTO "@SCHEMA@"."ODBC_FDW_MONEY_MATRIX" VALUES
    (3, 'smallest_unit',
     1, 0.01, 0.01, 0.0001, 0.0001, 0.000001, 1, 1, 1, 0.01, 1, 0.01);
INSERT INTO "@SCHEMA@"."ODBC_FDW_MONEY_MATRIX" VALUES
    (4, 'zero',
     0, 0.00, 0.00, 0.0000, 0.0000, 0.000000, 0, 0, 0, 0.00, 0, 0.00);
INSERT INTO "@SCHEMA@"."ODBC_FDW_MONEY_MATRIX" VALUES
    (5, 'typical',
     1, 1234.56, 1234.56, 1234.5678, 1234.5678, 1234.567890, 1234, 1234, 1234, 1234.56, 1234, 1234.56);
INSERT INTO "@SCHEMA@"."ODBC_FDW_MONEY_MATRIX" VALUES
    (6, 'nulls', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- Writing systems across the Unicode planes. Literals are written directly as
-- UTF-8 here, which the HANA executor transmits unchanged -- unlike the SQL
-- Server suite, whose ANSI entry point requires code units.
CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" (
    "ID"          INTEGER PRIMARY KEY,
    "SCRIPT_NAME" NVARCHAR(20),
    "VALUE"       NVARCHAR(100)
);
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (1, 'ascii', 'ABC12!');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (2, 'latin1', 'café Üßñ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (3, 'latin_ext', 'Čřőžłẹ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (4, 'greek', 'Ελλάδα');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (5, 'cyrillic', 'Привет');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (6, 'armenian', 'Աայեր');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (7, 'hebrew', 'שלום');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (8, 'arabic', 'مرحبا');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (9, 'syriac', 'ܤܠܫܐ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (10, 'thaana', 'ދިވެހި');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (11, 'nko', 'ߒߞߏ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (12, 'devanagari', 'नमस्ते');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (13, 'bengali', 'হ্যালো');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (14, 'gurmukhi', 'ਸਤਿਸ੍ਰੀ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (15, 'tamil', 'வணிக்கம்');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (16, 'telugu', 'నమస్కారం');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (17, 'sinhala', 'ශ්රී');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (18, 'thai', 'สวัสดี');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (19, 'lao', 'ສະບາຍດີ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (20, 'tibetan', 'བ་དེ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (21, 'myanmar', 'မင်္ဂလာ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (22, 'georgian', 'გამარჯ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (23, 'ethiopic', 'ሰላም');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (24, 'cherokee', 'ᏣᎳᎩ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (25, 'khmer', 'ជមរាពសូរ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (26, 'mongolian', 'ᠠᠷᠢᠨ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (27, 'hiragana', 'こんにちは');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (28, 'katakana', 'カタカナ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (29, 'han', '北京東京');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (30, 'hangul', '안녕하세요');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (31, 'tifinagh', 'ⵜⴰⵢ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (32, 'vai', 'ꔀꔋꔡ');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (33, 'combining', 'éọ̀');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (34, 'rtl_mixed', 'الع ABC');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (35, 'supp_emoji', '😀🚀');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (36, 'supp_music', '𝄞𝄢');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (37, 'supp_cjk_ext', '𠮷𪚲');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (38, 'supp_adlam', '𞤀𞤡');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (39, 'emoji_zwj', '👩‍💻');
INSERT INTO "@SCHEMA@"."ODBC_FDW_CHARSET_MATRIX" VALUES (40, 'emoji_skin', '👍🏽');

-- Multi-byte LOBs at sizes that cross the read chunk, which an ASCII LOB
-- fixture cannot exercise: a character count and a byte count agree for ASCII,
-- and it is exactly their disagreement that this catches. The pattern is 10
-- characters and 17 UTF-8 bytes, so no size here is a whole number of chunks.
CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_NCLOB_SIZES" (
    "ID" INTEGER PRIMARY KEY, "CHARS" INTEGER, "V" NCLOB, "C" CLOB);
INSERT INTO "@SCHEMA@"."ODBC_FDW_NCLOB_SIZES" VALUES (1,  1000, RPAD('', 1000,  'Grüße 東京 '), RPAD('', 1000, 'ascii '));
INSERT INTO "@SCHEMA@"."ODBC_FDW_NCLOB_SIZES" VALUES (2,  8000, RPAD('', 8000,  'Grüße 東京 '), RPAD('', 8000, 'ascii '));
INSERT INTO "@SCHEMA@"."ODBC_FDW_NCLOB_SIZES" VALUES (3, 20000, RPAD('', 20000, 'Grüße 東京 '), RPAD('', 20000, 'ascii '));
