
_____________________________________________

## *Author*: AAVA

## *Created on*: 

## *Description*: Review of Snowflake stored procedure `gold.sp_load_fact_flight_operations` for metadata alignment, Snowflake compatibility, join integrity, coding standards, and transformation logic.

## *Version*: 1

## *Updated on*: 

_____________________________________________

### Workflow Summary
The input SQL Scripting stored procedure `gold.sp_load_fact_flight_operations` loads `FACT_FLIGHT_OPERATIONS` in the Gold layer from Silver table `SLV_FLIGHT_OPERATIONS` by filtering to `dq_valid_flag = TRUE`, looking up surrogate keys from Gold dimensions (`DIM_DATE`, `DIM_AIRLINE`, `DIM_AIRCRAFT`, `DIM_ROUTE`, `DIM_AIRPORT`), deduplicating by `flight_id` (latest `updated_ts`), and performing a `MERGE` into the target. It also writes start/end audit records to a provided audit table FQN and returns a VARIANT object with execution metadata.

> Note: No mapping/metadata file was provided/read as part of the inputs (only the stored procedure SQL file was supplied). All mapping validations below are limited to what can be inferred from code comments and object names.

---

## 1) Validation Against Metadata

| Item | Status | Details |
|---|---:|---|
| Mapping/metadata file(s) present in inputs | ❌ | Only `DI_LakehouseInaDay/Output/DI_Snowflake_Fact_sp_gold_fact_flight.sql` was provided. No mapping/metadata file was available to validate column-level rules. |
| Source table(s) identified and consistent | ✅ | Source referenced as `IDENTIFIER(P_SILVER_DB || '.' || P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS')`. |
| Target table(s) identified and consistent | ✅ | Target resolved as `P_GOLD_DB.P_GOLD_SCHEMA.FACT_FLIGHT_OPERATIONS`. |
| Column mapping validated vs metadata | ❌ | Cannot verify required/optional columns, datatypes, defaulting rules, and business keys without mapping/DDL metadata. |
| Dimension lookups validated vs metadata | ❌ | Lookups are coded, but cannot confirm correct keys/attributes without dimension/table DDL or mapping. |
| Audit table schema validated vs metadata | ❌ | Procedure inserts into `P_AUDIT_TABLE_FQN` columns `(procedure_name, target_table, start_ts, end_ts, status, rows_inserted, rows_updated, error_message)` but no audit table DDL provided to confirm these columns exist and types match. |

---

## 2) Compatibility with Snowflake

| Item | Status | Details |
|---|---:|---|
| `CREATE OR REPLACE PROCEDURE` syntax correct | ✅ | Uses Snowflake SQL Scripting: `LANGUAGE SQL ... AS $$ ... $$;`. |
| Parameter definitions valid | ✅ | Parameters are typed as `STRING`; used to build fully qualified names. |
| Return type valid | ✅ | `RETURNS VARIANT` and returns `OBJECT_CONSTRUCT(...)`. |
| Execution rights specified | ✅ | `EXECUTE AS CALLER` specified. |
| SQL Scripting variable/assignment syntax valid | ✅ | Uses `DECLARE`, `:=` assignments, `IF ... THEN ... END IF;`. |
| Use of `IDENTIFIER()` for dynamic objects valid | ✅ | Correct pattern for dynamic table references in SQL. |
| Dynamic SQL with `EXECUTE IMMEDIATE ... USING` valid | ✅ | Parameter binding used for audit inserts to reduce injection risk for values (table name still dynamic). |
| Transaction handling appropriate | ⚠️/❌ | No explicit transaction control. Depending on requirements, merge + audit inserts may need atomicity. In Snowflake procedures, statements run in a transaction by default unless autocommit/implicit behavior differs; clarify if audit should commit on failure. |
| MERGE syntax valid | ✅ | Standard Snowflake `MERGE INTO ... USING ... ON ... WHEN MATCHED ... WHEN NOT MATCHED ...`. |
| MERGE results rowcount capture valid | ⚠️/❌ | Uses `RESULT_SCAN(LAST_QUERY_ID())` and expects `$1/$2` labels `number of rows inserted/updated`. This pattern works for some DML (and historically for MERGE), but output format can vary. Safer: use `GET_DML_STATEMENT_STATS` (where available) or parse `QUERY_HISTORY` / `LAST_QUERY_ID()` carefully; verify in your Snowflake account. |
| Exception handling valid | ✅ | Uses `EXCEPTION WHEN OTHER THEN ... SQLERRM ... RAISE;`. |
| Unsupported/deprecated features used | ✅ | No obvious unsupported features observed. |

---

## 3) Validation of Join Operations

| Item | Status | Details |
|---|---:|---|
| Join columns exist and are meaningful (DIM_DATE) | ❌ | Join: `d.date = s.flight_date`. Cannot confirm `DIM_DATE.date` exists or datatype aligns with `flight_date` without DDL/metadata. |
| Join columns exist and are meaningful (DIM_AIRLINE) | ❌ | Join: `a.airline_code = s.carrier_code`. Cannot confirm presence/types without DDL/metadata. |
| Join columns exist and are meaningful (DIM_AIRCRAFT) | ❌ | Join: `ac.tail_number = s.tail_number` and date range on `effective_start_date/effective_end_date`. Cannot confirm presence/types without DDL/metadata. |
| Join logic for route dimension is valid | ❌ | `lkp_route` join is effectively a no-op: `ON r.route_key IS NOT NULL AND r.route_key = r.route_key` is always true for non-null and does not reference source columns. This creates a many-to-many join (cartesian-like) and will explode row counts. Comment indicates a missing `dim_route.route_id` column needed for lookup by Silver `route_id`. |
| Airport lookups join keys validated | ❌ | Joins: `airport_code = origin_airport_code` and `airport_code = destination_airport_code`. Cannot confirm columns/types without DDL/metadata. |
| Join key datatype compatibility | ❌ | Cannot validate datatypes across joins without table DDL/metadata. |
| Relationship integrity (1:1 vs 1:M) protected | ❌ | No constraints/qualify applied after each dimension lookup. If dimensions have duplicates on lookup columns, joins can multiply rows. Only final `QUALIFY` dedupes by `flight_id`, which may mask join explosions and produce nondeterministic key selection. |

---

## 4) Syntax and Code Review

| Item | Status | Details |
|---|---:|---|
| Stored procedure compiles in Snowflake SQL Scripting | ❌ | `MERGE ... USING final_rows src` is invalid because `final_rows` is a CTE and must be referenced as `(SELECT ... FROM final_rows)` or inline CTE in `USING` clause is not directly addressable in that position. In Snowflake, you can do `USING (SELECT * FROM final_rows) src`. |
| MERGE `ON` clause uses correct business key | ❌ | `ON tgt.schedule_id = src.flight_id` appears mismatched: compares `schedule_id` to `flight_id`. Comment also states Gold DDL lacks `flight_id`. This likely breaks matching logic and causes incorrect updates/inserts. |
| Target columns referenced in UPDATE/INSERT exist | ❌ | Cannot confirm target columns exist (no target DDL). Additionally, `flight_id` is not inserted, but used for dedupe and merge match; indicates mismatch with target model. |
| Source columns referenced exist | ❌ | References many columns (`dq_valid_flag`, `flight_date`, `carrier_code`, `tail_number`, `updated_ts`, etc.). Without Silver table DDL/metadata, cannot confirm. |
| Naming conventions | ⚠️/❌ | Procedure name `gold.sp_load_fact_flight_operations` does not follow the suggested `SP_<DOMAIN>_<ACTION>` convention (upper-case prefix). If your standard allows schema-qualified lower-case `sp_...` it may be acceptable; otherwise rename. |
| Use of comments / clarity | ✅ | Comments clearly indicate known skipped mappings/issues (route lookup and business key). |

---

## 5) Compliance with Development Standards

| Item | Status | Details |
|---|---:|---|
| Modular design (CTEs for stages) | ✅ | Uses staged CTEs for each lookup step. |
| Logging/auditing implemented | ✅ | Writes start/end entries to an audit table; returns execution metadata. |
| Audit logging on failure | ✅ | Exception block writes failure audit with `SQLERRM`. |
| Guard against audit self-write | ✅ | Checks target table FQN vs audit table FQN before inserting audit rows. |
| SQL injection risk controlled | ⚠️/❌ | Values are bound via `USING`, but `P_AUDIT_TABLE_FQN` and constructed target FQN are concatenated directly into SQL. If these parameters are user-controlled, object-name injection is possible. Consider validating against allowed patterns / whitelisting DB+schema+table names. |
| Consistent formatting and readability | ✅ | Formatting is consistent and readable. |

---

## 6) Validation of Transformation Logic

| Item | Status | Details |
|---|---:|---|
| DQ filter applied correctly | ✅ | `WHERE s.dq_valid_flag = TRUE`. |
| Date surrogate key derivation | ❌ | `lkp_date` uses LEFT JOIN but does not enforce `date_key` presence. Comment says “must have date_key”, but no filter like `WHERE d.date_key IS NOT NULL`. Missing keys may flow into fact as NULL. |
| Airline surrogate key derivation | ⚠️/❌ | LEFT JOIN allows null `airline_key`; no enforcement or default unknown member handling shown. |
| Aircraft SCD range logic | ✅ | Uses `flight_date BETWEEN effective_start_date AND COALESCE(effective_end_date, '9999-12-31'::DATE)`; reasonable SCD2 filter assuming types align. |
| Route surrogate key derivation | ❌ | Route lookup is incorrect/no-op and will cause row explosion or arbitrary `route_key` selection after final dedupe. |
| Airport key derivation | ⚠️/❌ | LEFT JOIN allows NULL airport keys; no enforcement/unknown handling. |
| Deduplication logic correct and deterministic | ⚠️/❌ | `QUALIFY ROW_NUMBER() ... ORDER BY s.updated_ts DESC` assumes `updated_ts` exists and is non-null; if ties occur, nondeterministic selection. Add secondary sort (e.g., ingestion timestamp) for determinism. |
| MERGE update/insert column alignment | ❌ | Merge match key mismatch (`schedule_id` vs `flight_id`). Also `schedule_id` is set from `src.schedule_id` but match uses `src.flight_id`; indicates confusion between natural keys. |

---

## 7) Error Reporting and Recommendations

| Finding (❌) | Impact | Recommendation / Fix |
|---|---|---|
| No mapping/metadata files provided | Cannot validate column-level mapping, datatypes, and required business keys | Add mapping file(s) and/or DDL for Silver/Gold tables and dimensions to the input set. Re-run review with these artifacts. |
| `lkp_route` join is invalid/no-op (`r.route_key = r.route_key`) | Severe: row explosion, incorrect `route_key`, wrong fact grain | Implement proper join to `DIM_ROUTE` using a real business key from Silver (e.g., `s.route_id`) and a corresponding dimension attribute (e.g., `r.route_id`). If `DIM_ROUTE` lacks that column, update the dimension model/DDL to include it or create a bridge/lookup table. |
| MERGE `USING final_rows src` references CTE directly | Procedure may fail to compile/run | Change to `USING (SELECT * FROM final_rows) src` (or inline the `final_rows` SELECT directly in the USING clause). |
| MERGE `ON` condition mismatched (`tgt.schedule_id = src.flight_id`) | Incorrect upserts: duplicates, missed updates, wrong matches | Align business key. Either: (a) include `flight_id` in target and match on it; or (b) match on `schedule_id` to `src.schedule_id` if that is the intended natural key. Update comments and mapping accordingly. |
| Cannot verify join column existence/types for all dimension lookups | Risk of runtime failures (invalid identifiers) or implicit casts hurting performance | Provide/verify DDL for `SLV_FLIGHT_OPERATIONS`, `DIM_DATE`, `DIM_AIRLINE`, `DIM_AIRCRAFT`, `DIM_ROUTE`, `DIM_AIRPORT`, `FACT_FLIGHT_OPERATIONS`. Ensure join columns exist and datatypes align (DATE vs TIMESTAMP, VARCHAR lengths, etc.). |
| No enforcement of required surrogate keys (e.g., `date_key`) | Facts may load with NULL foreign keys, breaking downstream analytics | If keys are mandatory, filter out rows where key lookup fails (`WHERE date_key IS NOT NULL`) or map to an "Unknown" member key (e.g., 0 or -1) consistently across dimensions. |
| Potential dimension duplicates not controlled | Many-to-many joins can multiply rows and create nondeterministic key selection | Ensure dimension uniqueness on lookup attributes (constraints or dedupe subqueries). Consider `QUALIFY ROW_NUMBER()` on each dimension join or pre-aggregate dimensions to distinct keys before joining. |
| Object-name injection risk via concatenated FQNs | Security risk in multi-tenant / parameterized execution | Validate input parameters to allow only expected database/schema/table names (regex + whitelist), or avoid passing raw FQNs from untrusted contexts. |
| Rowcount capture via `RESULT_SCAN(LAST_QUERY_ID())` may be brittle | Incorrect audit metrics if result format differs | Validate in environment. If unreliable, query `INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION` for the last query and parse `ROWS_INSERTED/ROWS_UPDATED` where available, or maintain counts via staged temp table approach. |

---

### Overall Readiness
- **Compilation/Runtime readiness:** ❌ (route join and MERGE USING syntax/match key issues must be fixed)
- **Metadata conformance:** ❌ (missing mapping/DDL inputs)
- **Join integrity:** ❌ (route join is invalid; other joins unverified without DDL)
