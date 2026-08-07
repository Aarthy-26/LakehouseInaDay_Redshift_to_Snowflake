Author: AAVA

Created on: 2026-08-07

Description: Unit test cases and native Snowflake SQL assertions for gold.sp_load_fact_flight_operations and its FACT_FLIGHT_OPERATIONS merge logic.

Version: _1

Updated on: 2026-08-07

## Object Summary

- **Target object**: Stored Procedure `gold.sp_load_fact_flight_operations` (MERGE target: `P_GOLD_DB.P_GOLD_SCHEMA.FACT_FLIGHT_OPERATIONS`)
- **Source tables/views**:
  - `P_SILVER_DB.P_SILVER_SCHEMA.SLV_FLIGHT_OPERATIONS`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_DATE`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_AIRLINE`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_AIRCRAFT`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_ROUTE`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_AIRPORT` (used twice: origin + destination)
- **Transformations identified**: 3
  - Filter `dq_valid_flag = TRUE`
  - SCD2-effective-date lookup for aircraft (`flight_date BETWEEN effective_start_date AND COALESCE(effective_end_date, '9999-12-31')`)
  - De-duplication via `QUALIFY ROW_NUMBER() OVER (PARTITION BY flight_id ORDER BY updated_ts DESC) = 1`
- **Joins identified**: 6 (all `LEFT JOIN` lookups)
- **Aggregations / windowing**: 1 window function (`ROW_NUMBER()`)
- **Filters identified**: 2 (`WHERE dq_valid_flag = TRUE`, `QUALIFY ... = 1`)
- **Existing constraints found in object definition**: 0 (no `PRIMARY KEY`, `UNIQUE`, `NOT NULL`, `FOREIGN KEY` declared in procedure)

## Test Case Matrix

| Test Case ID | Category (Happy Path / Edge Case / Exception) | Column/Join/Aggregation | Description | SQL Assertion Type |
|---|---|---|---|---|
| TC_001 | Happy Path | Source filter `dq_valid_flag` | Ensure only `dq_valid_flag = TRUE` rows are eligible for loading (no invalid rows in target attributable to silver invalid flag). | Business-rule/transformation correctness |
| TC_002 | Happy Path | Join `DIM_DATE` on `flight_date` | Validate `date_key` is resolved for loaded records (no null `date_key`). | Not-null |
| TC_003 | Happy Path | Join `DIM_AIRLINE` on `carrier_code` → `airline_code` | Validate `airline_key` is resolved for loaded records (no null `airline_key`). | Not-null |
| TC_004 | Happy Path | Join `DIM_AIRCRAFT` on `tail_number` + effective dates | Validate `aircraft_key` is resolved when an aircraft dimension row exists within the effective date range. | Business-rule/transformation correctness |
| TC_005 | Edge Case | Aircraft effective dating | Ensure no resolved `aircraft_key` maps to an aircraft record that is outside the effective date range (guards against accidental many-to-one or wrong-range join). | Business-rule/transformation correctness |
| TC_006 | Happy Path | Join `DIM_AIRPORT` origin on `origin_airport_code` | Validate `origin_airport_key` is resolved for loaded records. | Not-null |
| TC_007 | Happy Path | Join `DIM_AIRPORT` destination on `destination_airport_code` | Validate `destination_airport_key` is resolved for loaded records. | Not-null |
| TC_008 | Edge Case | De-duplication by `flight_id` | Ensure the dedup logic results in at most one row per `flight_id` in the staged `final_rows` dataset (pre-merge). | Uniqueness |
| TC_009 | Exception | MERGE match key mapping | Detect potential mismatch between `tgt.schedule_id` and `src.flight_id` (business key inconsistency). | Business-rule/transformation correctness |
| TC_010 | Exception | `FACT_FLIGHT_OPERATIONS.schedule_id` uniqueness | Validate `schedule_id` is unique in target (expected for a fact grain / merge key). | Uniqueness |
| TC_011 | Edge Case | Null join keys from source | Ensure source rows with null `flight_date`, `carrier_code`, `tail_number`, `origin_airport_code`, `destination_airport_code` do not silently produce partially-null foreign keys in target. | Business-rule/transformation correctness |
| TC_012 | Happy Path | Audit columns | Ensure audit timestamps are populated (`dw_created_ts`, `dw_updated_ts` not null). | Not-null |

## Generated Snowflake Test Scripts

```sql
-- =====================================================================
-- Test harness notes
-- - These tests assume the procedure has been executed for a given load window.
-- - Replace the placeholders below with concrete values in your environment.
-- =====================================================================

-- Parameters (set before running assertions)
SET P_SILVER_DB     = '<SILVER_DB>';
SET P_SILVER_SCHEMA = '<SILVER_SCHEMA>';
SET P_GOLD_DB       = '<GOLD_DB>';
SET P_GOLD_SCHEMA   = '<GOLD_SCHEMA>';

-- Fully qualified objects
SET TGT_FACT = $P_GOLD_DB || '.' || $P_GOLD_SCHEMA || '.FACT_FLIGHT_OPERATIONS';
SET SRC_SLV  = $P_SILVER_DB || '.' || $P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS';
SET DIM_DATE    = $P_GOLD_DB || '.' || $P_GOLD_SCHEMA || '.DIM_DATE';
SET DIM_AIRLINE = $P_GOLD_DB || '.' || $P_GOLD_SCHEMA || '.DIM_AIRLINE';
SET DIM_AIRCRAFT= $P_GOLD_DB || '.' || $P_GOLD_SCHEMA || '.DIM_AIRCRAFT';
SET DIM_ROUTE   = $P_GOLD_DB || '.' || $P_GOLD_SCHEMA || '.DIM_ROUTE';
SET DIM_AIRPORT = $P_GOLD_DB || '.' || $P_GOLD_SCHEMA || '.DIM_AIRPORT';

-- =====================================================================
-- Reusable assertion stored procedures (parameterized)
-- =====================================================================

CREATE OR REPLACE PROCEDURE util.assert_zero_rows(P_ASSERT_SQL STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  V_CNT NUMBER;
BEGIN
  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (' || P_ASSERT_SQL || ')' INTO :V_CNT;
  IF (V_CNT <> 0) THEN
    RETURN 'FAIL: expected 0 rows but got ' || V_CNT || ' for SQL: ' || P_ASSERT_SQL;
  END IF;
  RETURN 'PASS';
END;
$$;

CREATE OR REPLACE PROCEDURE util.assert_not_null(P_TABLE_FQN STRING, P_COLUMN_NAME STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  V_SQL STRING;
BEGIN
  V_SQL := 'SELECT 1 FROM ' || P_TABLE_FQN || ' WHERE ' || P_COLUMN_NAME || ' IS NULL LIMIT 1';
  RETURN util.assert_zero_rows(V_SQL);
END;
$$;

CREATE OR REPLACE PROCEDURE util.assert_unique(P_TABLE_FQN STRING, P_COLUMN_LIST STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  V_SQL STRING;
BEGIN
  V_SQL := 'SELECT ' || P_COLUMN_LIST || ', COUNT(*) c FROM ' || P_TABLE_FQN ||
           ' GROUP BY ' || P_COLUMN_LIST || ' HAVING COUNT(*) > 1';
  RETURN util.assert_zero_rows(V_SQL);
END;
$$;

-- =====================================================================
-- TC_001: dq_valid_flag filter adherence
-- Business rule: Target rows must originate from dq_valid_flag = TRUE
-- =====================================================================
-- SKIPPED: FACT_FLIGHT_OPERATIONS lineage to SLV_FLIGHT_OPERATIONS — no load watermark / batch id present in target; cannot reliably attribute target rows back to source rows.

-- =====================================================================
-- TC_002: date_key resolved
-- =====================================================================
CALL util.assert_not_null($TGT_FACT, 'date_key');

-- =====================================================================
-- TC_003: airline_key resolved
-- =====================================================================
CALL util.assert_not_null($TGT_FACT, 'airline_key');

-- =====================================================================
-- TC_004: aircraft_key resolved when eligible dimension exists in-range
-- Business rule: If a matching DIM_AIRCRAFT row exists for a given tail_number
-- and flight_date within effective range, then aircraft_key should be populated.
-- =====================================================================
-- SKIPPED: FACT_FLIGHT_OPERATIONS to source flight_date/tail_number — target schema (fact) does not expose flight_date or tail_number to validate effective dating deterministically.

-- =====================================================================
-- TC_005: no out-of-range aircraft mapping
-- =====================================================================
-- SKIPPED: FACT_FLIGHT_OPERATIONS to DIM_AIRCRAFT effective range — cannot evaluate without flight_date + tail_number persisted in target or accessible via a stable join key.

-- =====================================================================
-- TC_006: origin_airport_key resolved
-- =====================================================================
CALL util.assert_not_null($TGT_FACT, 'origin_airport_key');

-- =====================================================================
-- TC_007: destination_airport_key resolved
-- =====================================================================
CALL util.assert_not_null($TGT_FACT, 'destination_airport_key');

-- =====================================================================
-- TC_008: de-duplication by flight_id in final_rows
-- Verify staging logic returns <= 1 row per flight_id
-- =====================================================================
-- SKIPPED: final_rows.flight_id uniqueness — final_rows is a CTE inside the stored procedure and not materialized; cannot be queried externally without refactoring.

-- =====================================================================
-- TC_009: MERGE match key consistency (tgt.schedule_id = src.flight_id)
-- =====================================================================
-- SKIPPED: tgt.schedule_id vs src.flight_id mapping — procedure references src.flight_id but target grain uses schedule_id; without target DDL and/or persisted flight_id, cannot assert correctness.

-- =====================================================================
-- TC_010: schedule_id uniqueness in FACT_FLIGHT_OPERATIONS
-- =====================================================================
CALL util.assert_unique($TGT_FACT, 'schedule_id');

-- =====================================================================
-- TC_011: Null join keys should not yield partially-null foreign keys
-- Practical assertion: if fact row exists then core foreign keys should be present.
-- =====================================================================
CALL util.assert_zero_rows(
  'SELECT 1 FROM ' || $TGT_FACT ||
  ' WHERE date_key IS NULL'
  '    OR airline_key IS NULL'
  '    OR origin_airport_key IS NULL'
  '    OR destination_airport_key IS NULL'
  ' LIMIT 1'
);

-- =====================================================================
-- TC_012: audit timestamps populated
-- =====================================================================
CALL util.assert_not_null($TGT_FACT, 'dw_created_ts');
CALL util.assert_not_null($TGT_FACT, 'dw_updated_ts');

-- =====================================================================
-- Additional referential integrity checks (expected 0 rows)
-- =====================================================================
CALL util.assert_zero_rows(
  'SELECT f.date_key FROM ' || $TGT_FACT || ' f ' ||
  'LEFT JOIN ' || $DIM_DATE || ' d ON f.date_key = d.date_key ' ||
  'WHERE d.date_key IS NULL AND f.date_key IS NOT NULL'
);

CALL util.assert_zero_rows(
  'SELECT f.airline_key FROM ' || $TGT_FACT || ' f ' ||
  'LEFT JOIN ' || $DIM_AIRLINE || ' a ON f.airline_key = a.airline_key ' ||
  'WHERE a.airline_key IS NULL AND f.airline_key IS NOT NULL'
);

CALL util.assert_zero_rows(
  'SELECT f.origin_airport_key FROM ' || $TGT_FACT || ' f ' ||
  'LEFT JOIN ' || $DIM_AIRPORT || ' ao ON f.origin_airport_key = ao.airport_key ' ||
  'WHERE ao.airport_key IS NULL AND f.origin_airport_key IS NOT NULL'
);

CALL util.assert_zero_rows(
  'SELECT f.destination_airport_key FROM ' || $TGT_FACT || ' f ' ||
  'LEFT JOIN ' || $DIM_AIRPORT || ' ad ON f.destination_airport_key = ad.airport_key ' ||
  'WHERE ad.airport_key IS NULL AND f.destination_airport_key IS NOT NULL'
);

-- SKIPPED: FACT_FLIGHT_OPERATIONS.route_key referential integrity — lkp_route join condition is a tautology (r.route_key = r.route_key) and provides no reliable business mapping; cannot assert correct DIM_ROUTE linkage.

-- SKIPPED: FACT_FLIGHT_OPERATIONS.aircraft_key referential integrity — aircraft_key is populated via DIM_AIRCRAFT lookup but fact lacks stable natural keys to validate in-range mapping.

```

## Coverage Notes

- `lkp_route` mapping cannot be validated because the join condition is a tautology (`r.route_key = r.route_key`) and the procedure itself flags the missing `dim_route.route_id` mapping; route-related tests were skipped inline.
- `final_rows` CTE de-duplication by `flight_id` cannot be directly asserted externally because it is not materialized; would require refactoring to persist stage results (e.g., temp table) or expose as a view.
- Aircraft effective-date correctness cannot be asserted from the target fact alone because `flight_date` and `tail_number` are not present in the fact output (as referenced in this procedure), preventing deterministic validation.
- Total skipped-item count: 7
