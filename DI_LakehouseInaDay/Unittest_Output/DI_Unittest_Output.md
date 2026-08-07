Author: AAVA

Created on: 2026-08-07

Description: Unit test cases and native Snowflake SQL assertions for gold.sp_load_fact_flight_operations (loads gold.fact_flight_operations).

Version: _1

Updated on: 2026-08-07

## Object Summary

- Target object: **Stored Procedure** `gold.sp_load_fact_flight_operations(P_AUDIT_TABLE_FQN VARCHAR)` loading **table** `gold.fact_flight_operations`
- Source table(s)/view(s): `silver.slv_flight_operations`, `gold.dim_airline`, `gold.dim_aircraft`, `gold.dim_route`, `gold.dim_airport`
- Transformations identified: **6** (date_key derivation; airline lookup; SCD2 aircraft lookup; airport lookups; dedup via ROW_NUMBER; merge dw_created_ts/dw_updated_ts stamping)
- Joins identified: **6** (dim_airline; dim_aircraft; dim_route; dim_airport origin; dim_airport destination; merge match)
- Aggregations identified: **1** (ROW_NUMBER window for dedup)
- Filters identified: **3** (`dq_valid_flag = TRUE`; SCD2 date-range predicate; `QUALIFY ROW_NUMBER()...=1`)
- Existing constraints/tests found in object: **1** (in-proc validation that `date_key IS NOT NULL`, raises error)

## Test Case Matrix

| Test Case ID | Category (Happy Path / Edge Case / Exception) | Column/Join/Aggregation | Description | SQL Assertion Type |
|---|---|---|---|---|
| TC001 | Happy Path | Filter: `dq_valid_flag` | Ensure only `silver.slv_flight_operations` rows with `dq_valid_flag = TRUE` are eligible for load. | Business-rule/transformation correctness |
| TC002 | Happy Path | Transformation: `date_key` | Validate `date_key` equals `TO_NUMBER(TO_CHAR(flight_date,'YYYYMMDD'))` for loaded rows (when `flight_date` present). | Business-rule/transformation correctness |
| TC003 | Exception | Validation: `date_key` non-null | Ensure procedure’s DQ rule is upheld: no rows exist with `date_key IS NULL` in the staged set. | Not-null |
| TC004 | Happy Path | Join: airline lookup | Validate `airline_key` resolves via `gold.dim_airline.airline_code = carrier_code` for loaded rows (when carrier_code exists). | Referential integrity |
| TC005 | Edge Case | Join key nullability: carrier_code | Ensure rows with `carrier_code IS NULL` do not incorrectly resolve an `airline_key`. | Business-rule/transformation correctness |
| TC006 | Happy Path | Join: airport origin lookup | Validate `origin_airport_key` resolves via `gold.dim_airport.airport_code = origin_airport_code` (when origin_airport_code exists). | Referential integrity |
| TC007 | Happy Path | Join: airport destination lookup | Validate `destination_airport_key` resolves via `gold.dim_airport.airport_code = destination_airport_code` (when destination_airport_code exists). | Referential integrity |
| TC008 | Happy Path | Join: SCD2 aircraft lookup | Validate `aircraft_key` resolves via tail_number and `flight_date BETWEEN effective_start_date AND COALESCE(effective_end_date,'9999-12-31')` (when tail_number + flight_date present). | Business-rule/transformation correctness |
| TC009 | Edge Case | SCD2 boundary: effective_end_date NULL | Ensure rows can resolve aircraft against open-ended SCD2 records (`effective_end_date IS NULL`). | Business-rule/transformation correctness |
| TC010 | Happy Path | Dedup: ROW_NUMBER | Ensure only the latest `src_updated_ts` per `flight_id` would be kept by `QUALIFY ROW_NUMBER()...=1`. | Business-rule/transformation correctness |
| TC011 | Exception | Merge match key uniqueness | Ensure `(schedule_id, date_key)` is unique in `gold.fact_flight_operations` to prevent ambiguous MERGE matches. | Uniqueness |
| TC012 | Happy Path | Merge stamping | Ensure `dw_created_ts` and `dw_updated_ts` are populated in target. | Not-null |
| TC013 | Edge Case | Empty input set | If no valid `src` rows, ensure target is unchanged (no inserts/updates). | Business-rule/transformation correctness |
| TC014 | Exception | Orphan detection: airports | Detect any non-null airport codes in source that would not map to a dim_airport row, causing null FK keys. | Referential integrity |

## Generated Snowflake Test Scripts

```sql
/*
Unit tests for: gold.sp_load_fact_flight_operations
Target: gold.fact_flight_operations

NOTE: These are assertion queries meant to return ZERO rows (or COUNT=0) unless otherwise stated.

Where possible, assertions are written to validate the transformation logic defined in the stored procedure.
*/

/* ----------------------------------------------------------------------
Reusable assertion helpers (optional)
-----------------------------------------------------------------------*/
CREATE OR REPLACE PROCEDURE util.sp_assert_zero_count(
    P_TEST_NAME STRING,
    P_SQL STRING
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_CNT NUMBER;
BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (' || P_SQL || ') t' INTO :V_CNT;

    IF (V_CNT <> 0) THEN
        RAISE STATEMENT_ERROR WITH MESSAGE = 'ASSERTION FAILED [' || P_TEST_NAME || ']: expected 0 rows but got ' || V_CNT;
    END IF;

    RETURN OBJECT_CONSTRUCT('test', P_TEST_NAME, 'status', 'PASS', 'count', V_CNT);
END;
$$;

/* ----------------------------------------------------------------------
TC001 — Filter: only dq_valid_flag = TRUE are eligible
This checks that target does not contain flight_ids that come only from dq_invalid source.
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC001_only_valid_silver_rows_loaded',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN silver.slv_flight_operations s
    ON s.flight_id = f.flight_id
   AND TO_NUMBER(TO_CHAR(s.flight_date,'YYYYMMDD')) = f.date_key
  WHERE s.dq_valid_flag = FALSE
  $$
);

/* ----------------------------------------------------------------------
TC002 — date_key correctness (when flight_date present in source)
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC002_date_key_matches_flight_date',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN silver.slv_flight_operations s
    ON s.flight_id = f.flight_id
   AND s.dq_valid_flag = TRUE
  WHERE s.flight_date IS NOT NULL
    AND f.date_key <> TO_NUMBER(TO_CHAR(s.flight_date,'YYYYMMDD'))
  $$
);

/* ----------------------------------------------------------------------
TC003 — date_key NOT NULL (procedure already enforces; still assert on target)
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC003_target_date_key_not_null',
  $$
  SELECT 1 FROM gold.fact_flight_operations WHERE date_key IS NULL
  $$
);

/* ----------------------------------------------------------------------
TC004 — airline FK resolves when carrier_code present
Because we cannot assume dim_airline PK column beyond airline_key and natural key airline_code,
assert that if carrier_code maps to a dim row, then airline_key must be that key.
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC004_airline_key_matches_dim_airline',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN silver.slv_flight_operations s
    ON s.flight_id = f.flight_id
   AND s.dq_valid_flag = TRUE
  JOIN gold.dim_airline da
    ON da.airline_code = s.carrier_code
  WHERE s.carrier_code IS NOT NULL
    AND f.airline_key <> da.airline_key
  $$
);

/* ----------------------------------------------------------------------
TC005 — carrier_code NULL should not resolve airline_key (avoid accidental matches)
This is a best-effort rule: when source carrier_code IS NULL, airline_key should be NULL.
If business expects unknown member instead, adjust accordingly.
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC005_null_carrier_code_no_airline_key',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN silver.slv_flight_operations s
    ON s.flight_id = f.flight_id
   AND s.dq_valid_flag = TRUE
  WHERE s.carrier_code IS NULL
    AND f.airline_key IS NOT NULL
  $$
);

/* ----------------------------------------------------------------------
TC006 — origin airport FK resolves when origin_airport_code present
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC006_origin_airport_key_matches_dim',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN silver.slv_flight_operations s
    ON s.flight_id = f.flight_id
   AND s.dq_valid_flag = TRUE
  JOIN gold.dim_airport dao
    ON dao.airport_code = s.origin_airport_code
  WHERE s.origin_airport_code IS NOT NULL
    AND f.origin_airport_key <> dao.airport_key
  $$
);

/* ----------------------------------------------------------------------
TC007 — destination airport FK resolves when destination_airport_code present
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC007_destination_airport_key_matches_dim',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN silver.slv_flight_operations s
    ON s.flight_id = f.flight_id
   AND s.dq_valid_flag = TRUE
  JOIN gold.dim_airport dad
    ON dad.airport_code = s.destination_airport_code
  WHERE s.destination_airport_code IS NOT NULL
    AND f.destination_airport_key <> dad.airport_key
  $$
);

/* ----------------------------------------------------------------------
TC008 — SCD2 aircraft mapping correctness (when tail_number + flight_date present)
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC008_aircraft_key_matches_scd2_dim_aircraft',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN silver.slv_flight_operations s
    ON s.flight_id = f.flight_id
   AND s.dq_valid_flag = TRUE
  JOIN gold.dim_aircraft dac
    ON dac.tail_number = s.tail_number
   AND s.flight_date BETWEEN dac.effective_start_date AND COALESCE(dac.effective_end_date, '9999-12-31')
  WHERE s.tail_number IS NOT NULL
    AND s.flight_date IS NOT NULL
    AND f.aircraft_key <> dac.aircraft_key
  $$
);

/* ----------------------------------------------------------------------
TC009 — Open-ended SCD2 rows (effective_end_date IS NULL) can match
This ensures presence of at least one matched row in a scenario where dim has open-ended records.
Expected result: COUNT(*) >= 0; but for assertion style we check there is no contradiction:
if a match exists with NULL end date, aircraft_key must equal that key.
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC009_open_ended_scd2_aircraft_consistent',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN silver.slv_flight_operations s
    ON s.flight_id = f.flight_id
   AND s.dq_valid_flag = TRUE
  JOIN gold.dim_aircraft dac
    ON dac.tail_number = s.tail_number
   AND dac.effective_end_date IS NULL
   AND s.flight_date BETWEEN dac.effective_start_date AND '9999-12-31'
  WHERE f.aircraft_key <> dac.aircraft_key
  $$
);

/* ----------------------------------------------------------------------
TC010 — Dedup correctness: only latest src_updated_ts per flight_id should exist in target
We approximate by asserting that for each flight_id present in target, its src_updated_ts equals
the MAX(updated_ts) from valid silver for that flight_id.
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC010_target_reflects_latest_src_updated_ts_per_flight_id',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  JOIN (
    SELECT
      flight_id,
      MAX(updated_ts) AS max_updated_ts
    FROM silver.slv_flight_operations
    WHERE dq_valid_flag = TRUE
    GROUP BY flight_id
  ) smax
    ON smax.flight_id = f.flight_id
  WHERE f.src_updated_ts IS NULL
     OR f.src_updated_ts <> smax.max_updated_ts
  $$
);

/* ----------------------------------------------------------------------
TC011 — Merge match key uniqueness in target: (schedule_id, date_key)
Expected zero rows.
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC011_unique_schedule_id_date_key_in_target',
  $$
  SELECT schedule_id, date_key
  FROM gold.fact_flight_operations
  GROUP BY schedule_id, date_key
  HAVING COUNT(*) > 1
  $$
);

/* ----------------------------------------------------------------------
TC012 — dw timestamps populated
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC012_dw_created_ts_not_null',
  $$ SELECT 1 FROM gold.fact_flight_operations WHERE dw_created_ts IS NULL $$
);

CALL util.sp_assert_zero_count(
  'TC012_dw_updated_ts_not_null',
  $$ SELECT 1 FROM gold.fact_flight_operations WHERE dw_updated_ts IS NULL $$
);

/* ----------------------------------------------------------------------
TC013 — Empty input set should result in no changes
This is execution-based and environment-dependent.
Assertion pattern: if there are currently 0 valid silver rows, then procedure should insert/update 0.

Implement as a controlled test by running in an isolated test schema or using a temporary clone.
-----------------------------------------------------------------------*/
-- SKIPPED: gold.sp_load_fact_flight_operations — TC013 requires controlled harness (clone/transaction) to compare rowcounts before/after; not safely assertable with a single static query.

/* ----------------------------------------------------------------------
TC014 — Orphan detection for airports: non-null airport_code with no dim mapping
We check that any source airport code present in target has corresponding dim row.
Expected zero rows.
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC014_no_orphan_origin_airports',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  LEFT JOIN gold.dim_airport da
    ON da.airport_key = f.origin_airport_key
  WHERE f.origin_airport_key IS NOT NULL
    AND da.airport_key IS NULL
  $$
);

CALL util.sp_assert_zero_count(
  'TC014_no_orphan_destination_airports',
  $$
  SELECT 1
  FROM gold.fact_flight_operations f
  LEFT JOIN gold.dim_airport da
    ON da.airport_key = f.destination_airport_key
  WHERE f.destination_airport_key IS NOT NULL
    AND da.airport_key IS NULL
  $$
);

/* ----------------------------------------------------------------------
Route mapping tests
The procedure contains contradictory/placeholder joins to gold.dim_route and an inline SKIPPED comment.
-----------------------------------------------------------------------*/
-- SKIPPED: gold.fact_flight_operations.route_key — procedure does not implement a deterministic route natural-key lookup (joins are placeholders: `dr.route_key IS NOT NULL`); cannot assert correctness.

/* ----------------------------------------------------------------------
Additional not-null expectations from procedure outputs
-----------------------------------------------------------------------*/
CALL util.sp_assert_zero_count(
  'TC015_schedule_id_not_null_in_target_match_key',
  $$
  SELECT 1
  FROM gold.fact_flight_operations
  WHERE schedule_id IS NULL
  $$
);

/*
End of test scripts
*/
```

## Coverage Notes

- `route_key` mapping has **0** deterministic tests because the procedure’s `dim_route` joins are placeholders (`dr.route_key IS NOT NULL` and duplicated alias), making the lookup logic ambiguous.
- MERGE natural key ambiguity: procedure comment indicates `flight_key` identity and no deterministic natural key; the merge uses `(schedule_id, date_key)` best-effort. A uniqueness assertion (TC011) covers the risk, but correctness of this choice requires model-owner confirmation.
- Execution-based behavior (TC013) skipped because it requires a harness (clone/test schema + before/after comparison) rather than a static assertion.
- Total skipped-item count: **2**
