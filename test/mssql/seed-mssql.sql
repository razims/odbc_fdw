DROP TABLE IF EXISTS dbo.ODBC_FDW_MONEY_MATRIX;
DROP TABLE IF EXISTS dbo.ODBC_FDW_CHARSET_MATRIX;
DROP TABLE IF EXISTS dbo.ODBC_FDW_WIDE_DECIMAL;
DROP TABLE IF EXISTS dbo.ODBC_FDW_WIDE_DECIMAL_S0;
DROP TABLE IF EXISTS dbo.ODBC_FDW_SCRIPTS;
DROP TABLE IF EXISTS dbo.ODBC_FDW_DATA_TYPES;
DROP TABLE IF EXISTS dbo.ODBC_FDW_TYPE_MATRIX;
DROP TABLE IF EXISTS dbo.ODBC_FDW_LARGE_VALUES;
DROP TABLE IF EXISTS dbo.ODBC_FDW_SINGLE_ROW;
DROP TABLE IF EXISTS dbo.ODBC_FDW_CASE_NAMES;

CREATE TABLE dbo.ODBC_FDW_DATA_TYPES (
    ID int PRIMARY KEY,
    TEXT_VALUE varchar(100),
    INTEGER_VALUE int,
    DECIMAL_VALUE decimal(20,4),
    DATE_VALUE date,
    TIME_VALUE time(6),
    TIMESTAMP_VALUE datetime2(6),
    NULL_VALUE varchar(10),
    UNICODE_VALUE nvarchar(100)
);
INSERT INTO dbo.ODBC_FDW_DATA_TYPES VALUES
    (1, 'alpha', 42, 123.4500, '2024-01-02', '03:04:05.123456',
     '2024-01-02T03:04:05.123456', NULL,
     N'Gr' + NCHAR(0x00FC) + NCHAR(0x00DF) + N'e'),
    (2, 'beta', -7, -0.0100, '2024-12-31', '23:59:59.654321',
     '2024-12-31T23:59:59.654321', 'present',
     NCHAR(0x6771) + NCHAR(0x4EAC));

CREATE TABLE dbo.ODBC_FDW_TYPE_MATRIX (
    ID int PRIMARY KEY,
    TINY_VALUE tinyint,
    SMALL_VALUE smallint,
    INTEGER_VALUE int,
    BIGINT_VALUE bigint,
    DECIMAL_VALUE decimal(18,4),
    REAL_VALUE real,
    FLOAT_VALUE float(53),
    BIT_VALUE bit,
    CHAR_VALUE char(6),
    NCHAR_VALUE nchar(6),
    VARCHAR_VALUE varchar(100),
    NVARCHAR_VALUE nvarchar(100),
    TEXT_VALUE varchar(max),
    NTEXT_VALUE nvarchar(max),
    DATE_VALUE date,
    TIME_VALUE time(6),
    DATETIME_VALUE datetime2(6),
    SMALLDATETIME_VALUE smalldatetime,
    GUID_VALUE uniqueidentifier,
    BINARY_VALUE binary(4),
    VARBINARY_VALUE varbinary(4),
    IMAGE_VALUE varbinary(max)
);
INSERT INTO dbo.ODBC_FDW_TYPE_MATRIX VALUES
    (1, 255, -32768, 2147483647, 922337203685477580,
     12345678901234.5678, 3.25, 1234567.125, 1,
     'abc', NCHAR(0x6771) + NCHAR(0x4EAC), 'plain text',
     N'Gr' + NCHAR(0x00FC) + NCHAR(0x00DF) + N'e ' +
         NCHAR(0x6771) + NCHAR(0x4EAC),
     REPLICATE('long ', 20),
     N'long unicode ' + NCHAR(0x041F) + NCHAR(0x0440) + NCHAR(0x0438) +
         NCHAR(0x0432) + NCHAR(0x0435) + NCHAR(0x0442) + N' ' +
         NCHAR(0x6771) + NCHAR(0x4EAC),
     '2024-06-30', '12:34:56.123456', '2024-06-30T12:34:56.123456',
     '2024-06-30T12:35:00', '01234567-89ab-cdef-0123-456789abcdef',
     0xABCD, 0x1020, 0x004142FF);
INSERT INTO dbo.ODBC_FDW_TYPE_MATRIX VALUES
    (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

CREATE TABLE dbo.ODBC_FDW_LARGE_VALUES (
    ID int PRIMARY KEY,
    TEXT_VALUE varchar(max),
    BLOB_VALUE varbinary(max)
);
INSERT INTO dbo.ODBC_FDW_LARGE_VALUES VALUES
    (1, REPLICATE(CAST('x' AS varchar(max)), 6000), 0x004142FF);

CREATE TABLE dbo.ODBC_FDW_SINGLE_ROW (ID int PRIMARY KEY, PAYLOAD varchar(100));
INSERT INTO dbo.ODBC_FDW_SINGLE_ROW VALUES (1, 'rescan');

-- Decimals whose TEXT rendering is longer than their precision, which is the
-- quantity a column buffer used to be sized from. Both signs are seeded: the
-- sign is one of the two characters that rendering needs and the precision does
-- not budget for, so a negative value is a full character wider than its
-- positive counterpart and fails at a precision the positive one survives.
--
-- Split by SCALE, because the two fail differently here and only one of them is
-- silent. Microsoft ODBC Driver 18 raises "Numeric value out of range" when a
-- scale-0 decimal does not fit, which at least stops the scan. For
-- decimal(38,2) it reports the full length, delivers a short value and declines
-- to continue -- and PostgreSQL's numeric(38,2) then PADS the missing digits
-- back with zeros, so the result is a plausible wrong amount and nothing stops
-- at all. That is the case these fixtures exist for.
CREATE TABLE dbo.ODBC_FDW_WIDE_DECIMAL (
    ID int PRIMARY KEY,
    D38_2 decimal(38,2),
    D18_4 decimal(18,4)
);
INSERT INTO dbo.ODBC_FDW_WIDE_DECIMAL VALUES
    (1,  999999999999999999999999999999999999.99,  12345678901234.5678),
    (2, -999999999999999999999999999999999999.99, -12345678901234.5678);

CREATE TABLE dbo.ODBC_FDW_WIDE_DECIMAL_S0 (
    ID int PRIMARY KEY,
    D38_0 decimal(38,0),
    D32_0 decimal(32,0)
);
INSERT INTO dbo.ODBC_FDW_WIDE_DECIMAL_S0 VALUES
    (1,  99999999999999999999999999999999999999,  99999999999999999999999999999999),
    (2, -99999999999999999999999999999999999999, -99999999999999999999999999999999);

CREATE TABLE dbo.ODBC_FDW_CASE_NAMES (
    UPPER_VALUE int,
    lower_value varchar(100),
    MixedValue nvarchar(100),
    [Spaced Value] nvarchar(100)
);
INSERT INTO dbo.ODBC_FDW_CASE_NAMES VALUES
    (1, 'lower column', N'mixed column', N'space column');

-- Scripts this distribution is expected to carry, every literal built from code
-- units server-side: the seed executor uses the ANSI ODBC entry point, so a
-- non-ASCII literal written directly in this file would be stored double
-- encoded and the fixture rather than the read path would be what is measured.
--
-- Chosen to exercise the parts of wide retrieval that differ from each other:
-- two-byte UTF-16 across several scripts, a SURROGATE PAIR for the
-- supplementary plane, and a COMBINING mark, which is two code points that must
-- not be reordered or coalesced.
CREATE TABLE dbo.ODBC_FDW_SCRIPTS (
    ID int PRIMARY KEY,
    SCRIPT_NAME varchar(32),
    VALUE nvarchar(100)
);
INSERT INTO dbo.ODBC_FDW_SCRIPTS VALUES
    -- Privet (Cyrillic)
    (1, 'cyrillic',
     NCHAR(0x041F) + NCHAR(0x0440) + NCHAR(0x0438) + NCHAR(0x0432) +
     NCHAR(0x0435) + NCHAR(0x0442)),
    -- Beijing (Han)
    (2, 'han', NCHAR(0x5317) + NCHAR(0x4EAC)),
    -- U+1F600 and U+1D11E, each a surrogate pair in UTF-16
    (3, 'supplementary',
     NCHAR(0xD83D) + NCHAR(0xDE00) + NCHAR(0xD834) + NCHAR(0xDD1E)),
    -- Selam (Ethiopic, used for Amharic)
    (4, 'ethiopic',
     NCHAR(0x1230) + NCHAR(0x120B) + NCHAR(0x121D)),
    -- Yoruba: precomposed E-with-dot-below plus a COMBINING grave accent
    (5, 'yoruba',
     NCHAR(0x1EB8) + N' k' + NCHAR(0x00E1) + NCHAR(0x00E0) + N'b' +
     NCHAR(0x1ECD) + NCHAR(0x0300)),
    -- N'Ko, a right-to-left African script
    (6, 'nko', NCHAR(0x07D2) + NCHAR(0x07DE) + NCHAR(0x07CF)),
    -- Tifinagh, used for Amazigh
    (7, 'tifinagh', NCHAR(0x2D5C) + NCHAR(0x2D30) + NCHAR(0x2D62));

-- Money matrix: one column per DECLARED precision and scale, because the buffer
-- defect this suite guards is driven by the declared precision rather than by
-- the value. The 30/31/32 boundary is deliberate -- precision 30 fitted the old
-- budget and 31 did not, once a sign or a decimal point had to fit beside the
-- digits. Rows carry the extremes of each column's domain rather than sample
-- values, because a truncation that loses the last character is invisible
-- unless the value reaches the last character.
CREATE TABLE dbo.ODBC_FDW_MONEY_MATRIX (
    ID int PRIMARY KEY,
    LABEL varchar(20),
    D1_0 decimal(1,0),
    D9_2 decimal(9,2),
    D15_2 decimal(15,2),
    D18_4 decimal(18,4),
    D19_4 decimal(19,4),
    D28_6 decimal(28,6),
    D30_0 decimal(30,0),
    D31_0 decimal(31,0),
    D32_0 decimal(32,0),
    D34_2 decimal(34,2),
    D38_0 decimal(38,0),
    D38_2 decimal(38,2)
);
INSERT INTO dbo.ODBC_FDW_MONEY_MATRIX VALUES
    (1, 'max_positive',
     9, 9999999.99, 9999999999999.99, 99999999999999.9999, 999999999999999.9999, 9999999999999999999999.999999, 999999999999999999999999999999, 9999999999999999999999999999999, 99999999999999999999999999999999, 99999999999999999999999999999999.99, 99999999999999999999999999999999999999, 999999999999999999999999999999999999.99);
INSERT INTO dbo.ODBC_FDW_MONEY_MATRIX VALUES
    (2, 'max_negative',
     -9, -9999999.99, -9999999999999.99, -99999999999999.9999, -999999999999999.9999, -9999999999999999999999.999999, -999999999999999999999999999999, -9999999999999999999999999999999, -99999999999999999999999999999999, -99999999999999999999999999999999.99, -99999999999999999999999999999999999999, -999999999999999999999999999999999999.99);
INSERT INTO dbo.ODBC_FDW_MONEY_MATRIX VALUES
    (3, 'smallest_unit',
     1, 0.01, 0.01, 0.0001, 0.0001, 0.000001, 1, 1, 1, 0.01, 1, 0.01);
INSERT INTO dbo.ODBC_FDW_MONEY_MATRIX VALUES
    (4, 'zero',
     0, 0.00, 0.00, 0.0000, 0.0000, 0.000000, 0, 0, 0, 0.00, 0, 0.00);
INSERT INTO dbo.ODBC_FDW_MONEY_MATRIX VALUES
    (5, 'typical',
     1, 1234.56, 1234.56, 1234.5678, 1234.5678, 1234.567890, 1234, 1234, 1234, 1234.56, 1234, 1234.56);
INSERT INTO dbo.ODBC_FDW_MONEY_MATRIX VALUES
    (6, 'nulls', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- Writing systems, spanning the Unicode planes and the properties that break a
-- naive UTF-16 to UTF-8 conversion: multi-byte BMP characters, surrogate pairs,
-- combining marks, right-to-left text, and zero-width joiner sequences.
--
-- Every literal is assembled from code units on the server. The seed executor
-- uses the ANSI ODBC entry point, so a non-ASCII literal written into this file
-- would be stored double encoded and the fixture rather than the read path
-- would be what the suite measures.
CREATE TABLE dbo.ODBC_FDW_CHARSET_MATRIX (
    ID int PRIMARY KEY,
    SCRIPT_NAME varchar(20),
    VALUE nvarchar(100)
);
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (1, 'ascii',
     NCHAR(0x0041)+NCHAR(0x0042)+NCHAR(0x0043)+NCHAR(0x0031)+
     NCHAR(0x0032)+NCHAR(0x0021));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (2, 'latin1',
     NCHAR(0x0063)+NCHAR(0x0061)+NCHAR(0x0066)+NCHAR(0x00E9)+
     NCHAR(0x0020)+NCHAR(0x00DC)+NCHAR(0x00DF)+NCHAR(0x00F1));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (3, 'latin_ext',
     NCHAR(0x010C)+NCHAR(0x0159)+NCHAR(0x0151)+NCHAR(0x017E)+
     NCHAR(0x0142)+NCHAR(0x1EB9));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (4, 'greek',
     NCHAR(0x0395)+NCHAR(0x03BB)+NCHAR(0x03BB)+NCHAR(0x03AC)+
     NCHAR(0x03B4)+NCHAR(0x03B1));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (5, 'cyrillic',
     NCHAR(0x041F)+NCHAR(0x0440)+NCHAR(0x0438)+NCHAR(0x0432)+
     NCHAR(0x0435)+NCHAR(0x0442));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (6, 'armenian',
     NCHAR(0x0531)+NCHAR(0x0561)+NCHAR(0x0575)+NCHAR(0x0565)+
     NCHAR(0x0580));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (7, 'hebrew',
     NCHAR(0x05E9)+NCHAR(0x05DC)+NCHAR(0x05D5)+NCHAR(0x05DD));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (8, 'arabic',
     NCHAR(0x0645)+NCHAR(0x0631)+NCHAR(0x062D)+NCHAR(0x0628)+
     NCHAR(0x0627));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (9, 'syriac',
     NCHAR(0x0724)+NCHAR(0x0720)+NCHAR(0x072B)+NCHAR(0x0710));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (10, 'thaana',
     NCHAR(0x078B)+NCHAR(0x07A8)+NCHAR(0x0788)+NCHAR(0x07AC)+
     NCHAR(0x0780)+NCHAR(0x07A8));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (11, 'nko',
     NCHAR(0x07D2)+NCHAR(0x07DE)+NCHAR(0x07CF));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (12, 'devanagari',
     NCHAR(0x0928)+NCHAR(0x092E)+NCHAR(0x0938)+NCHAR(0x094D)+
     NCHAR(0x0924)+NCHAR(0x0947));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (13, 'bengali',
     NCHAR(0x09B9)+NCHAR(0x09CD)+NCHAR(0x09AF)+NCHAR(0x09BE)+
     NCHAR(0x09B2)+NCHAR(0x09CB));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (14, 'gurmukhi',
     NCHAR(0x0A38)+NCHAR(0x0A24)+NCHAR(0x0A3F)+NCHAR(0x0A38)+
     NCHAR(0x0A4D)+NCHAR(0x0A30)+NCHAR(0x0A40));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (15, 'tamil',
     NCHAR(0x0BB5)+NCHAR(0x0BA3)+NCHAR(0x0BBF)+NCHAR(0x0B95)+
     NCHAR(0x0BCD)+NCHAR(0x0B95)+NCHAR(0x0BAE)+NCHAR(0x0BCD));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (16, 'telugu',
     NCHAR(0x0C28)+NCHAR(0x0C2E)+NCHAR(0x0C38)+NCHAR(0x0C4D)+
     NCHAR(0x0C15)+NCHAR(0x0C3E)+NCHAR(0x0C30)+NCHAR(0x0C02));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (17, 'sinhala',
     NCHAR(0x0DC1)+NCHAR(0x0DCA)+NCHAR(0x0DBB)+NCHAR(0x0DD3));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (18, 'thai',
     NCHAR(0x0E2A)+NCHAR(0x0E27)+NCHAR(0x0E31)+NCHAR(0x0E2A)+
     NCHAR(0x0E14)+NCHAR(0x0E35));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (19, 'lao',
     NCHAR(0x0EAA)+NCHAR(0x0EB0)+NCHAR(0x0E9A)+NCHAR(0x0EB2)+
     NCHAR(0x0E8D)+NCHAR(0x0E94)+NCHAR(0x0EB5));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (20, 'tibetan',
     NCHAR(0x0F56)+NCHAR(0x0F0B)+NCHAR(0x0F51)+NCHAR(0x0F7A));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (21, 'myanmar',
     NCHAR(0x1019)+NCHAR(0x1004)+NCHAR(0x103A)+NCHAR(0x1039)+
     NCHAR(0x1002)+NCHAR(0x101C)+NCHAR(0x102C));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (22, 'georgian',
     NCHAR(0x10D2)+NCHAR(0x10D0)+NCHAR(0x10DB)+NCHAR(0x10D0)+
     NCHAR(0x10E0)+NCHAR(0x10EF));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (23, 'ethiopic',
     NCHAR(0x1230)+NCHAR(0x120B)+NCHAR(0x121D));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (24, 'cherokee',
     NCHAR(0x13E3)+NCHAR(0x13B3)+NCHAR(0x13A9));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (25, 'khmer',
     NCHAR(0x1787)+NCHAR(0x1798)+NCHAR(0x179A)+NCHAR(0x17B6)+
     NCHAR(0x1796)+NCHAR(0x179F)+NCHAR(0x17BC)+NCHAR(0x179A));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (26, 'mongolian',
     NCHAR(0x1820)+NCHAR(0x1837)+NCHAR(0x1822)+NCHAR(0x1828));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (27, 'hiragana',
     NCHAR(0x3053)+NCHAR(0x3093)+NCHAR(0x306B)+NCHAR(0x3061)+
     NCHAR(0x306F));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (28, 'katakana',
     NCHAR(0x30AB)+NCHAR(0x30BF)+NCHAR(0x30AB)+NCHAR(0x30CA));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (29, 'han',
     NCHAR(0x5317)+NCHAR(0x4EAC)+NCHAR(0x6771)+NCHAR(0x4EAC));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (30, 'hangul',
     NCHAR(0xC548)+NCHAR(0xB155)+NCHAR(0xD558)+NCHAR(0xC138)+
     NCHAR(0xC694));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (31, 'tifinagh',
     NCHAR(0x2D5C)+NCHAR(0x2D30)+NCHAR(0x2D62));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (32, 'vai',
     NCHAR(0xA500)+NCHAR(0xA50B)+NCHAR(0xA521));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (33, 'combining',
     NCHAR(0x0065)+NCHAR(0x0301)+NCHAR(0x1ECD)+NCHAR(0x0300));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (34, 'rtl_mixed',
     NCHAR(0x0627)+NCHAR(0x0644)+NCHAR(0x0639)+NCHAR(0x0020)+
     NCHAR(0x0041)+NCHAR(0x0042)+NCHAR(0x0043));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (35, 'supp_emoji',
     NCHAR(0xD83D)+NCHAR(0xDE00)+NCHAR(0xD83D)+NCHAR(0xDE80));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (36, 'supp_music',
     NCHAR(0xD834)+NCHAR(0xDD1E)+NCHAR(0xD834)+NCHAR(0xDD22));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (37, 'supp_cjk_ext',
     NCHAR(0xD842)+NCHAR(0xDFB7)+NCHAR(0xD869)+NCHAR(0xDEB2));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (38, 'supp_adlam',
     NCHAR(0xD83A)+NCHAR(0xDD00)+NCHAR(0xD83A)+NCHAR(0xDD21));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (39, 'emoji_zwj',
     NCHAR(0xD83D)+NCHAR(0xDC69)+NCHAR(0x200D)+
     NCHAR(0xD83D)+NCHAR(0xDCBB));
INSERT INTO dbo.ODBC_FDW_CHARSET_MATRIX VALUES (40, 'emoji_skin',
     NCHAR(0xD83D)+NCHAR(0xDC4D)+NCHAR(0xD83C)+NCHAR(0xDFFD));
