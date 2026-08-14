DROP TABLE IF EXISTS dbo.ODBC_FDW_WIDE_DECIMAL;
DROP TABLE IF EXISTS dbo.ODBC_FDW_WIDE_DECIMAL_S0;
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
