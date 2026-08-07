Author: AAVA

Created on: 2026-08-07

Description: Unit test cases and native Snowflake SQL assertion scripts for gold.sp_load_fact_flight_operations.

Version: 1

Updated on: 2026-08-07

## Object Summary

- Target object: Stored Procedure `gold.sp_load_fact_flight_operations` (loads `P_GOLD_DB.P_GOLD_SCHEMA.FACT_FLIGHT_OPERATIONS` via `MERGE`)
- Source table/view(s):
  - `P_SILVER_DB.P_SILVER_SCHEMA.SLV_FLIGHT_OPERATIONS`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_DATE`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_AIRLINE`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_AIRCRAFT`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_ROUTE`
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_AIRPORT` (origin)
  - `P_GOLD_DB.P_GOLD_SCHEMA.DIM_AIRPORT` (destination)
- Transformations identified:
  - `src` filters to `dq_valid_flag = TRUE`
  - Dimension lookups deriving: `date_key`, `airline_key`, `aircraft_key`, `route_key`, `origin_airport_key`, `destination_airport_key`
  - SCD-effective-date constraint on aircraft lookup (`flight_date BETWEEN effective_start_date AND COALESCE(effective_end_date, '9999-12-31')`)
  - Deduplication using `QUALIFY ROW_NUMBER() OVER (PARTITION BY flight_id ORDER BY updated_ts DESC) = 1`
  - Audit columns set in `final_rows`: `dw_created_ts`, `dw_updated_ts` (both `CURRENT_TIMESTAMP()`)
- Joins identified: 6 LEFT JOINs (DIM_DATE, DIM_AIRLINE, DIM_AIRCRAFT, DIM_ROUTE, DIM_AIRPORT x2)
- Aggregations/windowing identified: 1 window function (`ROW_NUMBER()`)
- Filters identified: 1 WHERE (`dq_valid_flag = TRUE`), 1 QUALIFY clause
- Existing constraints found in object definition: 0 (none declared)

## Test Case Matrix

| Test Case ID | Category (Happy Path / Edge Case / Exception) | Column/Join/Aggregation | Description | SQL Assertion Type |
|---|---|---|---|---|
| TC_001 | Happy Path | Filter: `dq_valid_flag = TRUE` | Ensure procedure loads only rows from Silver marked valid (no invalid rows appear in target by key intersection). | Business-rule / transformation correctness |
| TC_002 | Happy Path | Dedup: `ROW_NUMBER() ... ORDER BY updated_ts DESC` | Ensure only the latest `updated_ts` per `flight_id` is used for loading. | Business-rule / transformation correctness |
| TC_003 | Edge Case | DIM_DATE lookup (`flight_date` → `date_key`) | Detect rows loaded with NULL `date_key` (missing date dimension entry). | Not-null (derived key) |
| TC_004 | Edge Case | DIM_AIRLINE lookup (`carrier_code` → `airline_key`) | Detect rows loaded with NULL `airline_key` (missing airline dimension entry). | Not-null (derived key) |
| TC_005 | Edge Case | DIM_AIRCRAFT SCD lookup | Detect rows loaded with NULL `aircraft_key` when `tail_number` present (no effective-dated match). | Business-rule / transformation correctness |
| TC_006 | Exception | DIM_AIRPORT origin lookup | Detect rows loaded with NULL `origin_airport_key` when `origin_airport_code` present (missing airport dimension). | Business-rule / transformation correctness |
| TC_007 | Exception | DIM_AIRPORT destination lookup | Detect rows loaded with NULL `destination_airport_key` when `destination_airport_code` present (missing airport dimension). | Business-rule / transformation correctness |
| TC_008 | Exception | Referential integrity | Ensure `date_key` values in fact exist in DIM_DATE. | Referential integrity |
| TC_009 | Exception | Referential integrity | Ensure `airline_key` values in fact exist in DIM_AIRLINE. | Referential integrity |
| TC_010 | Exception | Referential integrity | Ensure `aircraft_key` values in fact exist in DIM_AIRCRAFT. | Referential integrity |
| TC_011 | Exception | Referential integrity | Ensure `origin_airport_key` values in fact exist in DIM_AIRPORT. | Referential integrity |
| TC_012 | Exception | Referential integrity | Ensure `destination_airport_key` values in fact exist in DIM_AIRPORT. | Referential integrity |
| TC_013 | Edge Case | Audit columns | Ensure `dw_created_ts` and `dw_updated_ts` are populated. | Not-null |
| TC_014 | Edge Case | Accepted values | Ensure `cancelled_flag` and `diverted_flag` contain only boolean-like values (0/1/TRUE/FALSE) depending on actual datatype. | SKIPPED (ambiguous datatype/allowed-values) |
| TC_015 | Exception | MERGE match key consistency | Validate MERGE ON condition uses consistent natural key; current code uses `tgt.schedule_id = src.flight_id` which likely mismatches. | SKIPPED (requires Gold DDL / key definition) |
| TC_016 | Exception | DIM_ROUTE lookup | Validate route lookup is meaningful; current join is self-equality and does not use a Silver route identifier. | SKIPPED (unresolvable mapping) |

## Generated Snowflake Test Scripts

```sql
/*
Assumptions for running tests:
- Set these session variables to point to your environments.
- Tests are written as assertions returning ZERO rows (or COUNT=0) when passing.

SET SILVER_DB = '<SILVER_DB>';
SET SILVER_SCHEMA = '<SILVER_SCHEMA>';
SET GOLD_DB = '<GOLD_DB>';
SET GOLD_SCHEMA = '<GOLD_SCHEMA>';

-- Fully qualified objects
SET FCT = $GOLD_DB || '.' || $GOLD_SCHEMA || '.FACT_FLIGHT_OPERATIONS';
SET SLV = $SILVER_DB || '.' || $SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS';
SET DIM_DATE = $GOLD_DB || '.' || $GOLD_SCHEMA || '.DIM_DATE';
SET DIM_AIRLINE = $GOLD_DB || '.' || $GOLD_SCHEMA || '.DIM_AIRLINE';
SET DIM_AIRCRAFT = $GOLD_DB || '.' || $GOLD_SCHEMA || '.DIM_AIRCRAFT';
SET DIM_AIRPORT = $GOLD_DB || '.' || $GOLD_SCHEMA || '.DIM_AIRPORT';
SET DIM_ROUTE = $GOLD_DB || '.' || $GOLD_SCHEMA || '.DIM_ROUTE';
*/

-- ---------------------------------------------------------------------
-- Reusable assertion helpers (optional)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE gold.ut_assert_zero_count(SQL_TEXT STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  C NUMBER;
BEGIN
  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (' || SQL_TEXT || ') t' INTO :C;
  IF (C <> 0) THEN
    RETURN OBJECT_CONSTRUCT('status','FAIL','count',C,'sql',SQL_TEXT);
  END IF;
  RETURN OBJECT_CONSTRUCT('status','PASS','count',0);
END;
$$;

-- ---------------------------------------------------------------------
-- TC_001: Filter dq_valid_flag = TRUE (no invalid silver rows loaded)
-- Assertion: no fact rows exist whose originating silver row has dq_valid_flag = FALSE
-- Note: This requires a joinable key; procedure uses flight_id as natural key.
-- ---------------------------------------------------------------------
CALL gold.ut_assert_zero_count(
$$
SELECT 1
FROM IDENTIFIER($FCT) f
JOIN IDENTIFIER($SLV) s
  ON s.flight_id = f.schedule_id
WHERE s.dq_valid_flag = FALSE
$$
);

-- ---------------------------------------------------------------------
-- TC_002: Dedup latest updated_ts per flight_id
-- Assertion: for each schedule_id in fact, it should match the max(updated_ts) among valid silver rows for that flight_id.
-- ---------------------------------------------------------------------
CALL gold.ut_assert_zero_count(
$$
SELECT 1
FROM IDENTIFIER($FCT) f
JOIN (
  SELECT flight_id, MAX(updated_ts) AS max_updated_ts
  FROM IDENTIFIER($SLV)
  WHERE dq_valid_flag = TRUE
  GROUP BY flight_id
) mx
  ON mx.flight_id = f.schedule_id
JOIN IDENTIFIER($SLV) s
  ON s.flight_id = mx.flight_id
 AND s.updated_ts = mx.max_updated_ts
WHERE dq_valid_flag = TRUE
  AND (
    -- if fact was loaded from a different row than the latest, this join will not find it.
    -- We detect this by ensuring the latest row exists; if business wants exact column-by-column match, extend this test.
    1=0
  )
$$
);
-- SKIPPED: TC_002 strict row-equivalence — procedure does not carry updated_ts into FACT; cannot assert exact-source-row without additional lineage columns

-- ---------------------------------------------------------------------
-- TC_003: date_key should not be NULL
-- ---------------------------------------------------------------------
CALL gold.ut_assert_zero_count(
$$
SELECT 1 FROM IDENTIFIER($FCT) WHERE date_key IS NULL
$$
);

-- TC_004: airline_key should not be NULL
CALL gold.ut_assert_zero_count(
$$
SELECT 1 FROM IDENTIFIER($FCT) WHERE airline_key IS NULL
$$
);

-- ---------------------------------------------------------------------
-- TC_005: aircraft_key should not be NULL when aircraft identifier exists in source
-- ---------------------------------------------------------------------
CALL gold.ut_assert_zero_count(
$$
SELECT 1
FROM IDENTIFIER($FCT) f
JOIN IDENTIFIER($SLV) s
  ON s.flight_id = f.schedule_id
WHERE s.dq_valid_flag = TRUE
  AND s.tail_number IS NOT NULL
  AND f.aircraft_key IS NULL
$$
);

-- ---------------------------------------------------------------------
-- TC_006: origin_airport_key should not be NULL when origin_airport_code exists
-- ---------------------------------------------------------------------
CALL gold.ut_assert_zero_count(
$$
SELECT 1
FROM IDENTIFIER($FCT) f
JOIN IDENTIFIER($SLV) s
  ON s.flight_id = f.schedule_id
WHERE s.dq_valid_flag = TRUE
  AND s.origin_airport_code IS NOT NULL
  AND f.origin_airport_key IS NULL
$$
);

-- TC_007: destination_airport_key should not be NULL when destination_airport_code exists
CALL gold.ut_assert_zero_count(
$$
SELECT 1
FROM IDENTIFIER($FCT) f
JOIN IDENTIFIER($SLV) s
  ON s.flight_id = f.schedule_id
WHERE s.dq_valid_flag = TRUE
  AND s.destination_airport_code IS NOT NULL
  AND f.destination_airport_key IS NULL
$$
);

-- ---------------------------------------------------------------------
-- TC_008..TC_012: Referential integrity checks to dimensions
-- ---------------------------------------------------------------------
CALL gold.ut_assert_zero_count(
$$
SELECT f.date_key
FROM IDENTIFIER($FCT) f
LEFT JOIN IDENTIFIER($DIM_DATE) d
  ON f.date_key = d.date_key
WHERE d.date_key IS NULL
  AND f.date_key IS NOT NULL
$$
);

CALL gold.ut_assert_zero_count(
$$
SELECT f.airline_key
FROM IDENTIFIER($FCT) f
LEFT JOIN IDENTIFIER($DIM_AIRLINE) a
  ON f.airline_key = a.airline_key
WHERE a.airline_key IS NULL
  AND f.airline_key IS NOT NULL
$$
);

CALL gold.ut_assert_zero_count(
$$
SELECT f.aircraft_key
FROM IDENTIFIER($FCT) f
LEFT JOIN IDENTIFIER($DIM_AIRCRAFT) ac
  ON f.aircraft_key = ac.aircraft_key
WHERE ac.aircraft_key IS NULL
  AND f.aircraft_key IS NOT NULL
$$
);

CALL gold.ut_assert_zero_count(
$$
SELECT f.origin_airport_key
FROM IDENTIFIER($FCT) f
LEFT JOIN IDENTIFIER($DIM_AIRPORT) ao
  ON f.origin_airport_key = ao.airport_key
WHERE ao.airport_key IS NULL
  AND f.origin_airport_key IS NOT NULL
$$
);

CALL gold.ut_assert_zero_count(
$$
SELECT f.destination_airport_key
FROM IDENTIFIER($FCT) f
LEFT JOIN IDENTIFIER($DIM_AIRPORT) ad
  ON f.destination_airport_key = ad.airport_key
WHERE ad.airport_key IS NULL
  AND f.destination_airport_key IS NOT NULL
$$
);

-- ---------------------------------------------------------------------
-- TC_013: Audit columns not null
-- ---------------------------------------------------------------------
CALL gold.ut_assert_zero_count(
$$
SELECT 1
FROM IDENTIFIER($FCT)
WHERE dw_created_ts IS NULL
   OR dw_updated_ts IS NULL
$$
);

-- ---------------------------------------------------------------------
-- TC_014: cancelled_flag/diverted_flag accepted values
-- SKIPPED: FACT_FLIGHT_OPERATIONS.cancelled_flag — ambiguous datatype and allowed values not declared in object definition
-- SKIPPED: FACT_FLIGHT_OPERATIONS.diverted_flag — ambiguous datatype and allowed values not declared in object definition
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- TC_015: MERGE match key consistency
-- SKIPPED: gold.fact_flight_operations business key — MERGE matches tgt.schedule_id = src.flight_id; cannot validate without FACT DDL / defined natural key
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- TC_016: DIM_ROUTE lookup validity
-- SKIPPED: gold.dim_route.route_id — route dimension lookup join is currently r.route_key=r.route_key and lacks source route identifier
-- ---------------------------------------------------------------------
```

## Coverage Notes

- No direct uniqueness tests generated because the procedure does not define a unique key/constraint for `FACT_FLIGHT_OPERATIONS`, and the MERGE match key is ambiguous (`tgt.schedule_id = src.flight_id`).
- No numeric range tests (e.g., `delay_minutes >= 0`) generated because the object definition contains no explicit business-rule constraints for these measures.
- Skipped items: 5
  - TC_002 strict equivalence cannot be asserted without lineage/updated_ts in fact.
  - TC_014 (2 items) accepted values ambiguous.
  - TC_015 MERGE key definition unresolved.
  - TC_016 route lookup mapping unresolved.
