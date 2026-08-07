
_____________________________________________

## *Author*: AAVA

## *Created on*: 

## *Description*: Review of Snowflake SQL stored procedure gold.sp_load_fact_flight_operations for FACT_FLIGHT_OPERATIONS load/merge with audit logging.

## *Version*: 1

## *Updated on*: 

_____________________________________________

### Workflow Summary
The stored procedure `gold.sp_load_fact_flight_operations` reads validated rows from Silver `SLV_FLIGHT_OPERATIONS`, performs a series of dimension lookups (`DIM_DATE`, `DIM_AIRLINE`, `DIM_AIRCRAFT`, `DIM_ROUTE`, `DIM_AIRPORT`), deduplicates by `flight_id` using the latest `updated_ts`, and `MERGE`s results into Gold `FACT_FLIGHT_OPERATIONS`. It writes start/end audit records to a provided audit table FQN and returns a VARIANT status object.

---

## 1) Validation Against Metadata

| Item | Status | Details |
|---|---|---|
| Mapping/metadata file(s) provided alongside procedure | ❌ | No mapping/metadata files were provided/read. Validation against authoritative column-level rules cannot be completed. |
| Source table(s) explicitly identified and referenced via parameters | ✅ | Source referenced as `IDENTIFIER(P_SILVER_DB||'.'||P_SILVER_SCHEMA||'.SLV_FLIGHT_OPERATIONS')`. |
| Target table explicitly identified and referenced via parameters | ✅ | Target set as `P_GOLD_DB||'.'||P_GOLD_SCHEMA||'.FACT_FLIGHT_OPERATIONS'`. |
| Target columns in MERGE match selected columns in `final_rows` | ✅ | Insert list aligns with `final_rows` projection; update list aligns with same set (plus `dw_updated_ts`). |
| Business key alignment between source natural key and target key | ❌ | `final_rows` exposes `flight_id` as natural key but MERGE condition uses `tgt.schedule_id = src.flight_id` and comments indicate missing `flight_id` in Gold DDL. High risk of incorrect matching. |
| Dimension lookup keys aligned to expected dimensional attributes | ❌ | Route lookup is a no-op (`r.route_key = r.route_key`) and does not map from any source route identifier; comments indicate missing `dim_route.route_id`. |

---

## 2) Compatibility with Snowflake

| Item | Status | Details |
|---|---|---|
| Uses Snowflake SQL stored procedure with `LANGUAGE SQL` | ✅ | `CREATE OR REPLACE PROCEDURE ... LANGUAGE SQL`. |
| `EXECUTE AS` mode explicitly set | ✅ | `EXECUTE AS CALLER`. |
| Return type appropriate for status reporting | ✅ | `RETURNS VARIANT` with `OBJECT_CONSTRUCT` return. |
| Parameter types valid | ✅ | All parameters are `STRING` and used for object identifiers / audit table name. |
| Use of `IDENTIFIER()` for dynamic object names | ✅ | Correct pattern for dynamic table references. |
| Dynamic SQL uses binds (`USING`) to avoid injection in values | ✅ | Audit inserts use binds for values. Note: table name is concatenated (cannot be bound). |
| SQL scripting constructs valid (`DECLARE`, `BEGIN`, `EXCEPTION`) | ✅ | Structure is generally valid Snowflake Scripting. |
| MERGE syntax correctness | ✅ | MERGE statement structure is correct. |
| Resultset/rowcount capture logic compatible | ❌ | `RESULT_SCAN(LAST_QUERY_ID())` after MERGE does not return a stable 2-column key/value set in Snowflake for MERGE. Standard approach is `MERGE ...;` then use `SQLROWCOUNT` or query `QUERY_HISTORY`/`INFORMATION_SCHEMA`. Current parsing of `$1/$2` likely to fail or return 0. |
| Use of `LET ... RESULTSET := (...)` and `FROM V_MERGE_RESULTS` | ❌ | In Snowflake Scripting, consuming a RESULTSET typically requires cursor iteration or `TABLE(resultset)` pattern; `FROM V_MERGE_RESULTS` is not valid SQL. Risk of compilation error. |
| Exception handling and rethrow | ✅ | `EXCEPTION WHEN OTHER THEN ... RAISE;` is valid pattern. |

---

## 3) Validation of Join Operations

| Item | Status | Details |
|---|---|---|
| Date lookup join column existence and type compatibility | ❓/❌ | Join `d.date = s.flight_date`. Without DIM_DATE DDL/metadata, cannot confirm column names/types (`date` column name is often reserved/avoided). Marked ❌ due to missing metadata/DDL. |
| Airline lookup join column existence | ❓/❌ | `a.airline_code = s.carrier_code` cannot be verified without DIM_AIRLINE/SLV schema. Marked ❌ due to missing metadata/DDL. |
| Aircraft SCD join condition correctness | ❓/❌ | `ac.tail_number = s.tail_number` and date between effective range; cannot confirm column existence/types. Marked ❌ due to missing metadata/DDL. |
| Route lookup join integrity | ❌ | Join condition is tautological (`r.route_key = r.route_key`) and will produce a Cartesian-like effect (duplicates) unless optimizer collapses; also doesn’t use any source column. Must be fixed. |
| Airport lookup joins use correct keys | ❓/❌ | `airport_code` joins to origin/destination codes; cannot confirm columns. Marked ❌ due to missing metadata/DDL. |
| Deduplication strategy prevents duplicate MERGE source matches | ❌ | `QUALIFY ROW_NUMBER() ... PARTITION BY s.flight_id ORDER BY s.updated_ts DESC` assumes `updated_ts` exists. If missing, compilation error; if non-unique, still OK but unknown. Also potential duplication introduced by bad route join. |

---

## 4) Syntax and Code Review

| Item | Status | Details |
|---|---|---|
| Stored procedure name follows naming conventions | ✅ | `sp_load_fact_flight_operations` is descriptive; schema `gold` used. If stricter standard requires `SP_<DOMAIN>_<ACTION>`, then adjust. |
| Fully qualified object usage for target | ✅ | Target table constructed as FQN. |
| MERGE ON clause references correct columns | ❌ | Uses `tgt.schedule_id = src.flight_id` which is likely wrong and flagged by inline comments. |
| Use of reserved keywords / ambiguous names | ❓/❌ | `DIM_DATE` column named `date` may be reserved/ambiguous; cannot confirm. Recommend `DATE_VALUE` or quoting. |
| Comments indicate skipped mapping issues are tracked | ✅ | Inline `-- SKIPPED:` comments flag missing fields/DDL mismatches. |
| Potential SQL compilation issues | ❌ | Resultset consumption (`FROM V_MERGE_RESULTS`) likely invalid; route join logic invalid. |

---

## 5) Compliance with Development Standards

| Item | Status | Details |
|---|---|---|
| Parameterization for environments (DB/Schema) | ✅ | Silver/Gold DB & schema passed as params. |
| Basic audit logging start/end | ✅ | Inserts into audit table at start and end with status and row counts. |
| Audit table FQN validation / SQL injection risk | ❌ | `P_AUDIT_TABLE_FQN` is concatenated directly into dynamic SQL. If caller passes malicious identifier, risk exists. Recommend validate with `REGEXP_LIKE` for allowed pattern and/or use `IDENTIFIER()` in dynamic SQL patterns where possible. |
| Idempotency | ❌ | MERGE key mismatch and bad route join undermine idempotency (could update/insert wrong rows). |
| Consistent timestamp columns | ✅ | `dw_created_ts` and `dw_updated_ts` set to `CURRENT_TIMESTAMP()`. |
| Logging of error details | ✅ | Captures `SQLERRM` into audit on failure. |

---

## 6) Validation of Transformation Logic

| Item | Status | Details |
|---|---|---|
| DQ filter applied (`dq_valid_flag = TRUE`) | ✅ | Source filter applied in `src` CTE. |
| Dimension surrogate keys resolved before load | ✅/❌ | Date/airline/aircraft/airport keys are looked up; route key logic is incorrect (❌). |
| SCD effective dating applied for aircraft | ✅ | Uses `flight_date BETWEEN effective_start_date AND COALESCE(effective_end_date, '9999-12-31'::DATE)`. |
| Deduplication aligns with incremental semantics | ❓/❌ | Uses latest `updated_ts`; cannot verify existence/meaning of `updated_ts` without metadata. |
| Correct mapping of schedule/flight identifiers | ❌ | Selects `s.flight_id` but loads `schedule_id = s.schedule_id` while merging on `tgt.schedule_id = src.flight_id` (inconsistent). |

---

## 7) Error Reporting and Recommendations

| # | Finding (❌) | Impact | Recommendation |
|---:|---|---|---|
| 1 | No mapping/metadata files available | Cannot confirm correct source/target columns, data types, and business keys | Add/read mapping spec (source/target DDL + column mappings). Re-run review with those files. |
| 2 | Route dimension join is invalid (`r.route_key = r.route_key`) | Can explode row counts, create duplicates, wrong `route_key` assignment | Replace with join on a real business key (e.g., `r.route_id = s.route_id` or `r.origin_airport_code = s.origin_airport_code AND r.destination_airport_code = s.destination_airport_code`), per mapping/DDL. |
| 3 | MERGE match key inconsistent (`tgt.schedule_id = src.flight_id`) | Updates/inserts wrong rows; breaks idempotency | Align MERGE ON to the actual target natural key. Either (a) add `flight_id` column to FACT and use `tgt.flight_id = src.flight_id`, or (b) use `tgt.schedule_id = src.schedule_id` if schedule_id is the business key. |
| 4 | Rowcount capture using `RESULT_SCAN(LAST_QUERY_ID())` and `FROM V_MERGE_RESULTS` likely invalid | Procedure may fail to compile or always return 0 counts | Use Snowflake Scripting `GET DIAGNOSTICS` (where available) or `SQLROWCOUNT` for DML, or query `INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION` for MERGE stats. Validate correct pattern for MERGE counts. |
| 5 | Join column existence/types not verifiable (DIM/SLV schemas not provided) | Potential runtime failures due to missing columns or type mismatches | Provide DDLs for `SLV_FLIGHT_OPERATIONS` and all referenced dimensions. Add explicit casts in joins if needed (e.g., `TO_DATE`). |
| 6 | `updated_ts` assumed in dedupe | Compilation error if missing; incorrect ordering if wrong field | Confirm column exists; otherwise use a reliable ordering column (e.g., ingestion timestamp) or remove ordering if deterministic key uniqueness exists. |
| 7 | Audit table name concatenated directly | Potential SQL injection via identifier | Validate `P_AUDIT_TABLE_FQN` against allowed pattern (`^[A-Z0-9_]+\.[A-Z0-9_]+\.[A-Z0-9_]+$`), and fail fast if invalid; consider separate params for DB/SCHEMA/TABLE. |

---

### Open Items (Manual Review Required)
1. Provide Gold DDLs for `FACT_FLIGHT_OPERATIONS` and all referenced dimensions to confirm column names/types.
2. Provide Silver DDL for `SLV_FLIGHT_OPERATIONS` (confirm `flight_id`, `schedule_id`, `updated_ts`, airport codes, carrier code, tail number).
3. Confirm the intended business key for FACT (flight_id vs schedule_id) and adjust MERGE accordingly.
4. Confirm the intended route lookup logic and required columns in `DIM_ROUTE`.
