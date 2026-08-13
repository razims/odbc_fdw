DROP TABLE "@SCHEMA@"."ODBC_FDW_BULK";

-- Optional bulk fixture, seeded only when HANA_BULK_ROWS is set.
--
-- The DROP is deliberately the FIRST thing in this file, with no comment above
-- it: hana-exec only tolerates a failing statement when the text it is handed
-- begins with "DROP TABLE ", and a leading comment block makes it begin with
-- "--" instead. On a schema that has never had this fixture, the drop fails
-- with 42S02 and the seed aborts.
--
-- Kept out of seed-hana.sql because it is the one fixture whose size is a
-- decision rather than a constant, and because a million rows is a different
-- kind of thing to leave lying in somebody's schema than the handful of rows
-- every other fixture uses.
CREATE COLUMN TABLE "@SCHEMA@"."ODBC_FDW_BULK" (
    "ID"    INTEGER PRIMARY KEY,
    "LABEL" NVARCHAR(32)
);

-- SERIES_GENERATE_INTEGER(increment, start, end) is half-open at the end, so
-- @ROWS@ + 1 yields exactly @ROWS@ rows numbered 1..@ROWS@. That numbering is
-- what makes sum("ID") a checksum the probe can predict: n(n+1)/2.
INSERT INTO "@SCHEMA@"."ODBC_FDW_BULK"
SELECT "ELEMENT_NUMBER", 'row-' || "ELEMENT_NUMBER"
FROM SERIES_GENERATE_INTEGER(1, 1, @ROWS@ + 1);
