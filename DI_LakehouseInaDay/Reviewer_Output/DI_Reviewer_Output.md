
_____________________________________________

## *Author*: AAVA

## *Created on*: 

## *Description*: Review of Snowflake stored procedure `gold.sp_load_fact_flight_operations` for Gold fact load (fact_flight_operations).

## *Version*: 1

## *Updated on*: 

_____________________________________________

### Workflow Summary
This stored procedure (`gold.sp_load_fact_flight_operations`) loads data from `silver.slv_flight_operations` into the Gold fact table `gold.fact_flight_operations` using a `MERGE` (upsert). It filters to `dq_valid_flag = TRUE`, performs dimension lookups for airline/aircraft/airport (route lookup is currently a placeholder), deduplicates by `flight_id` using latest `src_updated_ts`, validates `date_key` is not null, merges into the target using `(schedule_id, date_key)` as the match key, and writes audit rows to a caller-supplied audit table.

---

## 1) Validation Against Metadata
> Mapping/metadata files were **not provided** in the inputs; validation is limited to internal consistency and obvious model intent inferred from object names.

| Item | Status | Details |
|---|---|---|
| Source table identified and referenced consistently | ✅ | Uses `silver.slv_flight_operations` in `src` CTE and downstream transformations. |
| Target table identified and referenced consistently | ✅ | Uses `gold.fact_flight_operations` as MERGE target; `V_TARGET_TABLE` matches. |
| Column-level mapping verified against mapping file | ❌ | No mapping/metadata file was provided, so mappings (e.g., `carrier_code → dim_airline.airline_key`, date_key derivation, merge key choice) cannot be confirmed. |
| Data type consistency (inferred) between derived keys and target | ❌ | `date_key` derived as NUMBER; cannot confirm target column type without DDL/mapping. Same for all other columns. |
| Natural/business key for fact identified per metadata | ❌ | Code comments state Gold DDL lacks deterministic natural key; merge uses `(schedule_id, date_key)` as best-effort. Needs confirmation via metadata. |

---

## 2) Compatibility with Snowflake

| Item | Status | Details |
|---|---|---|
| `CREATE OR REPLACE PROCEDURE` syntax valid | ✅ | Uses Snowflake SQL procedure syntax. |
| Procedure language appropriate and supported | ✅ | `LANGUAGE SQL` is supported (Snowflake Scripting). |
| `EXECUTE AS` clause valid | ✅ | `EXECUTE AS CALLER` is valid. |
| Return type valid and used consistently | ✅ | `RETURNS VARIANT` and returns `OBJECT_CONSTRUCT(...)`. |
| Variable declarations valid for Snowflake Scripting | ⚠️/❌ | Uses `DECLARE ...` correctly, but later uses `LET v_merge_qid STRING := LAST_QUERY_ID();` inside procedure body. In Snowflake Scripting, `LET` is valid, but mixing `LET` and `DECLARE` can be confusing; also `v_merge_qid` casing differs from declared variables and is referenced with `:v_merge_qid` bind style. Recommend `DECLARE v_merge_qid STRING; v_merge_qid := LAST_QUERY_ID();` for clarity and to avoid bind issues. |
| Bind variable usage (`INTO :var`, `TABLE(RESULT_SCAN(:qid))`) | ❌ | The code uses `INTO :V_ROWS_INSERTED, :V_ROWS_UPDATED` and `RESULT_SCAN(:v_merge_qid)`; bind syntax with `:` is typically for Snowflake clients. In Snowflake Scripting, variables are referenced without `:`. This may fail at runtime. |
| Exception handling implemented correctly | ✅ | Uses `EXCEPTION WHEN OTHER THEN ... ERROR_MESSAGE(); RAISE STATEMENT_ERROR ...` pattern. |
| Dynamic SQL with `EXECUTE IMMEDIATE ... USING` valid | ✅ | Uses parameter binding via `USING` for audit inserts. |
| Unsupported/deprecated features used | ✅ | No obvious unsupported features detected; main risk is variable/bind syntax in SQL scripting context. |
| Transaction handling appropriate | ❌ | No explicit transaction control (BEGIN TRANSACTION/COMMIT/ROLLBACK). For MERGE + audit logging, failure mid-way could leave partial audit entries. Needs a standard approach (either explicit transaction or idempotent audit strategy). |

---

## 3) Validation of Join Operations

| Item | Status | Details |
|---|---|---|
| All joined tables exist and are referenced with correct schema qualifiers | ✅ | `gold.dim_airline`, `gold.dim_aircraft`, `gold.dim_airport`, `gold.dim_route` referenced consistently. |
| Join columns exist in source/intermediate datasets | ❌ | Cannot confirm existence of `carrier_code`, `tail_number`, `origin_airport_code`, etc. without table DDLs or metadata. Must be validated against `silver.slv_flight_operations` definition. |
| Join predicates are meaningful and non-placeholder | ❌ | `gold.dim_route` join is `ON dr.route_key IS NOT NULL` (and in earlier CTE even duplicated joins/placeholder `EXISTS (SELECT 1)`). This is effectively a Cartesian-ish filter and will produce incorrect results / row explosion. |
| Join cardinality/integrity controlled (no unintended duplication) | ❌ | `dim_route` join as written can multiply rows. Also, `dim_airline` join assumes uniqueness on `airline_code`; without constraint/QUALIFY, duplicates could multiply fact rows. |
| SCD2 lookup logic for aircraft is correct | ✅ | `flight_date BETWEEN effective_start_date AND COALESCE(effective_end_date, '9999-12-31')` is standard point-in-time. Confirm date types to avoid implicit casts. |
| Duplicate join blocks / syntax issues in joins | ❌ | In `xform` CTE, `LEFT JOIN gold.dim_route dr` appears twice with same alias `dr` which is invalid SQL (duplicate alias). Although `xform` is not used later, it will still be parsed and will fail compilation. |

---

## 4) Syntax and Code Review

| Item | Status | Details |
|---|---|---|
| Procedure compiles (no obvious SQL compilation blockers) | ❌ | `xform` CTE contains duplicate `LEFT JOIN gold.dim_route dr` with same alias; this will cause compilation failure even if `xform` is unused. Also `QUALIFY 1=1` is unnecessary and may indicate unfinished logic. |
| Object naming conventions | ✅ | `gold.sp_load_fact_flight_operations` is descriptive and consistent with domain/action. |
| Consistent aliasing and readability | ❌ | Two separate transformation approaches (`xform` then `resolved`), but `xform` is unused. Duplicate joins and placeholder comments should be removed. |
| MERGE match condition aligns with intended grain | ❌ | Uses `(schedule_id, date_key)` but dedup is by `flight_id`. If schedule_id is not unique per day, updates/inserts may be incorrect. Needs a deterministic business key per model. |
| Use of reserved words / quoting issues | ✅ | No obvious reserved-word conflicts in identifiers. |

---

## 5) Compliance with Development Standards

| Item | Status | Details |
|---|---|---|
| Parameter validation | ❌ | Does not validate `P_AUDIT_TABLE_FQN` is non-null/non-empty and exists. Dynamic insert will fail with unclear error if invalid. |
| Logging/auditing implemented | ✅ | Writes pre/post rows with status and counts; includes guard to avoid recursion. |
| Row count metrics captured reliably | ❌ | MERGE result parsing relies on `RESULT_SCAN` with bind syntax that may be incorrect in SQL scripting; may fail or return 0. |
| Idempotency/re-runnability | ❌ | Depends on merge key; if incorrect, reruns could overwrite or duplicate. Also audit pre-step always inserts RUNNING row; no update of same row, may create duplicates. |
| Formatting and modularity | ❌ | Contains dead/unreferenced CTE (`xform`) and placeholder joins; should be cleaned before production. |

---

## 6) Validation of Transformation Logic

| Item | Status | Details |
|---|---|---|
| Filter on DQ-valid rows applied as intended | ✅ | `WHERE s.dq_valid_flag = TRUE`. |
| `date_key` derivation correct and consistent | ✅ | Uses `TO_NUMBER(TO_CHAR(flight_date,'YYYYMMDD'))`. Must confirm `flight_date` is DATE/TIMESTAMP. |
| Dimension key resolution logic correct | ❌ | `dim_route` key resolution is not implemented; currently uses placeholder join. This will set `route_key` arbitrarily/non-deterministically and can multiply rows. |
| Deduplication logic consistent with merge key | ❌ | Dedup uses `flight_id` but merge matches on `(schedule_id, date_key)`. If these represent different grains, dedup may not prevent duplicates and updates may be wrong. |
| Data quality assertions adequate | ❌ | Only checks `date_key IS NULL`. Missing checks for mandatory FKs (airline/aircraft/airports), negative measures, timestamp ordering, etc. (as per expected model). |

---

## 7) Error Reporting and Recommendations

| Finding (❌) | Impact | Recommendation / Fix |
|---|---|---|
| Missing mapping/metadata inputs | Cannot confirm correctness of mappings, data types, business keys | Add mapping/metadata file(s) (source/target DDL, column mapping) to review set. Re-validate all derived columns and merge keys. |
| `xform` CTE has duplicate joins with alias `dr` and is unused | Procedure likely fails to compile; dead code increases risk | Remove `xform` CTE entirely or fix it. Ensure each join alias is unique and only one `dim_route` join exists. |
| `dim_route` join is placeholder (`dr.route_key IS NOT NULL`) | Produces incorrect `route_key` and can cause row multiplication | Implement route lookup using a natural key (e.g., `s.route_id` or `(origin,destination)`); update `dim_route` to store that natural key if missing. Replace placeholder join with deterministic predicate. |
| Variable/bind syntax likely incorrect for Snowflake Scripting (`INTO :V_STATUS`, `RESULT_SCAN(:v_merge_qid)`) | Runtime failures or incorrect row counts; compilation may fail depending on parser | Use Snowflake Scripting variable references without `:`. Example: `SELECT ... INTO V_ROWS_INSERTED, V_ROWS_UPDATED FROM TABLE(RESULT_SCAN(v_merge_qid));` and `SELECT ... INTO V_STATUS ...`. Also prefer `DECLARE v_merge_qid STRING; v_merge_qid := LAST_QUERY_ID();`. |
| Merge key not confirmed and potentially inconsistent with dedup grain | Incorrect updates/inserts, duplicates, data drift | Define and document fact grain and natural key in Gold DDL/metadata (e.g., `flight_id` or `(flight_id,date_key)`), then align `MERGE ON` and dedup partition to that key. |
| Join integrity not guaranteed (dim duplicates, missing FK checks) | Row multiplication, non-deterministic key assignment, FK nulls | Enforce dimension uniqueness (e.g., `QUALIFY ROW_NUMBER()` in dimension subquery) or add constraints/logic. Add DQ checks for mandatory keys and handle unknown members. |
| No explicit transaction strategy with audit logging | Partial audit rows or partial data changes on failure | Consider wrapping MERGE + post-audit in a transaction, or write audit using update-in-place (single audit row per run) keyed by run_id. |
| Limited DQ assertions | Bad data can enter Gold | Add validations: non-null required fields, timestamp order (dep ≤ arr), non-negative durations/distances, etc., based on business rules in mapping. |

---

### Open Items (Needs Input / Manual Confirmation)
1. Provide DDL for `silver.slv_flight_operations` and `gold.fact_flight_operations` to validate column existence and data types.
2. Provide DDL and natural key design for `gold.dim_route` (and how to map from `slv_flight_operations.route_id` or origin/destination codes).
3. Confirm the intended business key/grain for `gold.fact_flight_operations` and required uniqueness constraints.
4. Confirm audit table schema (required columns and types) for `P_AUDIT_TABLE_FQN`.
