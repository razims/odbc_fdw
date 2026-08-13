/*----------------------------------------------------------
 *
 *        Foreign-data wrapper registration entry point.
 *
 * Copyright (c) 2011, PostgreSQL Global Development Group
 * Copyright (c) 2026, Softinent
 *
 * This software is released under the PostgreSQL Licence.
 *
 * Author: Zheng Yang <zhengyang4k@gmail.com>
 * Updated to 9.2+ by Gunnar "Nick" Bluth <nick@pro-open.de>
 *   based on tds_fdw code from Geoff Montee
 *
 *----------------------------------------------------------
 */

#include "odbc_fdw.h"

PG_MODULE_MAGIC;

PGDLLEXPORT Datum odbc_fdw_handler(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum odbc_fdw_validator(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum odbc_tables_list(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum odbc_table_size(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum odbc_query_size(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(odbc_fdw_handler);
PG_FUNCTION_INFO_V1(odbc_fdw_validator);
PG_FUNCTION_INFO_V1(odbc_tables_list);
PG_FUNCTION_INFO_V1(odbc_table_size);
PG_FUNCTION_INFO_V1(odbc_query_size);

Datum
odbc_fdw_handler(PG_FUNCTION_ARGS)
{
	FdwRoutine *fdwroutine = makeNode(FdwRoutine);

	fdwroutine->GetForeignRelSize = odbcGetForeignRelSize;
	fdwroutine->GetForeignPaths = odbcGetForeignPaths;
	fdwroutine->AnalyzeForeignTable = odbcAnalyzeForeignTable;
	fdwroutine->GetForeignPlan = odbcGetForeignPlan;
	fdwroutine->ExplainForeignScan = odbcExplainForeignScan;
	fdwroutine->BeginForeignScan = odbcBeginForeignScan;
	fdwroutine->IterateForeignScan = odbcIterateForeignScan;
	fdwroutine->ReScanForeignScan = odbcReScanForeignScan;
	fdwroutine->EndForeignScan = odbcEndForeignScan;
	fdwroutine->ImportForeignSchema = odbcImportForeignSchema;

	PG_RETURN_POINTER(fdwroutine);
}
