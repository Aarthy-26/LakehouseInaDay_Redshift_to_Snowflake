# Gold Fact Stored Procedures — Metadata (Snowflake)

Generated from:
- `DI_LakehouseInaDay/Inputs/gold ddl snowflake.txt`
- `DI_LakehouseInaDay/Inputs/silver ddl snowflake.txt`
- `DI_LakehouseInaDay/Inputs/silver_to_gold_mapping(Column_Mapping).csv`

## Procedures generated
- `gold.sp_load_fact_flight_operations`
- `gold.sp_load_fact_flight_events`
- `gold.sp_load_fact_aircraft_utilization`
- `gold.sp_load_fact_route_performance`
- `gold.sp_load_fact_flight_history`
- `gold.sp_load_fact_product_subscriptions`

## Common Parameters
- `P_SILVER_SCHEMA STRING`
- `P_GOLD_SCHEMA STRING`
- `P_AUDIT_TABLE_FQN STRING` (fully qualified `DB.SCHEMA.TABLE`)
- `P_LOAD_MODE STRING DEFAULT 'INCREMENTAL'`

All procedures:
- insert audit start row (status `RUNNING`)
- MERGE into the Gold fact
- insert audit completion row (status `SUCCESS`/`FAILED`)
- on exception: write audit failure and return error payload

---

## gold.sp_load_fact_flight_operations
Target: `GOLD.FACT_FLIGHT_OPERATIONS`

Columns (Gold DDL types):
- FLIGHT_KEY BIGINT (IDENTITY)
- DATE_KEY INTEGER
- AIRLINE_KEY INTEGER
- AIRCRAFT_KEY INTEGER
- ROUTE_KEY INTEGER
- ORIGIN_AIRPORT_KEY INTEGER
- DESTINATION_AIRPORT_KEY INTEGER
- SCHEDULE_ID VARCHAR(50)
- SCHEDULED_DEPARTURE_TS TIMESTAMP
- ACTUAL_DEPARTURE_TS TIMESTAMP
- SCHEDULED_ARRIVAL_TS TIMESTAMP
- ACTUAL_ARRIVAL_TS TIMESTAMP
- DELAY_MINUTES INTEGER
- TAXI_OUT_MINUTES INTEGER
- TAXI_IN_MINUTES INTEGER
- FLIGHT_DISTANCE_MILES NUMBER(10,2)
- BLOCK_HOURS NUMBER(6,2)
- CANCELLED_FLAG BOOLEAN
- DIVERTED_FLAG BOOLEAN
- SOURCE_SYSTEM VARCHAR(100)
- DW_CREATED_TS TIMESTAMP
- DW_UPDATED_TS TIMESTAMP

Inline skips:
- route_key lookup (missing DIM_ROUTE natural key in Gold DDL)

---

## gold.sp_load_fact_flight_events
Target: `GOLD.FACT_FLIGHT_EVENTS`

Columns:
- EVENT_KEY BIGINT (IDENTITY)
- FLIGHT_KEY BIGINT
- EVENT_TYPE_KEY INTEGER
- DATE_KEY INTEGER
- EVENT_TIMESTAMP TIMESTAMP
- PRODUCER_SYSTEM VARCHAR(100)
- CONSUMER_SYSTEM VARCHAR(100)
- MESSAGE_SIZE_BYTES INTEGER
- EVENT_COUNT INTEGER
- SOURCE_SYSTEM VARCHAR(100)
- DW_CREATED_TS TIMESTAMP
- DW_UPDATED_TS TIMESTAMP

Inline skips:
- event_type_key lookup (Gold DIM_EVENT_TYPE lacks event_type_code)
- flight_key lookup (Gold FACT_FLIGHT_OPERATIONS lacks flight_id)

---

## gold.sp_load_fact_aircraft_utilization
Target: `GOLD.FACT_AIRCRAFT_UTILIZATION`

Columns:
- UTILIZATION_KEY BIGINT (IDENTITY)
- DATE_KEY INTEGER
- AIRCRAFT_KEY INTEGER
- OPERATOR_AIRLINE_KEY INTEGER
- FLIGHT_COUNT INTEGER
- UTILIZATION_HOURS NUMBER(10,2)
- GROUND_HOURS NUMBER(10,2)
- MAINTENANCE_HOURS NUMBER(10,2)
- AVAILABLE_HOURS NUMBER(10,2)
- TOTAL_LABOR_HOURS NUMBER(10,2)
- TOTAL_PARTS_USED INTEGER
- TOTAL_DISCREPANCIES INTEGER
- AVERAGE_DELAY_MINUTES NUMBER(10,2)
- SOURCE_SYSTEM VARCHAR(100)
- DW_CREATED_TS TIMESTAMP
- DW_UPDATED_TS TIMESTAMP

Inline skips:
- ground_hours, available_hours (insufficient explicit business rule)

---

## gold.sp_load_fact_route_performance
Target: `GOLD.FACT_ROUTE_PERFORMANCE`

Columns:
- ROUTE_PERF_KEY BIGINT (IDENTITY)
- DATE_KEY INTEGER
- ROUTE_KEY INTEGER
- FLIGHT_COUNT INTEGER
- DELAY_COUNT INTEGER
- CANCEL_COUNT INTEGER
- AVG_DELAY_MINUTES NUMBER(10,2)
- OTP_PERCENTAGE NUMBER(5,2)
- SOURCE_SYSTEM VARCHAR(100)
- DW_CREATED_TS TIMESTAMP
- DW_UPDATED_TS TIMESTAMP

Inline skips:
- route_key lookup (missing DIM_ROUTE natural key in Gold DDL)

---

## gold.sp_load_fact_flight_history
Target: `GOLD.FACT_FLIGHT_HISTORY`

Columns:
- HISTORY_KEY BIGINT (IDENTITY)
- FLIGHT_KEY BIGINT
- AIRLINE_KEY INTEGER
- ROUTE_KEY INTEGER
- DATE_KEY INTEGER
- DELAY_MINUTES INTEGER
- CANCELLED_FLAG BOOLEAN
- LOAD_FACTOR NUMBER(5,2)
- DATA_SOURCE VARCHAR(100)
- DW_CREATED_TS TIMESTAMP
- DW_UPDATED_TS TIMESTAMP

Inline skips:
- route_key lookup (missing DIM_ROUTE natural key in Gold DDL)
- flight_key lookup (no operational flight identifiers in Gold)

---

## gold.sp_load_fact_product_subscriptions
Target: `GOLD.FACT_PRODUCT_SUBSCRIPTIONS`

Columns:
- SUBSCRIPTION_KEY BIGINT (IDENTITY)
- CUSTOMER_KEY INTEGER
- PRODUCT_KEY INTEGER
- START_DATE DATE
- END_DATE DATE
- SUBSCRIPTION_TIER VARCHAR(50)
- SUBSCRIPTION_STATUS VARCHAR(50)
- SOURCE_SYSTEM VARCHAR(100)
- DW_CREATED_TS TIMESTAMP
- DW_UPDATED_TS TIMESTAMP

Inline skips:
- customer_key lookup (Gold DIM_CUSTOMER lacks customer_id)
- product_key lookup (Gold DIM_DATA_PRODUCT lacks product_code)
