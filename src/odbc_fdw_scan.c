/*----------------------------------------------------------
 *
 *        Foreign scan execution and result retrieval.
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
static GetDataTruncation
result_truncation(SQLRETURN ret, SQLHSTMT stmt)
{
	SQLCHAR sqlstate[ODBC_SQLSTATE_LENGTH + 1] = {0};
	GetDataTruncation truncation = NO_TRUNCATION;
	if (ret == SQL_SUCCESS_WITH_INFO)
	{
		SQLRETURN diag_ret;

		diag_ret = SQLGetDiagRec(SQL_HANDLE_STMT, stmt, 1, sqlstate,
		                         NULL, NULL, 0, NULL);
		if (!SQL_SUCCEEDED(diag_ret))
			ereport(ERROR,
			        (errcode(ERRCODE_FDW_ERROR),
			         errmsg("ODBC driver returned success with info but no diagnostic record")));
		if (strncmp((char*)sqlstate, ODBC_SQLSTATE_STRING_TRUNCATION, ODBC_SQLSTATE_LENGTH) == 0 || strncmp((char*)sqlstate, ODBC_SQLSTATE_BQ_TRUNCATION, ODBC_SQLSTATE_LENGTH) == 0)
		{
			truncation = STRING_TRUNCATION;
		}
		else if (strncmp((char*)sqlstate, ODBC_SQLSTATE_FRACTIONAL_TRUNCATION, ODBC_SQLSTATE_LENGTH) == 0)
		{
			truncation = FRACTIONAL_TRUNCATION;
		}
	}
	return truncation;
}

/*
 * Enforce max_result_size: the total field bytes one scan may retrieve.
 *
 * max_field_size bounds ONE value and max_row_count bounds the number of rows,
 * and a result set can sit comfortably inside both while being unbounded in
 * aggregate -- 200 columns of 1KB across 10,000,000 rows violates neither. This
 * is the ceiling on the product.
 *
 * done_bytes is what completed fields have already cost, field_bytes is the
 * current field, and the comparison is written as a SUBTRACTION rather than as
 * `done + field > max` deliberately: max_result_size is any non-negative int64
 * an operator cares to type, and the invariant this function maintains is
 * done_bytes <= max_result_size, so `max - done` is non-negative and the sum on
 * the other side of the inequality is the one that could overflow.
 *
 * Called from two places for the same reason max_field_size is: once inside the
 * chunk loop, where field_bytes is what has been assembled so far, so a runaway
 * scan is refused while its last field is still being read rather than after;
 * and once when a field's real length is known, which is the exact test. The
 * message is the same in both, and says "at least", because in the first case
 * the amount is a lower bound.
 */
static void
check_result_size(int64 max_result_size, int64 done_bytes, int field_bytes)
{
	if (max_result_size > 0 && (int64) field_bytes > max_result_size - done_bytes)
		ereport(ERROR,
		        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
		         errmsg("odbc_fdw: scan has retrieved at least " INT64_FORMAT " bytes, exceeding max_result_size of " INT64_FORMAT,
		                done_bytes + (int64) field_bytes, max_result_size),
		         errhint("Raise or remove the \"max_result_size\" option on the foreign table or server.")));
}

/*
 * used_size + chunk_size, refusing any extent that cannot be a valid buffer.
 *
 * The addition itself is the hazard. used_buffer_size and chunk_size are both
 * int, and chunk_size is recomputed from a driver-supplied SQLLEN on every
 * truncation, so a sufficiently large or simply wrong value made the sum wrap
 * NEGATIVE. resize_buffer then compared a negative required_size against the
 * current size, found nothing to do, and returned without growing anything --
 * after which SQLGetData was handed `buffer + used_buffer_size` and told it
 * had chunk_size bytes to write into an allocation that had never been
 * extended. That is a heap overflow reached from a value the remote controls.
 *
 * Checked rather than clamped on purpose: a wrapped extent means the length
 * arithmetic has already gone wrong, and silently reading a different amount
 * than the driver was asked for would turn a detectable fault into a wrong
 * answer. See also MAXIMUM_FIELD_EXTENT below for the ceiling on the result.
 */
static int
checked_buffer_extent(int used_size, int chunk_size)
{
	if (chunk_size <= 0)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("odbc_fdw: invalid read chunk size %d", chunk_size),
		         errdetail("The ODBC driver reported a length that produced a non-positive chunk size.")));
	if (used_size < 0)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("odbc_fdw: invalid accumulated field size %d", used_size)));
	if (used_size > PG_INT32_MAX - chunk_size)
		ereport(ERROR,
		        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
		         errmsg("odbc_fdw: field value too large to buffer"),
		         errdetail("Reading %d more bytes onto %d already buffered would overflow the buffer extent.",
		                   chunk_size, used_size)));
	return used_size + chunk_size;
}

static void
resize_buffer(char ** buffer, int *size, int used_size, int required_size)
{
	/*
	 * Refuse impossible geometry instead of allocating from it. Every caller
	 * computes required_size from a driver-reported length, and this function
	 * used to trust it completely: a required_size <= 0 silently did nothing
	 * (leaving the caller to write into a buffer it believed had been grown),
	 * and a used_size larger than required_size would memmove more bytes than
	 * the new allocation can hold.
	 */
	if (used_size < 0 || required_size <= 0 || used_size > required_size)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("odbc_fdw: invalid buffer geometry"),
		         errdetail("used_size=%d required_size=%d", used_size, required_size)));

	if (required_size > *size)
	{
		int new_size = (*size > 0) ? *size : 1024;

		/* Geometric growth keeps chunked LOB reads linear in the value size. */
		while (new_size < required_size)
		{
			if (new_size > PG_INT32_MAX / 2)
			{
				new_size = required_size;
				break;
			}
			new_size *= 2;
		}

		if (*buffer == NULL)
			*buffer = (char *) palloc(new_size);
		else
			*buffer = (char *) repalloc(*buffer, new_size);
		*size = new_size;
	}
}

/* Prefer exact identifier matches; use case folding only when unambiguous. */
static int
find_table_column(StringInfoData *table_columns, int num_columns,
				  const char *result_name)
{
	int exact = -1;
	int folded = -1;
	int folded_count = 0;
	int i;

	for (i = 0; i < num_columns; i++)
	{
		if (table_columns[i].data == NULL)
			continue;
		if (strcmp(table_columns[i].data, result_name) == 0)
		{
			if (exact != -1)
				ereport(ERROR,
				        (errcode(ERRCODE_AMBIGUOUS_COLUMN),
				         errmsg("remote result column \"%s\" maps to multiple foreign table columns",
				                result_name)));
			exact = i;
		}
		else if (pg_strcasecmp(table_columns[i].data, result_name) == 0)
		{
			folded = i;
			folded_count++;
		}
	}

	if (exact != -1)
		return exact;
	if (folded_count == 1)
		return folded;
	if (folded_count > 1)
		ereport(ERROR,
		        (errcode(ERRCODE_AMBIGUOUS_COLUMN),
		         errmsg("remote result column \"%s\" has an ambiguous case-insensitive mapping",
		                result_name),
		         errhint("Add explicit column mappings whose remote names match exactly.")));
	return -1;
}

static const char * HEX_DIGITS = "0123456789ABCDEF";

static char * binary_to_hex(char * buffer, int buffer_size)
{
	int i;
	int hex_size;
	char * hex;

	/*
	 * buffer_size*2 is an int multiplication on a length that came from the
	 * driver, so anything above INT_MAX/2 wrapped negative and palloc was
	 * called with a negative size. Refused rather than clamped: half a value
	 * is not a value.
	 */
	if (buffer_size < 0 || buffer_size > (PG_INT32_MAX - 1) / 2)
		ereport(ERROR,
		        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
		         errmsg("odbc_fdw: binary value of %d bytes is too large to hex-encode", buffer_size)));

	hex_size = buffer_size*2;
	hex = (char *) palloc(hex_size + 1);
	hex[hex_size] = 0;
	for (i=0; i<buffer_size; i++)
	{
		unsigned char byte = buffer[i];
		hex[i*2] = HEX_DIGITS[(byte >> 4)];
		hex[i*2+1] = HEX_DIGITS[(byte & 0xF)];
	}
	return hex;
}

/*
 * get quals in the select if there is one
 */
static void
odbcGetQual(Node *node, TupleDesc tupdesc, List *col_mapping_list, char **key, char **value, bool *pushdown)
{
	ListCell *col_mapping;
	*key = NULL;
	*value = NULL;
	*pushdown = false;

	elog_debug("%s", __func__);

	if (!node)
		return;

	if (IsA(node, OpExpr))
	{
		OpExpr  *op = (OpExpr *) node;
		Node    *left, *right;
		Index   varattno;

		if (list_length(op->args) != 2)
			return;

		left = list_nth(op->args, 0);
		if (!IsA(left, Var))

			return;

		varattno = ((Var *) left)->varattno;

		right = list_nth(op->args, 1);

		if (IsA(right, Const))
		{
			Const *constant = (Const *) right;

			if (constant->constisnull)
				return;
			/* And get the column and value... */
			*key = NameStr(TupleDescAttr(tupdesc, varattno - 1)->attname);

			if (constant->consttype == PROCID_TEXTCONST)
				*value = TextDatumGetCString(constant->constvalue);
			else
			{
				return;
			}

			/* convert qual keys to mapped couchdb attribute name */
			foreach(col_mapping, col_mapping_list)
			{
				DefElem *def = (DefElem *) lfirst(col_mapping);
				if (strcmp(def->defname, *key) == 0)
				{
					*key = defGetString(def);
					break;
				}
			}

			/*
			 * We can push down this qual if:
			 * - The operatory is TEXTEQ
			 * - The qual is on the _id column (in addition, _rev column can be also valid)
			 */

			if (op->opfuncid == PROCID_TEXTEQ)
				*pushdown = true;

			return;
		}
	}
	return;
}

/*
 * Check if the provided option is one of the valid options.
 * context is the Oid of the catalog holding the object the option is for.
 */
void odbcGetForeignRelSize(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid)
{
	elog_debug("%s", __func__);

	/* Planning and plain EXPLAIN must never execute a remote query. */
	baserel->rows = 1000;
	baserel->tuples = baserel->rows;
}

void odbcEstimateCosts(PlannerInfo *root, RelOptInfo *baserel, Cost *startup_cost, Cost *total_cost, Oid foreigntableid)
{
	elog_debug("----> starting %s", __func__);

	*startup_cost = 25;

	*total_cost = baserel->rows + *startup_cost;

	elog_debug("----> finishing %s", __func__);

}

void odbcGetForeignPaths(PlannerInfo *root, RelOptInfo *baserel, Oid foreigntableid)
{
	Cost startup_cost;
	Cost total_cost;

	elog_debug("----> starting %s", __func__);

	odbcEstimateCosts(root, baserel, &startup_cost, &total_cost, foreigntableid);

	add_path(baserel,
	         (Path *) create_foreignscan_path(root, baserel,
#if PG_VERSION_NUM >= 90600
	                 NULL, /* PathTarget */
#endif
	                 baserel->rows,
#if PG_VERSION_NUM >= 180000
	                 0, /* disabled_nodes */
#endif
	                 startup_cost,
	                 total_cost,
	                 NIL, /* no pathkeys */
	                 NULL, /* no outer rel either */
	                 NULL, /* no extra plan */
#if PG_VERSION_NUM >= 170000
	                 NIL, /* no fdw_restrictinfo list */
#endif
	                 NIL /* no fdw_private list */));

	elog_debug("----> finishing %s", __func__);
}

bool odbcAnalyzeForeignTable(Relation relation, AcquireSampleRowsFunc *func, BlockNumber *totalpages)
{
	elog_debug("----> starting %s", __func__);
	elog_debug("----> finishing %s", __func__);

	return false;
}

ForeignScan *
odbcGetForeignPlan(PlannerInfo *root, RelOptInfo *baserel,
                                       Oid foreigntableid, ForeignPath *best_path, List *tlist, List *scan_clauses, Plan *outer_plan)
{
	Index scan_relid = baserel->relid;
	elog_debug("----> starting %s", __func__);

	scan_clauses = extract_actual_clauses(scan_clauses, false);

	elog_debug("----> finishing %s", __func__);

	return make_foreignscan(tlist, scan_clauses,
	                        scan_relid, NIL, NIL,
	                        NIL /* fdw_scan_tlist */, NIL, /* fdw_recheck_quals */
	                        NULL /* outer_plan */ );
}

/*
 * odbcBeginForeignScan
 *
 */
void
odbcBeginForeignScan(ForeignScanState *node, int eflags)
{
	SQLHENV env;
	SQLHDBC dbc;
	odbcFdwExecutionState   *festate;
	SQLSMALLINT result_columns;
	SQLHSTMT stmt;
	SQLRETURN ret;

#ifdef DEBUG
	char dsn[256];
	char desc[256];
	SQLSMALLINT dsn_ret;
	SQLSMALLINT desc_ret;
	SQLUSMALLINT direction;
#endif

	odbcFdwOptions options;

	Relation rel;
	int num_of_columns;
	int live_columns = 0;
	StringInfoData *columns;
	int i;
	ListCell *col_mapping;
	StringInfoData sql;
	StringInfoData col_str;
	StringInfoData name_qualifier_char;
	StringInfoData quote_char;

	char *qual_key         = NULL;
	char *qual_value       = NULL;
	bool pushdown          = false;

	const char* schema_name;
	int encoding = -1;

	elog_debug("%s", __func__);

	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
	{
		node->fdw_state = NULL;
		return;
	}

	/* Fetch the foreign table options */
	odbcGetTableOptions(RelationGetRelid(node->ss.ss_currentRelation), &options);

	schema_name = get_schema_name(&options);

	odbc_connection(&options, &env, &dbc);

	/* Get quote char */
	getQuoteChar(dbc, &quote_char);

	/* Get name qualifier char */
	getNameQualifierChar(dbc, &name_qualifier_char);

	if (!is_blank_string(options.encoding))
	{
		encoding = pg_char_to_encoding(options.encoding);
		if (encoding < 0)
		{
			ereport(ERROR,
			        (errcode(ERRCODE_FDW_INVALID_ATTRIBUTE_VALUE),
			         errmsg("invalid encoding name \"%s\"", options.encoding)
			        ));
		}
	}

	/* Fetch the table column info */
	rel = table_open(RelationGetRelid(node->ss.ss_currentRelation), AccessShareLock);
	num_of_columns = rel->rd_att->natts;
	columns = (StringInfoData *) palloc0(sizeof(StringInfoData) * num_of_columns);
	initStringInfo(&col_str);
	for (i = 0; i < num_of_columns; i++)
	{
		StringInfoData col;
		StringInfoData mapping;
		bool    mapped;
		char *escaped_column;

		if (TupleDescAttr(rel->rd_att, i)->attisdropped)
			continue;

		/* retrieve the column name */
		initStringInfo(&col);
		appendStringInfo(&col, "%s", NameStr(TupleDescAttr(rel->rd_att,i)->attname));
		mapped = false;

		/* check if the column name is mapping to a different name in remote table */
		foreach(col_mapping, options.mapping_list)
		{
			DefElem *def = (DefElem *) lfirst(col_mapping);
			if (strcmp(def->defname, col.data) == 0)
			{
				initStringInfo(&mapping);
				appendStringInfo(&mapping, "%s", defGetString(def));
				mapped = true;
				break;
			}
		}

		/* decide which name is going to be used */
		if (mapped)
			columns[i] = mapping;
		else
			columns[i] = col;

		escaped_column = escape_sql_identifier_part(columns[i].data,
		                                             quote_char.data);
		appendStringInfo(&col_str, live_columns == 0 ? "%s%s%s" : ",%s%s%s",
		                 (char *) quote_char.data, escaped_column,
		                 (char *) quote_char.data);
		live_columns++;
	}
	table_close(rel, NoLock);
	if (live_columns == 0)
		ereport(ERROR,
		        (errcode(ERRCODE_FDW_ERROR),
		         errmsg("foreign table has no non-dropped columns")));

	/* See if we've got a qual we can push down */
	if (node->ss.ps.plan->qual)
	{
#if PG_VERSION_NUM >= 100000
		ExprState  *state = node->ss.ps.qual;
		odbcGetQual((Node *) state->expr, node->ss.ss_currentRelation->rd_att, options.mapping_list, &qual_key, &qual_value, &pushdown);
#else
		ListCell    *lc;
		foreach (lc, node->ss.ps.qual)
		{
			/* Only the first qual can be pushed down to remote DBMS */
			ExprState  *state = lfirst(lc);
			odbcGetQual((Node *) state->expr, node->ss.ss_currentRelation->rd_att, options.mapping_list, &qual_key, &qual_value, &pushdown);
			if (pushdown)
				break;
		}
#endif
	}

	/* Construct the SQL statement used for remote querying */
	initStringInfo(&sql);
	if (!is_blank_string(options.sql_query))
	{
		/* Use custom query if it's available */
		pushdown = false;
		appendStringInfo(&sql, "%s", options.sql_query);
	}
	else
	{
		/* Get options.table */
		char *escaped_table = escape_sql_identifier_part(options.table, quote_char.data);

		if (is_blank_string(schema_name))
		{
			appendStringInfo(&sql, "SELECT %s FROM %s%s%s", col_str.data,
			                 (char *) quote_char.data, escaped_table, (char *) quote_char.data);
		}
		else
		{
			char *escaped_schema = escape_sql_identifier_part(schema_name, quote_char.data);

			appendStringInfo(&sql, "SELECT %s FROM %s%s%s%s%s%s%s", col_str.data,
			                 (char *) quote_char.data, escaped_schema, (char *) quote_char.data,
			                 (char *) name_qualifier_char.data,
			                 (char *) quote_char.data, escaped_table, (char *) quote_char.data);
		}
		if (pushdown)
		{
			char *escaped_key = escape_sql_identifier_part(qual_key, quote_char.data);

			appendStringInfo(&sql, " WHERE %s%s%s = ?",
			                 (char *) quote_char.data, escaped_key,
			                 (char *) quote_char.data);
		}
	}

	/* Allocate a statement handle. */
	odbc_allocate_statement(dbc, &stmt);

	festate = (odbcFdwExecutionState *) palloc0(sizeof(odbcFdwExecutionState));
	if (pushdown)
	{
		SQLULEN parameter_size;

		festate->param_value = pstrdup(qual_value);
		festate->param_value_len = (SQLLEN) strlen(festate->param_value);
		parameter_size = (festate->param_value_len > 0) ?
			(SQLULEN) festate->param_value_len : 1;
		ret = SQLBindParameter(stmt, 1, SQL_PARAM_INPUT, SQL_C_CHAR,
		                       SQL_VARCHAR, parameter_size, 0,
		                       festate->param_value,
		                       festate->param_value_len + 1,
		                       &festate->param_value_len);
		check_return(ret, "Binding ODBC query parameter", stmt,
		             SQL_HANDLE_STMT);
	}

	elog_debug("Executing query: %s", sql.data);

	/* Retrieve a list of rows */
	ret = SQLExecDirect(stmt, (SQLCHAR *) sql.data, SQL_NTS);
	check_return(ret, "Executing ODBC query", stmt, SQL_HANDLE_STMT);
	ret = SQLNumResultCols(stmt, &result_columns);
	check_return(ret, "Reading ODBC result column count", stmt,
	             SQL_HANDLE_STMT);

	festate->attinmeta = TupleDescGetAttInMetadata(node->ss.ss_currentRelation->rd_att);
	copy_odbcFdwOptions(&(festate->options), &options);
	festate->env = env;
	festate->dbc = dbc;
	festate->stmt = stmt;
	festate->table_columns = columns;
	festate->num_of_table_cols = num_of_columns;
	festate->num_of_result_cols = result_columns;
	/* prepare for the first iteration, there will be some precalculation needed in the first iteration*/
	festate->first_iteration = true;
	festate->encoding = encoding;
	festate->query = sql.data;
	node->fdw_state = (void *) festate;
}

/*
 * odbcIterateForeignScan
 *
 */
TupleTableSlot *
odbcIterateForeignScan(ForeignScanState *node)
{
	EState *executor_state = node->ss.ps.state;
	MemoryContext prev_context;
	/* ODBC API return status */
	SQLRETURN ret;
	SQLRETURN fetch_ret;
	odbcFdwExecutionState *festate = (odbcFdwExecutionState *) node->fdw_state;
	TupleTableSlot *slot = node->ss.ss_ScanTupleSlot;
	SQLSMALLINT columns;
	char    **values;
	HeapTuple   tuple;
	StringInfoData  col_data;
	SQLHSTMT stmt = festate->stmt;
	bool first_iteration = festate->first_iteration;
	int num_of_table_cols = festate->num_of_table_cols;
	int num_of_result_cols;
	StringInfoData  *table_columns = festate->table_columns;
	List *col_position_mask = NIL;
	List *col_size_array = NIL;
	List *col_conversion_array = NIL;

	elog_debug("%s", __func__);

	/*
	 * There is deliberately NO CHECK_FOR_INTERRUPTS() here, at the row
	 * boundary, because PostgreSQL already provides one: ExecScan checks
	 * interrupts once per tuple a scan node returns, and this FDW is only
	 * ever driven from there (odbcAnalyzeForeignTable returns false, so
	 * ANALYZE does not sample, and IterateForeignScan has no other caller).
	 *
	 * Measured with statement_timeout = 5s against a real SAP HANA 2.0
	 * tenant, on a 3,000,000-row remote scan, with no check in this function
	 * at all -- three shapes chosen to put the per-tuple loop in three
	 * different places: COPY of every row (many output tuples), count(*)
	 * (one output tuple), and a non-pushed-down qual matching nothing (zero
	 * output tuples). All three were cancelled at 5s. A check added here
	 * would be redundant, so it is not added.
	 *
	 * The gap is one level down, inside the chunked read; see the loop below.
	 */
	fetch_ret = SQLFetch(stmt);

	/*
	 * A FAILED fetch is not the end of the result set.
	 *
	 * This return was not examined at all. The only test applied to it was the
	 * SQL_SUCCEEDED guard further down, which decides whether to build a tuple
	 * -- so SQL_ERROR took exactly the same path as SQL_NO_DATA: an empty slot,
	 * which the executor reads as "this scan is finished". A connection dropped
	 * mid-scan, or a remote session killed by its administrator, therefore
	 * produced a SILENTLY TRUNCATED result set: no error anywhere, and the
	 * query committed whichever rows had arrived before the failure.
	 *
	 * SQL_NO_DATA is the legitimate end of the set and carries no diagnostic
	 * record, so it must NOT go to check_return -- which rejects anything that
	 * is not SQL_SUCCEEDED and would report a bare "Fetching row" at the end of
	 * every scan. Everything else is a real failure and gets the driver's own
	 * diagnostics.
	 */
	if (fetch_ret != SQL_NO_DATA)
		check_return(fetch_ret, "Fetching row", stmt, SQL_HANDLE_STMT);

	columns = (SQLSMALLINT) festate->num_of_result_cols;

	/*
	 * If this is the first iteration,
	 * we need to calculate the mask for column mapping as well as the column size
	 */
	if (first_iteration == true)
	{
		SQLCHAR *ColumnName;
		SQLSMALLINT NameLengthPtr;
		SQLSMALLINT DataTypePtr;
		SQLULEN     ColumnSizePtr;
		SQLSMALLINT DecimalDigitsPtr;
		SQLSMALLINT NullablePtr;
		int i;
		int mapped_pos;

		StringInfoData sql_type;

		/* Allocate memory for the masks in a memory context that
		   persists between IterateForeignScan calls */
		prev_context = MemoryContextSwitchTo(executor_state->es_query_cxt);
		col_position_mask = NIL;
		col_size_array = NIL;
		col_conversion_array = NIL;
		num_of_result_cols = columns;
		/* Once, not once per column: sql_data_type resets rather than inits. */
		initStringInfo(&sql_type);
		/* Obtain the column information of the first row. */
		for (i = 1; i <= columns; i++)
		{
			ColumnConversion conversion = TEXT_CONVERSION;
			ColumnName = (SQLCHAR *) palloc0(MAXIMUM_COLUMN_NAME_LEN + 1);
			ret = SQLDescribeCol(stmt,
			                     i,
			                     ColumnName,
			                     MAXIMUM_COLUMN_NAME_LEN + 1,
			                     &NameLengthPtr,
			                     &DataTypePtr,
			                     &ColumnSizePtr,
			                     &DecimalDigitsPtr,
			                     &NullablePtr);
			check_return(ret, "Describing ODBC result column", stmt,
			             SQL_HANDLE_STMT);
			if (NameLengthPtr > MAXIMUM_COLUMN_NAME_LEN)
				ereport(ERROR,
				        (errcode(ERRCODE_NAME_TOO_LONG),
				         errmsg("ODBC result column name exceeds %d bytes",
				                MAXIMUM_COLUMN_NAME_LEN)));

			sql_data_type(DataTypePtr, ColumnSizePtr, DecimalDigitsPtr, NullablePtr, &sql_type);
			if (strcmp("bytea", (char*)sql_type.data) == 0)
			{
				conversion = BIN_CONVERSION;
			}
			if (strcmp("boolean", (char*)sql_type.data) == 0)
			{
				conversion = BOOL_CONVERSION;
			}
			else if (strncmp("bit(",(char*)sql_type.data,4)==0 || strncmp("varbit(",(char*)sql_type.data,7)==0)
			{
				conversion = BIN_CONVERSION;
			}

			/* Get the position of the column in the FDW table. */
			mapped_pos = find_table_column(table_columns, num_of_table_cols,
			                               (char *) ColumnName);
			if (mapped_pos >= 0)
			{
				SQLULEN min_size = minimum_buffer_size(DataTypePtr);
				SQLULEN max_size = MAXIMUM_BUFFER_SIZE;

				col_position_mask = lappend_int(col_position_mask, mapped_pos);
				if (ColumnSizePtr < min_size)
					ColumnSizePtr = min_size;
				if (ColumnSizePtr > max_size)
					ColumnSizePtr = max_size;

				col_size_array = lappend_int(col_size_array,
				                                  (int) ColumnSizePtr);
				col_conversion_array = lappend_int(col_conversion_array,
				                                        (int) conversion);
			}
			/* if current column is not used by the foreign table */
			else
			{
				col_position_mask = lappend_int(col_position_mask, -1);
				col_size_array = lappend_int(col_size_array, -1);
				col_conversion_array = lappend_int(col_conversion_array, 0);
			}
			pfree(ColumnName);
		}
		festate->num_of_result_cols = num_of_result_cols;
		festate->col_position_mask = col_position_mask;
		festate->col_size_array = col_size_array;
		festate->col_conversion_array = col_conversion_array;
		festate->first_iteration = false;

		MemoryContextSwitchTo(prev_context);
	}
	else
	{
		num_of_result_cols = festate->num_of_result_cols;
		col_position_mask = festate->col_position_mask;
		col_size_array = festate->col_size_array;
		col_conversion_array = festate->col_conversion_array;
	}

	ExecClearTuple(slot);
	if (SQL_SUCCEEDED(fetch_ret))
	{
		SQLSMALLINT i;

		/*
		 * Enforce max_row_count before doing any work for this row.
		 *
		 * A remote that returns far more rows than expected is otherwise
		 * bounded only by the executor's willingness to keep asking, and every
		 * row costs a palloc'd values[] array and one buffer per column. This
		 * refuses rather than stopping quietly: silently returning the first N
		 * rows of a larger result would be a wrong answer, which is worse than
		 * no answer.
		 */
		festate->row_count++;
		if (festate->options.max_row_count > 0 &&
		    festate->row_count > festate->options.max_row_count)
			ereport(ERROR,
			        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
			         errmsg("odbc_fdw: scan returned more than " INT64_FORMAT " rows",
			                festate->options.max_row_count),
			         errhint("Raise or remove the \"max_row_count\" option on the foreign table or server.")));
		/*
		 * One slot per FOREIGN TABLE column, and ZEROED.
		 *
		 * Was palloc(sizeof(char *) * columns), which is wrong twice over.
		 * It was sized by the number of RESULT columns while every write
		 * below indexes it by mapped_pos, a position in the FOREIGN TABLE,
		 * and BuildTupleFromCStrings reads natts entries regardless -- so a
		 * table with more columns than the query returns overran the
		 * allocation. And palloc does not zero, while a result column that
		 * matches no table column is `continue`d over, leaving that slot
		 * uninitialised for BuildTupleFromCStrings to dereference as a C
		 * string.
		 *
		 * That single read of uninitialised heap is the entire measured
		 * symptom set against HANA: 'ABCDEFGH' arriving empty, SYS.TABLES
		 * schema names arriving as a stray \x03 and as blanks with the row
		 * COUNT still correct, 424242 failing with "invalid input syntax for
		 * integer", and an intermittent SIGSEGV that took the whole instance
		 * into crash recovery and appeared to depend on which HANA client
		 * libraries were installed -- because that changed the heap layout,
		 * not the bug. A zeroed slot is a SQL NULL, which is the honest
		 * answer for a column the remote query did not return.
		 */
		values = (char **) palloc0(sizeof(char *) * num_of_table_cols);

		/* Loop through the columns */
		for (i = 1; i <= columns; i++)
		{
			int mask_index = i - 1;
			int col_size = list_nth_int(col_size_array, mask_index);
			int mapped_pos = list_nth_int(col_position_mask, mask_index);
			ColumnConversion conversion = list_nth_int(col_conversion_array, mask_index);
			SQLSMALLINT target_type = SQL_C_CHAR;
			SQLLEN result_size;
			int chunk_size, effective_chunk_size;
			int buffer_size = 0;
			char * buffer = 0;
			char * hex;
			int used_buffer_size = 0;
			GetDataTruncation truncation;
			bool binary_data = false;
			if (conversion == BIN_CONVERSION)
			{
				target_type	= SQL_C_BINARY;
				binary_data = true;
			}

			if (col_size == 0)
			{
				col_size = 1024;
			}

			chunk_size = binary_data ? col_size : col_size + 1;

			/* Ignore this column if position is marked as invalid */
			if (mapped_pos == -1)
				continue;

			do // Loop for reading the field in chunks
			{
				/*
				 * Make a single enormous field cancellable.
				 *
				 * This loop is the one part of a scan that PostgreSQL's own
				 * per-tuple check cannot reach: a LOB arrives in
				 * MAXIMUM_BUFFER_SIZE chunks, so Iterate is entered ONCE for
				 * the row and stays here for the whole value. Measured against
				 * a real SAP HANA 2.0 tenant on a single row holding one
				 * 60,000,000-character NCLOB, with this check absent: the read
				 * took 9.94s unbounded, and a pg_cancel_backend() issued 2.01s
				 * in did not stop it for a further 11.15s -- that is, not until
				 * the entire field had been read. With the check present the
				 * same scan stops before the read completes.
				 *
				 * Safe HERE specifically. No ODBC call is outstanding at this
				 * point -- SQLGetData has returned and the next one has not
				 * been issued -- so no handle is mid-operation. `buffer` is
				 * palloc'd and the pfree at the tail of this function is
				 * skipped when we throw, but it belongs to the memory context
				 * of the query being cancelled and is released with it. What is
				 * abandoned is a partially-read field on a statement that is
				 * being discarded anyway, which is exactly the state
				 * check_return already leaves behind when the driver errors
				 * mid-field, a few lines below. So this takes an existing
				 * unwind path rather than creating one.
				 *
				 * What it does NOT do is interrupt the driver. A blocking call
				 * inside libodbcHDB has no interrupt callback, so if the driver
				 * materialises a large LOB inside one SQLGetData -- which the
				 * measured cancel latency above indicates it does -- the wait
				 * for that call still cannot be cancelled. This bounds the
				 * LOOP, not the driver, and the honest claim is a scan that
				 * stops early rather than one that stops promptly.
				 */
				CHECK_FOR_INTERRUPTS();
				/*
				 * Enforce max_field_size before growing the buffer again, so a
				 * runaway value is refused while it is still bounded by the
				 * ceiling plus one chunk rather than after the whole thing has
				 * been assembled in memory. used_buffer_size is 0 on the first
				 * pass, so a value that arrives in a single chunk is never
				 * rejected here -- the exact test is after the loop.
				 */
				if (festate->options.max_field_size > 0 &&
				    (int64) used_buffer_size > festate->options.max_field_size)
					ereport(ERROR,
					        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					         errmsg("odbc_fdw: field value exceeds max_field_size of " INT64_FORMAT " bytes",
					                festate->options.max_field_size),
					         errhint("Raise or remove the \"max_field_size\" option on the foreign table or server.")));
				/*
				 * And the same for the scan total, for the same reason: bound
				 * memory while this field is still being assembled rather than
				 * once it exists. result_bytes covers the fields already
				 * completed, used_buffer_size this one so far.
				 */
				check_result_size(festate->options.max_result_size,
				                  festate->result_bytes, used_buffer_size);
				resize_buffer(&buffer, &buffer_size, used_buffer_size,
				              checked_buffer_extent(used_buffer_size, chunk_size));
				ret = SQLGetData(stmt, i, target_type, buffer + used_buffer_size, chunk_size, &result_size);
				if (ret == SQL_NO_DATA)
				{
					/*
					 * The column is exhausted, which is not an error.
					 *
					 * ODBC guarantees that a value can be retrieved across
					 * SEVERAL SQLGetData calls only for character and binary
					 * source types. Any other type rendered to SQL_C_CHAR gets
					 * ONE call: the driver truncates, reports 01004 with the full
					 * length, and then has no continuation to give. Measured
					 * against SAP HANA, CURRENT_TIMESTAMP is exactly that -- a
					 * driver-reported column size of 27 against a 29-byte
					 * rendering:
					 *   chunk=28 ret=1 rsize=29 state=01004   (27 bytes copied)
					 *   chunk=3  ret=100                      (SQL_NO_DATA)
					 * The loop then fell through to check_return, which rejects
					 * SQL_NO_DATA because it is not SQL_SUCCEEDED, and every
					 * timestamp failed with a bare "Reading data" and no driver
					 * diagnostic -- SQL_NO_DATA carries no diagnostic record,
					 * which is what made the message so uninformative.
					 *
					 * What was already copied IS the value, so terminate it and
					 * stop. Terminating explicitly matters because the value is
					 * consumed below as a C string: were SQL_NO_DATA to arrive on
					 * the FIRST call, breaking without this would hand
					 * appendStringInfoString an uninitialised buffer.
					 */
					resize_buffer(&buffer, &buffer_size, used_buffer_size, used_buffer_size + 1);
					buffer[used_buffer_size] = 0;
					ret = SQL_SUCCESS;
					break;
				}
				/*
				 * How much of this chunk is DATA.
				 *
				 * Was:
				 *   effective_chunk_size = chunk_size;
				 *   if (!binary_data && buffer[used_buffer_size + chunk_size - 1] == 0)
				 *           effective_chunk_size--;
				 * which read the chunk's last byte without consulting `ret` and
				 * without regard for how many bytes SQLGetData actually wrote.
				 * For any value shorter than the chunk -- the normal case, and
				 * always so for a column whose declared width exceeds its
				 * contents -- that byte is uninitialised heap, so a control-flow
				 * decision depended on undefined memory.
				 *
				 * The test is also unnecessary. effective_chunk_size is read only
				 * on the truncation arms below, which are reached only when the
				 * driver really did fill the chunk, and SQL_C_CHAR output is
				 * always NUL-terminated -- so a truncated character chunk carries
				 * exactly chunk_size - 1 bytes of data. Binary data is not
				 * terminated and uses the whole chunk.
				 */
				effective_chunk_size = binary_data ? chunk_size : chunk_size - 1;
				truncation = result_truncation(ret, stmt);
				if (truncation == STRING_TRUNCATION)
				{
					if (result_size == SQL_NO_TOTAL)
					{
						// no info about remaining data size; keep reading with same chunk_size
						used_buffer_size += effective_chunk_size;
					}
					else
					{
						// we read chunk_size, but there was result_size pending in total;
						// adjust chunk_size for the remaining, so next wil hopely be the final chunk
						used_buffer_size += effective_chunk_size;
						/*
						 * result_size is a 64-bit SQLLEN and chunk_size is an
						 * int, so this cast could TRUNCATE. A driver reporting a
						 * total of 2^32 + 100 produced (int) 100, which then read
						 * 100 bytes, concluded the value was complete, and
						 * returned a silently truncated field -- and a total whose
						 * low 32 bits happened to be negative fell through to the
						 * extent arithmetic instead. Neither is a length this
						 * extension can honour: a value is built into a
						 * PostgreSQL datum, which cannot exceed 1GB anyway, so
						 * refuse rather than cast.
						 */
						if (result_size > (SQLLEN) PG_INT32_MAX)
							ereport(ERROR,
							        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
							         errmsg("odbc_fdw: field value too large to buffer"),
							         errdetail("The ODBC driver reported a total length of " INT64_FORMAT " bytes.",
							                   (int64) result_size)));
						// note that we need to read result_size - effective_chunk_size more data bytes,
						chunk_size = (int)result_size - effective_chunk_size;
						// wait, maybe we don't need to read, just append a zero!
						if (chunk_size == 0)
						{
							if (!binary_data)
							{
								/*
								 * Writes at used_buffer_size - 1, so it needs at
								 * least one byte already buffered. Guarded because
								 * a driver reporting a total equal to what it had
								 * already delivered while delivering nothing would
								 * otherwise write buffer[-1].
								 */
								if (used_buffer_size < 1)
									ereport(ERROR,
									        (errcode(ERRCODE_FDW_ERROR),
									         errmsg("odbc_fdw: ODBC driver reported a complete value having returned no data")));
								resize_buffer(&buffer, &buffer_size, used_buffer_size, used_buffer_size + 1);
								buffer[used_buffer_size - 1] = 0;
							}
							break;
						}
						if (!binary_data)
						{
							chunk_size += 1;
						}
					}
				}
				else if (truncation == FRACTIONAL_TRUNCATION)
				{
					/* Fractional truncation has occurred;
					* at this point we cannot obtain the lost digits
					*/
					used_buffer_size += effective_chunk_size;
					if (chunk_size == effective_chunk_size)
					{
						/* The driver has omitted the trailing zero */
						resize_buffer(&buffer, &buffer_size, used_buffer_size, used_buffer_size + 1);
						buffer[used_buffer_size] = 0;
					}
					elog_debug("Truncating number: %s", buffer);
				}
				else // NO_TRUNCATION: finish reading
				{
					/*
					 * result_size is an INDICATOR, not always a length:
					 * SQL_NULL_DATA (-1) for a NULL value, SQL_NO_TOTAL (-4)
					 * when the driver will not say. Adding it unchecked drove
					 * used_buffer_size NEGATIVE, and the
					 * strnlen(buffer, used_buffer_size) below then ran with a
					 * (size_t)-1 bound -- an out-of-bounds scan on every NULL
					 * value, which the SQL_NULL_DATA test further down was too
					 * late to prevent. Clamping to chunk_size keeps the total
					 * within what resize_buffer just guaranteed, so a driver
					 * over-reporting a length cannot walk off the end either.
					 */
					if (result_size > 0)
						used_buffer_size += (result_size > chunk_size)
						                    ? chunk_size : (int) result_size;
				}
			} while (truncation == STRING_TRUNCATION && chunk_size > 0);

			if (!binary_data)
			{
				used_buffer_size = strnlen(buffer, used_buffer_size);
			}

			/*
			 * The exact max_field_size test, on the value's real length. The
			 * in-loop check above bounds MEMORY while the value is still being
			 * assembled, but it cannot be exact: it runs before each chunk, so
			 * a value delivered in one chunk never reaches it. Both are needed
			 * -- without this one a max_field_size smaller than a single chunk
			 * would not be enforced at all.
			 */
			if (festate->options.max_field_size > 0 &&
			    (int64) used_buffer_size > festate->options.max_field_size)
				ereport(ERROR,
				        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				         errmsg("odbc_fdw: field value of %d bytes exceeds max_field_size of " INT64_FORMAT,
				                used_buffer_size, festate->options.max_field_size),
				         errhint("Raise or remove the \"max_field_size\" option on the foreign table or server.")));

			/*
			 * The exact max_result_size test, on this field's real length, then
			 * charge it to the scan. Checked BEFORE adding so that the running
			 * total never exceeds the ceiling, which is the invariant
			 * check_result_size' subtraction relies on to be overflow-free.
			 *
			 * used_buffer_size is what this extension retrieved into its own
			 * buffer. It is not the tuple's footprint: a BIN_CONVERSION column
			 * is hex-encoded to twice this, and the StringInfo and the heap
			 * tuple are further copies. So this ceiling bounds the retrieval,
			 * and the backend's actual high-water mark is a multiple of it.
			 */
			check_result_size(festate->options.max_result_size,
			                  festate->result_bytes, used_buffer_size);
			festate->result_bytes += (int64) used_buffer_size;

			if (ret != SQL_SUCCESS_WITH_INFO)
			{
				// TODO: review check_result behaviour for SQL_SUCCESS_WITH_INFO (it should not fail right?)
				check_return(ret, "Reading data", stmt, SQL_HANDLE_STMT);
			}

			if (SQL_SUCCEEDED(ret))
			{
				/* Handle null columns */
				if (result_size == SQL_NULL_DATA)
				{
					// BuildTupleFromCStrings expects NULLs to be NULL pointers
					values[mapped_pos] = NULL;
				}
				else
				{
					if (festate->encoding != -1 && !binary_data)
					{
						/* Convert character encoding */
						buffer = pg_any_to_server(buffer, used_buffer_size, festate->encoding);
					}
					initStringInfo(&col_data);
					switch (conversion)
					{
					case TEXT_CONVERSION :
						appendStringInfoString (&col_data, buffer);
						break;
					case BOOL_CONVERSION :
						if (buffer[0] == 0)
							strcpy(buffer, "F");
						else if (buffer[0] == 1)
							strcpy(buffer, "T");
						appendStringInfoString (&col_data, buffer);
						break;
					case BIN_CONVERSION :
						/* TODO: avoid hex conversion by building the tuple from Datum values instead of using BuildTupleFromCStrings */
						hex = binary_to_hex(buffer, used_buffer_size);
						appendStringInfoString (&col_data, "\\x");
						appendStringInfoString (&col_data, hex);
						pfree(hex);
						break;
					}

					values[mapped_pos] = col_data.data;
				}
			}
			pfree(buffer);
		}

		tuple = BuildTupleFromCStrings(festate->attinmeta, values);
#if PG_VERSION_NUM < 120000
		ExecStoreTuple(tuple, slot, InvalidBuffer, false);
#else
		ExecStoreHeapTuple(tuple, slot, false);
#endif
		pfree(values);
	}

	return slot;
}

/*
 * odbcExplainForeignScan
 *
 */
void
odbcExplainForeignScan(ForeignScanState *node, ExplainState *es)
{
	odbcFdwExecutionState *festate;

	elog_debug("%s", __func__);

	festate = (odbcFdwExecutionState *) node->fdw_state;
	if (festate == NULL)
		return;

	/* Report work already performed; EXPLAIN itself never runs a count query. */
	if (es->analyze)
	{
#if PG_VERSION_NUM >= 110000
		ExplainPropertyInteger("Foreign Rows Retrieved", NULL,
		                       festate->row_count, es);
#else
		ExplainPropertyLong("Foreign Rows Retrieved",
		                    (long) festate->row_count, es);
#endif
	}
}

/*
 * odbcEndForeignScan
 *      Finish scanning foreign table and dispose objects used for this scan
 */
void
odbcEndForeignScan(ForeignScanState *node)
{
	odbcFdwExecutionState *festate;

	elog_debug("%s", __func__);

	/* if festate is NULL, we are in EXPLAIN; nothing to do */
	festate = (odbcFdwExecutionState *) node->fdw_state;
	if (festate)
	{
		if (festate->stmt)
		{
			SQLFreeHandle(SQL_HANDLE_STMT, festate->stmt);
			festate->stmt = NULL;
		}
		odbc_disconnection(&festate->env, &festate->dbc);
	}
}

/*
 * odbcReScanForeignScan
 *      Rescan table, possibly with new parameters
 */
void
odbcReScanForeignScan(ForeignScanState *node)
{
	odbcFdwExecutionState *festate = (odbcFdwExecutionState *) node->fdw_state;
	SQLRETURN ret;

	elog_debug("%s", __func__);

	/*
	 * Actually rescan. This was an empty function, and an empty ReScan is not a
	 * cheap no-op here: the executor's contract is that after this call the scan
	 * starts again from the first row, and nothing else repositions an ODBC
	 * cursor. The cursor was left wherever the previous scan finished --
	 * normally exhausted -- so the second and every later scan returned NO ROWS
	 * and the query got a wrong answer with no error anywhere.
	 *
	 * SQLFreeStmt with SQL_CLOSE rather than SQLCloseCursor, and the difference
	 * matters: SQLCloseCursor returns SQL_ERROR with SQLSTATE 24000 when no
	 * cursor is open, which is a perfectly ordinary state here (a scan whose
	 * result set the executor never opened, or which the driver closed on
	 * exhaustion), so it would either have to be called and its return ignored
	 * -- indistinguishable from a real failure -- or guarded by state this
	 * function does not have. SQL_CLOSE is documented as having no effect when
	 * no cursor is open, and leaves the statement allocated and executable.
	 *
	 * Re-executing the stored text is correct because nothing in it varies per
	 * rescan: odbcGetQual pushes down only `Var = Const` with a text constant
	 * and TEXTEQ, so a Param never reaches the remote query, and a correlated
	 * qual stays a LOCAL filter on the scan node. If a future change pushes a
	 * parameter down, this function must rebuild the query instead of replaying
	 * it, and that is the note to find here.
	 *
	 * first_iteration is deliberately NOT reset. The masks it computes describe
	 * the mapping between the result set and the foreign table, the re-executed
	 * statement is the same statement, so its result metadata is identical and
	 * the masks stay valid. Resetting would recompute them into
	 * es_query_cxt on every rescan, which leaks for the life of the query.
	 */
	ret = SQLFreeStmt(festate->stmt, SQL_CLOSE);
	check_return(ret, "Closing ODBC cursor for rescan", festate->stmt,
	             SQL_HANDLE_STMT);
	ret = SQLExecDirect(festate->stmt, (SQLCHAR *) festate->query, SQL_NTS);
	check_return(ret, "Re-executing ODBC query", festate->stmt, SQL_HANDLE_STMT);

	/* The ceilings are per scan, so their counters restart with the scan. */
	festate->row_count = 0;
	festate->result_bytes = 0;
}
