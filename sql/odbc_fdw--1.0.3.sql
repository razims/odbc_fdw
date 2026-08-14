/*-------------------------------------------------------------------------
 *
 *                foreign-data wrapper for ODBC
 *
 * Copyright (c) 2011, PostgreSQL Global Development Group
 * Copyright (c) 2016-2020 CARTO
 * Copyright (c) 2026, Softinent
 *
 * This software is released under the PostgreSQL Licence
 *
 * Original author: Zheng Yang <zhengyang4k@gmail.com>
 *
 * IDENTIFICATION
 *                odbc_fdw/sql/odbc_fdw--1.0.2.sql
 *
 *-------------------------------------------------------------------------
 */

CREATE FUNCTION odbc_fdw_handler()
RETURNS fdw_handler
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION odbc_fdw_validator(text[], oid)
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FOREIGN DATA WRAPPER odbc_fdw
  HANDLER odbc_fdw_handler
  VALIDATOR odbc_fdw_validator;

CREATE TYPE __tabledata AS (schema text, name text);

CREATE FUNCTION ODBCTablesList(text, integer DEFAULT 0) RETURNS SETOF __tabledata
AS 'MODULE_PATHNAME', 'odbc_tables_list'
LANGUAGE C STRICT;

CREATE FUNCTION ODBCTableSize(text, text) RETURNS INTEGER
AS 'MODULE_PATHNAME', 'odbc_table_size'
LANGUAGE C STRICT;

CREATE FUNCTION ODBCQuerySize(text, text) RETURNS INTEGER
AS 'MODULE_PATHNAME', 'odbc_query_size'
LANGUAGE C STRICT;

/* These functions open remote connections and must be granted deliberately. */
REVOKE ALL ON FUNCTION ODBCTablesList(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION ODBCTableSize(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ODBCQuerySize(text, text) FROM PUBLIC;
