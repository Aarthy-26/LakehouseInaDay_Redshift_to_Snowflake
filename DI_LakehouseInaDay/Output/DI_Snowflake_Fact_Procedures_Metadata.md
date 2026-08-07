# Gold Fact Stored Procedures — Metadata

This documentation covers the Snowflake stored procedures generated to load **Gold Fact** tables from the **Silver** layer using **Snowflake Scripting (LANGUAGE SQL)**.

## Shared Parameters (all procedures)

| Parameter | Type | Description |
|---|---|---|
| `P_SILVER_DB` | STRING | Database containing Silver schema (source). |
| `P_SILVER_SCHEMA` | STRING | Schema containing Silver tables (source). |
| `P_GOLD_DB` | STRING | Database containing Gold schema (target). |
| `P_GOLD_SCHEMA` | STRING | Schema containing Gold tables (target). |
| `P_AUDIT_TABLE_FQN` | STRING | Fully qualified name of existing shared audit table used for process logging. Not created/modified by these procedures. |
| `P_BATCH_ID` | STRING | Batch identifier for audit traceability. |
| `P_START_TS` | TIMESTAMP | Optional process start timestamp (defaults to `CURRENT_TIMESTAMP()` when NULL). |

## Procedures Generated

### 1) `gold.sp_load_fact_flight_operations`

- **Target table:** `gold.fact_flight_operations`
- **Load type:** Incremental upsert using `MERGE`
- **Source:** `silver.slv_flight_operations` (`dq_valid_flag = TRUE`)
- **Deduplication:** `QUALIFY ROW_NUMBER() OVER (PARTITION BY flight_id ORDER BY updated_ts DESC) = 1`
- **Dimension lookups:**
  - `date_key` from `gold.dim_date` by `dim_date.date = slv_flight_operations.flight_date`
  - `airline_key` from `gold.dim_airline` by `dim_airline.airline_code = slv_flight_operations.carrier_code`
  - `aircraft_key` from `gold.dim_aircraft` point-in-time by tail number and effective dates
  - `origin_airport_key` and `destination_airport_key` from `gold.dim_airport` by airport_code
  - `route_key` mapping is **present in mapping** but **ambiguous** because `gold.dim_route` DDL does not include `route_id`. Procedure uses a placeholder join and will likely require correction.

**Target columns populated**

| Target Column | Target Type (Gold DDL) | Expression / Source |
|---|---|---|
| `date_key` | INTEGER | Lookup `dim_date.date_key` by `flight_date` |
| `airline_key` | INTEGER | Lookup `dim_airline.airline_key` by `carrier_code` |
| `aircraft_key` | INTEGER | Lookup `dim_aircraft.aircraft_key` by `tail_number` and effective dates |
| `route_key` | INTEGER | From dim_route lookup (ambiguous due to missing `route_id` in Gold DDL) |
| `origin_airport_key` | INTEGER | Lookup `dim_airport.airport_key` by `origin_airport_code` |
| `destination_airport_key` | INTEGER | Lookup `dim_airport.airport_key` by `destination_airport_code` |
| `schedule_id` | VARCHAR(50) | `slv_flight_operations.schedule_id` |
| `scheduled_departure_ts` | TIMESTAMP | `slv_flight_operations.scheduled_departure_ts` |
| `actual_departure_ts` | TIMESTAMP | `slv_flight_operations.actual_departure_ts` |
| `scheduled_arrival_ts` | TIMESTAMP | `slv_flight_operations.scheduled_arrival_ts` |
| `actual_arrival_ts` | TIMESTAMP | `slv_flight_operations.actual_arrival_ts` |
| `delay_minutes` | INTEGER | `slv_flight_operations.delay_minutes` |
| `taxi_out_minutes` | INTEGER | `slv_flight_operations.taxi_out_minutes` |
| `taxi_in_minutes` | INTEGER | `slv_flight_operations.taxi_in_minutes` |
| `flight_distance_miles` | NUMBER(10,2) | `slv_flight_operations.flight_distance_miles` |
| `block_hours` | NUMBER(6,2) | `slv_flight_operations.block_hours` |
| `cancelled_flag` | BOOLEAN | `slv_flight_operations.cancelled_flag` |
| `diverted_flag` | BOOLEAN | `slv_flight_operations.diverted_flag` |
| `source_system` | VARCHAR(100) | `slv_flight_operations.source_system` |
| `dw_created_ts` | TIMESTAMP | `CURRENT_TIMESTAMP()` on insert |
| `dw_updated_ts` | TIMESTAMP | `CURRENT_TIMESTAMP()` on update/insert |

### 2) `gold.sp_load_fact_flight_events`

- **Target table:** `gold.fact_flight_events`
- **Load type:** Insert-only (append)
- **Source:** `silver.slv_flight_events` (`dq_valid_flag = TRUE`)
- **Deduplication:** `QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY updated_ts DESC) = 1`

**Target columns populated**

| Target Column | Target Type (Gold DDL) | Expression / Source |
|---|---|---|
| `flight_key` | BIGINT | Derived from joining to `fact_flight_operations` via `slv_flight_operations.schedule_id` and `date_key` (nullable) |
| `event_type_key` | INTEGER | Intended lookup from `dim_event_type` (ambiguous due to missing `event_type_code` in Gold DDL) |
| `date_key` | INTEGER | Lookup `dim_date.date_key` by `CAST(event_timestamp AS DATE)` |
| `event_timestamp` | TIMESTAMP | `slv_flight_events.event_timestamp` |
| `producer_system` | VARCHAR(100) | `slv_flight_events.producer_system` |
| `consumer_system` | VARCHAR(100) | `slv_flight_events.consumer_system` |
| `message_size_bytes` | INTEGER | `slv_flight_events.message_size_bytes` |
| `event_count` | INTEGER | `slv_flight_events.event_count` |
| `source_system` | VARCHAR(100) | `slv_flight_events.source_system` |
| `dw_created_ts` | TIMESTAMP | `CURRENT_TIMESTAMP()` |
| `dw_updated_ts` | TIMESTAMP | `CURRENT_TIMESTAMP()` |

## Notes / Known Gaps Captured Inline

- Any unmapped/ambiguous elements are included in procedure files as `-- SKIPPED:` comments per requirements.
- Dimension lookups that require a code column not present in Gold DDL (e.g., `event_type_code`, `route_id`) will require either:
  - an agreed business key persisted in Gold dimensions, or
  - a separate crosswalk table available in Gold/Silver.
