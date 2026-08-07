-- ============================================================================
-- File: DI_Snowflake_Fact_sp_gold_fact_flight.sql
-- Purpose: Snowflake Stored Procedures to load GOLD Fact tables from SILVER.
-- Notes:
--   * Snowflake-only SQL / Snowflake Scripting (LANGUAGE SQL)
--   * Uses MERGE for upsert/incremental load
--   * Audit logging: writes to shared audit table passed as a parameter
--   * Mapping source: DI_LakehouseInaDay/Inputs/silver_to_gold_mapping(Column_Mapping).csv
-- ============================================================================

-- ============================================================================
-- STORED PROCEDURE: gold.sp_load_fact_flight_operations
-- Target: gold.fact_flight_operations
-- ============================================================================
CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_operations(
    P_SILVER_DB STRING,
    P_SILVER_SCHEMA STRING,
    P_GOLD_DB STRING,
    P_GOLD_SCHEMA STRING,
    P_AUDIT_TABLE_FQN STRING,
    P_BATCH_ID STRING,
    P_START_TS TIMESTAMP
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_operations';
    V_TARGET_FQN STRING;
    V_AUDIT_FQN STRING;
    V_SQL STRING;

    V_SRC_CNT NUMBER DEFAULT 0;
    V_MERGE_INS NUMBER DEFAULT 0;
    V_MERGE_UPD NUMBER DEFAULT 0;
    V_STATUS STRING DEFAULT 'RUNNING';
    V_ERROR_MSG STRING;
BEGIN
    V_TARGET_FQN := P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.FACT_FLIGHT_OPERATIONS';
    V_AUDIT_FQN  := P_AUDIT_TABLE_FQN;

    -- --------------------------
    -- AUDIT: start
    -- --------------------------
    IF (UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN)) THEN
        V_SQL := 'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, batch_id, start_ts, status) ' ||
                 'SELECT ?, ?, ?, ?, ?';
        EXECUTE IMMEDIATE :V_SQL USING (V_PROC_NAME, V_TARGET_FQN, P_BATCH_ID, COALESCE(P_START_TS, CURRENT_TIMESTAMP()), V_STATUS);
    END IF;

    -- --------------------------
    -- DQ ASSERTIONS (do not silently drop): validate required dims exist
    -- --------------------------
    -- Validate dim_date coverage for silver flight dates
    V_SQL := 'WITH s AS (\n' ||
             '  SELECT DISTINCT flight_date AS d\n' ||
             '  FROM ' || P_SILVER_DB || '.' || P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS\n' ||
             '  WHERE dq_valid_flag = TRUE AND flight_date IS NOT NULL\n' ||
             ')\n' ||
             'SELECT COUNT(*)\n' ||
             'FROM s\n' ||
             'LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_DATE dd\n' ||
             '  ON dd.date = s.d\n' ||
             'WHERE dd.date_key IS NULL';
    EXECUTE IMMEDIATE :V_SQL INTO :V_SRC_CNT;
    IF (V_SRC_CNT > 0) THEN
        V_ERROR_MSG := 'dim_date missing for ' || V_SRC_CNT || ' distinct flight_date values.';
        IF (UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN)) THEN
            V_SQL := 'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, batch_id, start_ts, end_ts, status, error_message) ' ||
                     'SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP(), ?, ?';
            EXECUTE IMMEDIATE :V_SQL USING (V_PROC_NAME, V_TARGET_FQN, P_BATCH_ID, COALESCE(P_START_TS, CURRENT_TIMESTAMP()), 'FAILED', V_ERROR_MSG);
        END IF;
        RAISE STATEMENT_ERROR WITH MESSAGE = V_ERROR_MSG;
    END IF;

    -- Source count (post dq_valid_flag)
    V_SQL := 'SELECT COUNT(*) FROM ' || P_SILVER_DB || '.' || P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS WHERE dq_valid_flag = TRUE';
    EXECUTE IMMEDIATE :V_SQL INTO :V_SRC_CNT;

    -- --------------------------
    -- MERGE into target
    -- Natural key for upsert isn't present on Gold fact (flight_key is surrogate).
    -- Implemented as business-key match using schedule_id + date_key + airline_key + origin/destination.
    -- SKIPPED: gold.fact_flight_operations.<natural_key> — no explicit natural key column exists in Gold DDL; using composite business key for MERGE match.
    -- --------------------------
    V_SQL :=
    'MERGE INTO ' || V_TARGET_FQN || ' AS T\n' ||
    'USING (\n' ||
    '  WITH src AS (\n' ||
    '    SELECT\n' ||
    '      s.flight_id,\n' ||
    '      s.schedule_id,\n' ||
    '      s.flight_date,\n' ||
    '      s.carrier_code,\n' ||
    '      s.tail_number,\n' ||
    '      s.origin_airport_code,\n' ||
    '      s.destination_airport_code,\n' ||
    '      s.route_id,\n' ||
    '      s.scheduled_departure_ts,\n' ||
    '      s.actual_departure_ts,\n' ||
    '      s.scheduled_arrival_ts,\n' ||
    '      s.actual_arrival_ts,\n' ||
    '      s.delay_minutes,\n' ||
    '      s.taxi_out_minutes,\n' ||
    '      s.taxi_in_minutes,\n' ||
    '      s.flight_distance_miles,\n' ||
    '      s.block_hours,\n' ||
    '      s.cancelled_flag,\n' ||
    '      s.diverted_flag,\n' ||
    '      s.source_system,\n' ||
    '      s.created_ts,\n' ||
    '      s.updated_ts\n' ||
    '    FROM ' || P_SILVER_DB || '.' || P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS s\n' ||
    '    WHERE s.dq_valid_flag = TRUE\n' ||
    '  ),\n' ||
    '  -- DEDUPE: keep latest per flight_id\n' ||
    '  dedup AS (\n' ||
    '    SELECT *\n' ||
    '    FROM src\n' ||
    '    QUALIFY ROW_NUMBER() OVER (PARTITION BY flight_id ORDER BY updated_ts DESC) = 1\n' ||
    '  ),\n' ||
    '  lk AS (\n' ||
    '    SELECT\n' ||
    '      dd.date_key AS date_key,\n' ||
    '      da.airline_key AS airline_key,\n' ||
    '      dr.route_key AS route_key,\n' ||
    '      ao.airport_key AS origin_airport_key,\n' ||
    '      ad.airport_key AS destination_airport_key,\n' ||
    '      dac.aircraft_key AS aircraft_key,\n' ||
    '      d.schedule_id,\n' ||
    '      d.scheduled_departure_ts,\n' ||
    '      d.actual_departure_ts,\n' ||
    '      d.scheduled_arrival_ts,\n' ||
    '      d.actual_arrival_ts,\n' ||
    '      d.delay_minutes,\n' ||
    '      d.taxi_out_minutes,\n' ||
    '      d.taxi_in_minutes,\n' ||
    '      d.flight_distance_miles,\n' ||
    '      d.block_hours,\n' ||
    '      d.cancelled_flag,\n' ||
    '      d.diverted_flag,\n' ||
    '      d.source_system,\n' ||
    '      d.created_ts,\n' ||
    '      d.updated_ts\n' ||
    '    FROM dedup d\n' ||
    '    LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_DATE dd\n' ||
    '      ON dd.date = d.flight_date\n' ||
    '    LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_AIRLINE da\n' ||
    '      ON da.airline_code = d.carrier_code\n' ||
    '    LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_ROUTE dr\n' ||
    '      ON dr.route_key IS NOT NULL\n' ||
    '    LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_AIRPORT ao\n' ||
    '      ON ao.airport_code = d.origin_airport_code\n' ||
    '    LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_AIRPORT ad\n' ||
    '      ON ad.airport_code = d.destination_airport_code\n' ||
    '    LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_ROUTE r\n' ||
    '      ON r.route_key = dr.route_key\n' ||
    '    LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_AIRCRAFT dac\n' ||
    '      ON dac.tail_number = d.tail_number\n' ||
    '     AND d.flight_date BETWEEN dac.effective_start_date AND COALESCE(dac.effective_end_date, ''9999-12-31'')\n' ||
    '  )\n' ||
    '  SELECT\n' ||
    '    date_key,\n' ||
    '    airline_key,\n' ||
    '    aircraft_key,\n' ||
    '    route_key,\n' ||
    '    origin_airport_key,\n' ||
    '    destination_airport_key,\n' ||
    '    schedule_id,\n' ||
    '    scheduled_departure_ts,\n' ||
    '    actual_departure_ts,\n' ||
    '    scheduled_arrival_ts,\n' ||
    '    actual_arrival_ts,\n' ||
    '    delay_minutes,\n' ||
    '    taxi_out_minutes,\n' ||
    '    taxi_in_minutes,\n' ||
    '    flight_distance_miles,\n' ||
    '    block_hours,\n' ||
    '    cancelled_flag,\n' ||
    '    diverted_flag,\n' ||
    '    source_system,\n' ||
    '    created_ts AS dw_created_ts,\n' ||
    '    updated_ts AS dw_updated_ts\n' ||
    '  FROM lk\n' ||
    ') AS S\n' ||
    'ON (\n' ||
    '  NVL(T.schedule_id, ''~'') = NVL(S.schedule_id, ''~'')\n' ||
    '  AND T.date_key = S.date_key\n' ||
    '  AND NVL(T.airline_key, -1) = NVL(S.airline_key, -1)\n' ||
    '  AND NVL(T.origin_airport_key, -1) = NVL(S.origin_airport_key, -1)\n' ||
    '  AND NVL(T.destination_airport_key, -1) = NVL(S.destination_airport_key, -1)\n' ||
    ')\n' ||
    'WHEN MATCHED THEN UPDATE SET\n' ||
    '  aircraft_key = S.aircraft_key,\n' ||
    '  route_key = S.route_key,\n' ||
    '  scheduled_departure_ts = S.scheduled_departure_ts,\n' ||
    '  actual_departure_ts = S.actual_departure_ts,\n' ||
    '  scheduled_arrival_ts = S.scheduled_arrival_ts,\n' ||
    '  actual_arrival_ts = S.actual_arrival_ts,\n' ||
    '  delay_minutes = S.delay_minutes,\n' ||
    '  taxi_out_minutes = S.taxi_out_minutes,\n' ||
    '  taxi_in_minutes = S.taxi_in_minutes,\n' ||
    '  flight_distance_miles = S.flight_distance_miles,\n' ||
    '  block_hours = S.block_hours,\n' ||
    '  cancelled_flag = S.cancelled_flag,\n' ||
    '  diverted_flag = S.diverted_flag,\n' ||
    '  source_system = S.source_system,\n' ||
    '  dw_updated_ts = CURRENT_TIMESTAMP()\n' ||
    'WHEN NOT MATCHED THEN INSERT (\n' ||
    '  date_key, airline_key, aircraft_key, route_key, origin_airport_key, destination_airport_key,\n' ||
    '  schedule_id, scheduled_departure_ts, actual_departure_ts, scheduled_arrival_ts, actual_arrival_ts,\n' ||
    '  delay_minutes, taxi_out_minutes, taxi_in_minutes, flight_distance_miles, block_hours,\n' ||
    '  cancelled_flag, diverted_flag, source_system, dw_created_ts, dw_updated_ts\n' ||
    ') VALUES (\n' ||
    '  S.date_key, S.airline_key, S.aircraft_key, S.route_key, S.origin_airport_key, S.destination_airport_key,\n' ||
    '  S.schedule_id, S.scheduled_departure_ts, S.actual_departure_ts, S.scheduled_arrival_ts, S.actual_arrival_ts,\n' ||
    '  S.delay_minutes, S.taxi_out_minutes, S.taxi_in_minutes, S.flight_distance_miles, S.block_hours,\n' ||
    '  S.cancelled_flag, S.diverted_flag, S.source_system, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()\n' ||
    ')';

    EXECUTE IMMEDIATE :V_SQL;

    V_STATUS := 'SUCCESS';

    -- --------------------------
    -- AUDIT: end (row counts unavailable without RESULT_SCAN on MERGE; emit source count only)
    -- --------------------------
    IF (UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN)) THEN
        V_SQL := 'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, batch_id, start_ts, end_ts, status, source_row_count, inserted_count, updated_count) ' ||
                 'SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP(), ?, ?, ?, ?';
        EXECUTE IMMEDIATE :V_SQL USING (V_PROC_NAME, V_TARGET_FQN, P_BATCH_ID, COALESCE(P_START_TS, CURRENT_TIMESTAMP()), V_STATUS, V_SRC_CNT, V_MERGE_INS, V_MERGE_UPD);
    END IF;

    RETURN OBJECT_CONSTRUCT('procedure', V_PROC_NAME, 'target', V_TARGET_FQN, 'status', V_STATUS, 'source_row_count', V_SRC_CNT);

EXCEPTION
    WHEN OTHER THEN
        V_STATUS := 'FAILED';
        V_ERROR_MSG := SQLERRM;
        IF (UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN)) THEN
            V_SQL := 'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, batch_id, start_ts, end_ts, status, error_message) ' ||
                     'SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP(), ?, ?';
            EXECUTE IMMEDIATE :V_SQL USING (V_PROC_NAME, V_TARGET_FQN, P_BATCH_ID, COALESCE(P_START_TS, CURRENT_TIMESTAMP()), V_STATUS, V_ERROR_MSG);
        END IF;
        RETURN OBJECT_CONSTRUCT('procedure', V_PROC_NAME, 'target', V_TARGET_FQN, 'status', V_STATUS, 'error', V_ERROR_MSG);
END;
$$;

-- ============================================================================
-- STORED PROCEDURE: gold.sp_load_fact_flight_events
-- Target: gold.fact_flight_events
-- ============================================================================
CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_events(
    P_SILVER_DB STRING,
    P_SILVER_SCHEMA STRING,
    P_GOLD_DB STRING,
    P_GOLD_SCHEMA STRING,
    P_AUDIT_TABLE_FQN STRING,
    P_BATCH_ID STRING,
    P_START_TS TIMESTAMP
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_events';
    V_TARGET_FQN STRING;
    V_AUDIT_FQN STRING;
    V_SQL STRING;

    V_SRC_CNT NUMBER DEFAULT 0;
    V_STATUS STRING DEFAULT 'RUNNING';
    V_ERROR_MSG STRING;
BEGIN
    V_TARGET_FQN := P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.FACT_FLIGHT_EVENTS';
    V_AUDIT_FQN  := P_AUDIT_TABLE_FQN;

    IF (UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN)) THEN
        V_SQL := 'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, batch_id, start_ts, status) SELECT ?, ?, ?, ?, ?';
        EXECUTE IMMEDIATE :V_SQL USING (V_PROC_NAME, V_TARGET_FQN, P_BATCH_ID, COALESCE(P_START_TS, CURRENT_TIMESTAMP()), V_STATUS);
    END IF;

    V_SQL := 'SELECT COUNT(*) FROM ' || P_SILVER_DB || '.' || P_SILVER_SCHEMA || '.SLV_FLIGHT_EVENTS WHERE dq_valid_flag = TRUE';
    EXECUTE IMMEDIATE :V_SQL INTO :V_SRC_CNT;

    -- Append-only fact; MERGE based on event natural id (event_id) is not present on Gold.
    -- SKIPPED: gold.fact_flight_events.<event_natural_id> — Gold DDL has no event_id; using composite (event_timestamp, producer_system, consumer_system, message_size_bytes) is ambiguous.
    -- Implemented as INSERT-only with dedupe on Silver event_id within the batch.

    V_SQL :=
    'INSERT INTO ' || V_TARGET_FQN || ' (\n' ||
    '  flight_key, event_type_key, date_key, event_timestamp, producer_system, consumer_system, message_size_bytes, event_count, source_system, dw_created_ts, dw_updated_ts\n' ||
    ')\n' ||
    'WITH src AS (\n' ||
    '  SELECT\n' ||
    '    e.event_id,\n' ||
    '    e.flight_id,\n' ||
    '    e.event_type_code,\n' ||
    '    e.event_timestamp,\n' ||
    '    e.producer_system,\n' ||
    '    e.consumer_system,\n' ||
    '    e.message_size_bytes,\n' ||
    '    e.event_count,\n' ||
    '    e.source_system,\n' ||
    '    e.created_ts,\n' ||
    '    e.updated_ts\n' ||
    '  FROM ' || P_SILVER_DB || '.' || P_SILVER_SCHEMA || '.SLV_FLIGHT_EVENTS e\n' ||
    '  WHERE e.dq_valid_flag = TRUE\n' ||
    '),\n' ||
    'dedup AS (\n' ||
    '  SELECT * FROM src\n' ||
    '  QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY updated_ts DESC) = 1\n' ||
    '),\n' ||
    'lk AS (\n' ||
    '  SELECT\n' ||
    '    f.flight_key AS flight_key,\n' ||
    '    det.event_type_key AS event_type_key,\n' ||
    '    dd.date_key AS date_key,\n' ||
    '    d.event_timestamp,\n' ||
    '    d.producer_system,\n' ||
    '    d.consumer_system,\n' ||
    '    d.message_size_bytes,\n' ||
    '    d.event_count,\n' ||
    '    d.source_system,\n' ||
    '    d.created_ts AS dw_created_ts,\n' ||
    '    d.updated_ts AS dw_updated_ts\n' ||
    '  FROM dedup d\n' ||
    '  LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_DATE dd\n' ||
    '    ON dd.date = CAST(d.event_timestamp AS DATE)\n' ||
    '  LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_EVENT_TYPE det\n' ||
    '    ON det.event_type_name = det.event_type_name\n' ||
    '  LEFT JOIN ' || P_SILVER_DB || '.' || P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS sfo\n' ||
    '    ON sfo.flight_id = d.flight_id\n' ||
    '  LEFT JOIN ' || P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.FACT_FLIGHT_OPERATIONS f\n' ||
    '    ON f.schedule_id = sfo.schedule_id\n' ||
    '   AND f.date_key = dd.date_key\n' ||
    ')\n' ||
    'SELECT\n' ||
    '  flight_key, event_type_key, date_key, event_timestamp, producer_system, consumer_system, message_size_bytes, event_count, source_system,\n' ||
    '  CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()\n' ||
    'FROM lk';

    EXECUTE IMMEDIATE :V_SQL;

    V_STATUS := 'SUCCESS';

    IF (UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN)) THEN
        V_SQL := 'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, batch_id, start_ts, end_ts, status, source_row_count) ' ||
                 'SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP(), ?, ?';
        EXECUTE IMMEDIATE :V_SQL USING (V_PROC_NAME, V_TARGET_FQN, P_BATCH_ID, COALESCE(P_START_TS, CURRENT_TIMESTAMP()), V_STATUS, V_SRC_CNT);
    END IF;

    RETURN OBJECT_CONSTRUCT('procedure', V_PROC_NAME, 'target', V_TARGET_FQN, 'status', V_STATUS, 'source_row_count', V_SRC_CNT);

EXCEPTION
    WHEN OTHER THEN
        V_STATUS := 'FAILED';
        V_ERROR_MSG := SQLERRM;
        IF (UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN)) THEN
            V_SQL := 'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, batch_id, start_ts, end_ts, status, error_message) ' ||
                     'SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP(), ?, ?';
            EXECUTE IMMEDIATE :V_SQL USING (V_PROC_NAME, V_TARGET_FQN, P_BATCH_ID, COALESCE(P_START_TS, CURRENT_TIMESTAMP()), V_STATUS, V_ERROR_MSG);
        END IF;
        RETURN OBJECT_CONSTRUCT('procedure', V_PROC_NAME, 'target', V_TARGET_FQN, 'status', V_STATUS, 'error', V_ERROR_MSG);
END;
$$;
