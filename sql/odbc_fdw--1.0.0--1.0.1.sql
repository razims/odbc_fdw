/* odbc_fdw 1.0.0 -> 1.0.1
 *
 * Copyright (c) 2011, PostgreSQL Global Development Group
 * Copyright (c) 2016-2020 CARTO
 * Copyright (c) 2026, Softinent
 *
 * Restrict the three metadata helpers on existing installations. The 1.0.1
 * base script applies the same policy for fresh installations; this upgrade
 * path ensures ALTER EXTENSION does not leave 1.0.0's PUBLIC grants behind.
 */

REVOKE ALL ON FUNCTION ODBCTablesList(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ODBCTableSize(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ODBCQuerySize(text, text) FROM PUBLIC;
