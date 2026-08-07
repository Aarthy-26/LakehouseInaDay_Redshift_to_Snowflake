
_____________________________________________

## *Author*: AAVA

## *Created on*: 

## *Description*: Review of Snowflake SQL stored procedure `gold.sp_load_fact_flight_operations` for loading `FACT_FLIGHT_OPERATIONS` from Silver layer with dimension lookups and MERGE-based upsert.

## *Version*: 1

## *Updated on*: 

_____________________________________________

### Workflow Summary
The stored procedure `gold.sp_load_fact_flight_operations` reads validated rows from `SLV_FLIGHT_OPERATIONS` in the Silver layer, enriches them with surrogate keys from Gold dimensions (`DIM_DATE`, `DIM_AIRLINE`, `DIM_AIRCRAFT`, `DIM_ROUTE`, `DIM_AIRPORT`), deduplicates by `flight_id` using the latest `updated_ts`, and performs a `MERGE` into the Gold fact table `FACT_FLIGHT_OPERATIONS`. It writes start/end status and rowcount metrics into a provided audit table.

---

## 1) Validation Against Metadata

| Item | Status | Details |
|---|---|---|
| Mapping/metadata file(s) present for validation | ❌ | Only the stored procedure SQL was provided (`DI_LakehouseInaDay/Output/DI_Snowflake_Fact_sp_gold_fact_flight.sql`). No mapping/metadata files were available to confirm source-to-target column rules, datatypes, or business keys. |
| Source table existence/consistency (Silver) | ❌ | Procedure references `SLV_FLIGHT_OPERATIONS` and columns `dq_valid_flag`, `flight_date`, `carrier_code`, `tail_number`, `origin_airport_code`, `destination_airport_code`, `updated_ts`, etc. Without metadata/DDL, column existence and datatypes cannot be confirmed. |
| Target table consistency (Gold Fact) | ❌ | Procedure targets `FACT_FLIGHT_OPERATIONS` and uses columns like `date_key`, `airline_key`, `aircraft_key`, `route_key`, `origin_airport_key`, `destination_airport_key`, `schedule_id`, timestamps, metrics, and audit columns. Without the Gold fact DDL/mapping, column presence and datatypes cannot be verified. |
| Business key alignment for MERGE | ❌ | The code notes a mismatch: `final_rows` natural key is `flight_id`, but `MERGE` condition uses `tgt.schedule_id = src.flight_id` and comments indicate Gold DDL has no `flight_id`. This is a strong indicator of mapping/model misalignment. |

---

## 2) Compatibility with Snowflake

| Item | Status | Details |
|---|---|---|
| `CREATE OR REPLACE PROCEDURE` syntax valid | ✅ | Uses `RETURNS VARIANT`, `LANGUAGE SQL`, `EXECUTE AS CALLER`, and `AS $$ ... $$;` which is Snowflake Scripting. |
| Parameter definitions and usage | ✅ | Parameters are typed as `STRING` and used to build FQNs and in `IDENTIFIER()` for dynamic object references. |
| Variable declaration/assignment | ✅ | Uses `DECLARE` with defaults and `:=` assignments; supported in Snowflake Scripting. |
| Dynamic SQL with bind variables | ✅ | Uses `EXECUTE IMMEDIATE ... USING (...)` for audit inserts; correct pattern. |
| MERGE statement validity | ⚠️/❌ | `MERGE INTO IDENTIFIER(V_TARGET_TABLE_FQN)` is valid, but correctness depends on join keys and target columns. The join `tgt.schedule_id = src.flight_id` appears logically incorrect per inline comments. |
| Resultset rowcount extraction | ✅ | Uses `RESULT_SCAN(LAST_QUERY_ID())` and parses MERGE output; approach is Snowflake-compatible. |
| Exception handling | ✅ | Uses `EXCEPTION WHEN OTHER THEN ... RAISE;` which is supported in Snowflake Scripting. |
| Use of supported functions/types | ✅ | Uses `CURRENT_TIMESTAMP()`, `OBJECT_CONSTRUCT`, `COALESCE`, `IFF`, `QUALIFY`, `ROW_NUMBER()`; all supported. |
| Potential Snowflake runtime errors (compile-time) | ❌ | The CTE `lkp_route` contains a join condition `ON r.route_key IS NOT NULL AND r.route_key = r.route_key`, which is a tautology and can create unintended row multiplication. Also `final_rows` references `s.updated_ts`; if not present in the Silver source this will fail at runtime. |

---

## 3) Validation of Join Operations

| Item | Status | Details |
|---|---|---|
| Join columns exist in referenced tables | ❌ | Cannot be fully validated without DDL/metadata. However, some joins are suspicious (see below). |
| Join datatype compatibility | ❌ | Cannot confirm datatypes of `d.date` vs `s.flight_date`, `a.airline_code` vs `s.carrier_code`, etc. |
| `DIM_DATE` join integrity | ✅/⚠️ | `LEFT JOIN ... ON d.date = s.flight_date` is reasonable assuming `DIM_DATE.date` exists and is `DATE`. If `flight_date` is `TIMESTAMP`, implicit cast may misbehave. |
| `DIM_AIRLINE` join integrity | ✅/⚠️ | `a.airline_code = s.carrier_code` is reasonable if both are same normalized code. |
| `DIM_AIRCRAFT` SCD join integrity | ✅/⚠️ | `tail_number` plus effective date range is standard. Potential datatype issue: `flight_date` must be DATE. Uses `'9999-12-31'::DATE` which is Snowflake-compatible. |
| `DIM_ROUTE` join integrity | ❌ | The join is effectively unconstrained: `r.route_key = r.route_key` is always true for non-null values and does not reference source columns. This can create a many-to-many join (row explosion) and incorrect `route_key` assignments. Inline comment states route lookup by `route_id` is required but missing. |
| Airport dimension joins | ✅/⚠️ | `airport_code` joins for origin/destination are standard. Requires codes to be standardized; otherwise may produce null keys. |
| MERGE match condition integrity | ❌ | `ON tgt.schedule_id = src.flight_id` mismatches semantics (schedule vs flight). Likely causes incorrect updates/inserts (duplicates or overwrites). |

---

## 4) Syntax and Code Review

| Item | Status | Details |
|---|---|---|
| General SQL syntax | ✅ | Script compiles structurally (CTEs, MERGE, exception). |
| Stored procedure naming convention | ❌ | Procedure is named `gold.sp_load_fact_flight_operations`. If your standard is `SP_<DOMAIN>_<ACTION>`, it does not comply (lowercase, schema-qualified, and not prefixed with `SP_`). If project standard differs, adjust accordingly. |
| Identifier usage and casing | ✅ | Uses `IDENTIFIER()` for dynamic object names; generally correct. |
| Column references in `final_rows` | ❌ | `final_rows` selects `s.flight_id` and orders by `s.updated_ts`. If target fact does not have `flight_id` and/or source does not have `updated_ts`, this will fail or be inconsistent. |
| Comments indicate unresolved mapping gaps | ❌ | Inline `SKIPPED` comments explicitly flag missing lookup/mapping for route and fact business key. These are unresolved design issues. |

---

## 5) Compliance with Development Standards

| Item | Status | Details |
|---|---|---|
| Modularity and readability | ✅ | Clear CTE-based transform pipeline, separated audit sections. |
| Audit logging implemented | ✅/⚠️ | Writes start and end audit rows. However, it inserts a new row at start and again at end rather than updating the start row; depending on audit design this may be acceptable or may create duplicates. |
| Transaction handling | ⚠️ | No explicit `BEGIN TRANSACTION/COMMIT/ROLLBACK`. Snowflake Scripting executes statements atomically, but multi-statement transactional requirements depend on audit expectations. Consider explicit transaction if consistency is required. |
| Idempotency | ❌ | Due to incorrect MERGE key (`schedule_id = flight_id`) idempotency is not guaranteed. Also unconstrained `DIM_ROUTE` join can change results between runs. |
| Error handling and observability | ✅/⚠️ | Exceptions are captured and logged, then re-raised. Good. Could add more context (e.g., `SQLSTATE`, `LAST_QUERY_ID()`) for troubleshooting. |

---

## 6) Validation of Transformation Logic

| Item | Status | Details |
|---|---|---|
| DQ filter correctness (`dq_valid_flag = TRUE`) | ✅/⚠️ | Reasonable, but depends on DQ framework definition; not verifiable without metadata. |
| Dimension key derivations | ✅/⚠️ | Date/airline/aircraft/airport keys are derived via left joins; nulls will propagate if lookups miss. Consider default unknown keys if required by model. |
| Route key derivation | ❌ | Not implemented correctly; current join does not derive route key from source attributes and will cause incorrect results. |
| Deduplication logic | ✅/⚠️ | `ROW_NUMBER() OVER (PARTITION BY flight_id ORDER BY updated_ts DESC) = 1` is standard for latest-record selection. Requires `updated_ts` to exist and represent last change. |
| Fact natural key and MERGE logic | ❌ | `final_rows` includes `flight_id` as natural key but the target merge uses `schedule_id` and maps `tgt.schedule_id = src.flight_id`. This is inconsistent and likely incorrect per the code comment. |
| Audit columns (`dw_created_ts`, `dw_updated_ts`) | ✅ | Populated consistently on insert; updated timestamp set on update. |

---

## 7) Error Reporting and Recommendations

| # | Issue (❌) | Impact | Recommendation / Fix |
|---:|---|---|---|
| 1 | No mapping/metadata inputs provided | Cannot validate column mapping, datatypes, constraints, business keys | Add mapping file(s)/DDL for Silver source, Gold dimensions, and Gold fact. Re-run review with those inputs. |
| 2 | `DIM_ROUTE` join is unconstrained (`r.route_key = r.route_key`) and does not reference source | Row explosion, wrong `route_key`, non-deterministic results | Implement proper route lookup join using a real business key from Silver (e.g., `s.route_id`, or `origin_airport_code + destination_airport_code`, etc.) aligned to `DIM_ROUTE` design. Remove tautological predicates. |
| 3 | MERGE match condition uses `tgt.schedule_id = src.flight_id` | Incorrect upserts (updates wrong rows or inserts duplicates), breaks idempotency | Confirm the fact table business key. If fact contains `flight_id`, add it to target and use `tgt.flight_id = src.flight_id`. If not, then use consistent key(s) such as `schedule_id` matched to `src.schedule_id`. Do not cross-map unrelated identifiers. |
| 4 | Potential missing columns in Silver source (`updated_ts`, `flight_id`, etc.) | Runtime failures at compile/execute time | Verify Silver schema and adjust dedup/order-by and natural keys accordingly. If no `updated_ts`, use ingestion timestamp or another deterministic ordering. |
| 5 | Procedure naming convention not aligned to stated standard | Governance/standards non-compliance | Rename to conform to standard, e.g., `GOLD.SP_FACT_FLIGHT_OPERATIONS_LOAD` (or project standard). Ensure dependent calls updated. |
| 6 | Audit logging inserts separate start and end rows | Audit table may have duplicated entries per run; difficult to query latest status | If audit design expects one row per run, capture a `run_id` at start and `UPDATE` that row at end, or include unique run identifier in both inserts. |

---

### Open Items (Requires Metadata / Design Decision)
1. Confirm Gold `FACT_FLIGHT_OPERATIONS` primary/natural key and required MERGE matching columns.
2. Confirm `DIM_ROUTE` design (available business keys/columns) to implement correct lookup.
3. Confirm required behavior for missing dimension lookups (allow null FK vs assign default "unknown" surrogate keys).
4. Confirm audit table schema (columns and whether insert-vs-update is desired).
