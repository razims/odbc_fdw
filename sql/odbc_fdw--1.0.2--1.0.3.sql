/* odbc_fdw 1.0.2 -> 1.0.3
 *
 * Copyright (c) 2011, PostgreSQL Global Development Group
 * Copyright (c) 2016-2020 CARTO
 * Copyright (c) 2026, Softinent
 *
 * Version 1.0.3 changes only the C library: how a result column's buffer is
 * sized, what happens when a driver truncates a value it will not finish
 * delivering, and which C type ODBC wide character types are retrieved
 * through. No function, type or catalog object changes.
 *
 * This file is therefore intentionally empty of statements, and is present
 * rather than omitted so that ALTER EXTENSION odbc_fdw UPDATE TO '1.0.3' has a
 * path. Without one the only route forward is DROP EXTENSION, which cascades
 * to every foreign table and dependent view in the database.
 */
