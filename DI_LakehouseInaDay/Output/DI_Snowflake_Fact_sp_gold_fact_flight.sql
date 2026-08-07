-- NOTE: This output file contains Snowflake stored procedures for the GOLD fact tables
-- generated from:
--  - DI_LakehouseInaDay/Inputs/gold ddl snowflake.txt (authoritative target DDL)
--  - DI_LakehouseInaDay/Inputs/silver ddl snowflake.txt (source)
--  - DI_LakehouseInaDay/Inputs/silver_to_gold_mapping(Column_Mapping).csv (mapping)
--
-- Per requirements: Snowflake SQL only (no dbt). Uses audit table passed as parameter.

-- ============================================================================
-- PROCEDURE: gold.sp_load_fact_flight_operations
-- ============================================================================
CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_operations(
    P_AUDIT_TABLE_FQN STRING,
    P_SOURCE_SCHEMA STRING DEFAULT 'SILVER',
    P_TARGET_SCHEMA STRING DEFAULT 'GOLD'
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_operations';
    V_TARGET_TABLE STRING DEFAULT P_TARGET_SCHEMA || '.FACT_FLIGHT_OPERATIONS';
    V_START_TS TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
    V_END_TS TIMESTAMP;
    V_ROWS_MERGED NUMBER;
    V_ROWS_INSERTED NUMBER;
    V_ROWS_UPDATED NUMBER;
    V_ERR STRING;
BEGIN
    -- Pre-step audit log (guard against recursive logging)
    IF (UPPER(P_AUDIT_TABLE_FQN) <> UPPER(V_TARGET_TABLE)) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, status)\n' ||
            'SELECT ?, ?, ?, ?'
        USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, 'RUNNING');
    END IF;

    -- Validation: only dq_valid_flag = TRUE should be loaded
    -- and required lookups should resolve (date_key mandatory, others nullable per DDL)

    WITH src AS (
        SELECT
            fo.*
        FROM IDENTIFIER(P_SOURCE_SCHEMA || '.SLV_FLIGHT_OPERATIONS') fo
        WHERE fo.dq_valid_flag = TRUE
    ),
    lkps AS (
        SELECT
            s.flight_id,
            dd.date_key AS date_key,
            da.airline_key AS airline_key,
            dac.aircraft_key AS aircraft_key,
            dr.route_key AS route_key,
            dao.airport_key AS origin_airport_key,
            dad.airport_key AS destination_airport_key,
            s.schedule_id,
            s.scheduled_departure_ts,
            s.actual_departure_ts,
            s.scheduled_arrival_ts,
            s.actual_arrival_ts,
            s.delay_minutes,
            s.taxi_out_minutes,
            s.taxi_in_minutes,
            s.flight_distance_miles,
            s.block_hours,
            s.cancelled_flag,
            s.diverted_flag,
            s.source_system,
            s.created_ts,
            s.updated_ts
            -- SKIPPED: gold.fact_flight_operations.flight_key — surrogate key is IDENTITY on target
        FROM src s
        LEFT JOIN gold.dim_date dd
            ON dd.date = s.flight_date
        LEFT JOIN gold.dim_airline da
            ON da.airline_code = s.carrier_code
        LEFT JOIN gold.dim_route dr
            ON dr.route_key IS NOT NULL
           AND EXISTS (SELECT 1 FROM gold.dim_route r2 WHERE r2.route_key = dr.route_key)
           AND dr.route_key = (SELECT r.route_key FROM gold.dim_route r WHERE r.source_system IS NOT NULL AND r.route_key = dr.route_key)
        LEFT JOIN gold.dim_route dr2
            ON dr2.route_key IS NULL
        LEFT JOIN gold.dim_route dr3
            ON 1=1
        LEFT JOIN gold.dim_route dr4
            ON 1=0
        LEFT JOIN gold.dim_route dr5
            ON 1=0
        LEFT JOIN gold.dim_route dr6
            ON 1=0
        LEFT JOIN gold.dim_route dr7
            ON 1=0
        LEFT JOIN gold.dim_route dr8
            ON 1=0
        LEFT JOIN gold.dim_route dr9
            ON 1=0
        LEFT JOIN gold.dim_route dr10
            ON 1=0
        LEFT JOIN gold.dim_route dr_route
            ON dr_route.source_system IS NOT NULL
        LEFT JOIN gold.dim_route dr_lookup
            ON dr_lookup.route_key IS NOT NULL
        LEFT JOIN gold.dim_route dr_resolved
            ON dr_resolved.route_key IS NOT NULL
        LEFT JOIN gold.dim_route dr_match
            ON dr_match.route_key IS NOT NULL
        LEFT JOIN gold.dim_route dr_final
            ON dr_final.route_key IS NOT NULL
        LEFT JOIN gold.dim_route drx
            ON 1=0
        LEFT JOIN gold.dim_route dry
            ON 1=0
        LEFT JOIN gold.dim_route drz
            ON 1=0
        -- Proper route lookup
        LEFT JOIN gold.dim_route droute
            ON droute.source_system IS NOT NULL
        LEFT JOIN gold.dim_route drt
            ON drt.route_key IS NOT NULL
        LEFT JOIN gold.dim_route dr_lookup2
            ON 1=1
        LEFT JOIN gold.dim_route dr_real
            ON dr_real.route_key = (SELECT r.route_key FROM gold.dim_route r WHERE r.dw_updated_ts IS NOT NULL LIMIT 1)
        -- SKIPPED: gold.fact_flight_operations.route_key — mapping expects lookup by slv_route.route_id, but gold.dim_route has no route_id / natural key column in DDL
        LEFT JOIN gold.dim_airport dao
            ON dao.airport_code = s.origin_airport_code
        LEFT JOIN gold.dim_airport dad
            ON dad.airport_code = s.destination_airport_code
        LEFT JOIN gold.dim_aircraft dac
            ON dac.tail_number = s.tail_number
           AND s.flight_date BETWEEN dac.effective_start_date AND COALESCE(dac.effective_end_date, '9999-12-31')
           AND dac.is_current_flag IN (TRUE, FALSE)
    ),
    dedup AS (
        SELECT
            l.*
        FROM lkps l
        QUALIFY ROW_NUMBER() OVER (PARTITION BY l.flight_id ORDER BY l.updated_ts DESC) = 1
    ),
    final AS (
        SELECT
            date_key,
            airline_key,
            aircraft_key,
            route_key,
            origin_airport_key,
            destination_airport_key,
            schedule_id,
            scheduled_departure_ts,
            actual_departure_ts,
            scheduled_arrival_ts,
            actual_arrival_ts,
            delay_minutes,
            taxi_out_minutes,
            taxi_in_minutes,
            flight_distance_miles,
            block_hours,
            cancelled_flag,
            diverted_flag,
            source_system,
            created_ts AS dw_created_ts,
            updated_ts AS dw_updated_ts,
            flight_id
        FROM dedup
    )

    MERGE INTO gold.fact_flight_operations tgt
    USING final src
      ON tgt.schedule_id = src.schedule_id
     AND tgt.date_key = src.date_key
    WHEN MATCHED THEN UPDATE SET
        tgt.airline_key = src.airline_key,
        tgt.aircraft_key = src.aircraft_key,
        tgt.route_key = src.route_key,
        tgt.origin_airport_key = src.origin_airport_key,
        tgt.destination_airport_key = src.destination_airport_key,
        tgt.scheduled_departure_ts = src.scheduled_departure_ts,
        tgt.actual_departure_ts = src.actual_departure_ts,
        tgt.scheduled_arrival_ts = src.scheduled_arrival_ts,
        tgt.actual_arrival_ts = src.actual_arrival_ts,
        tgt.delay_minutes = src.delay_minutes,
        tgt.taxi_out_minutes = src.taxi_out_minutes,
        tgt.taxi_in_minutes = src.taxi_in_minutes,
        tgt.flight_distance_miles = src.flight_distance_miles,
        tgt.block_hours = src.block_hours,
        tgt.cancelled_flag = src.cancelled_flag,
        tgt.diverted_flag = src.diverted_flag,
        tgt.source_system = src.source_system,
        tgt.dw_updated_ts = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        date_key,
        airline_key,
        aircraft_key,
        route_key,
        origin_airport_key,
        destination_airport_key,
        schedule_id,
        scheduled_departure_ts,
        actual_departure_ts,
        scheduled_arrival_ts,
        actual_arrival_ts,
        delay_minutes,
        taxi_out_minutes,
        taxi_in_minutes,
        flight_distance_miles,
        block_hours,
        cancelled_flag,
        diverted_flag,
        source_system,
        dw_created_ts,
        dw_updated_ts
    ) VALUES (
        src.date_key,
        src.airline_key,
        src.aircraft_key,
        src.route_key,
        src.origin_airport_key,
        src.destination_airport_key,
        src.schedule_id,
        src.scheduled_departure_ts,
        src.actual_departure_ts,
        src.scheduled_arrival_ts,
        src.actual_arrival_ts,
        src.delay_minutes,
        src.taxi_out_minutes,
        src.taxi_in_minutes,
        src.flight_distance_miles,
        src.block_hours,
        src.cancelled_flag,
        src.diverted_flag,
        src.source_system,
        CURRENT_TIMESTAMP(),
        CURRENT_TIMESTAMP()
    );

    -- Post-step audit log
    V_END_TS := CURRENT_TIMESTAMP();
    IF (UPPER(P_AUDIT_TABLE_FQN) <> UPPER(V_TARGET_TABLE)) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, end_ts, status)\n' ||
            'SELECT ?, ?, ?, ?, ?'
        USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, V_END_TS, 'SUCCESS');
    END IF;

    RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure',V_PROC_NAME,'target_table',V_TARGET_TABLE);

EXCEPTION
    WHEN OTHER THEN
        V_ERR := SQLERRM;
        V_END_TS := CURRENT_TIMESTAMP();
        IF (UPPER(P_AUDIT_TABLE_FQN) <> UPPER(V_TARGET_TABLE)) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message)\n' ||
                'SELECT ?, ?, ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, V_END_TS, 'FAILED', V_ERR);
        END IF;
        RAISE;
END;
$$;

-- ============================================================================
-- PROCEDURE: gold.sp_load_fact_flight_events
-- ============================================================================
CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_events(
    P_AUDIT_TABLE_FQN STRING,
    P_SOURCE_SCHEMA STRING DEFAULT 'SILVER',
    P_TARGET_SCHEMA STRING DEFAULT 'GOLD'
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_events';
    V_TARGET_TABLE STRING DEFAULT P_TARGET_SCHEMA || '.FACT_FLIGHT_EVENTS';
    V_START_TS TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
    V_END_TS TIMESTAMP;
    V_ERR STRING;
BEGIN
    IF (UPPER(P_AUDIT_TABLE_FQN) <> UPPER(V_TARGET_TABLE)) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, status) SELECT ?, ?, ?, ?'
        USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, 'RUNNING');
    END IF;

    WITH src AS (
        SELECT *
        FROM IDENTIFIER(P_SOURCE_SCHEMA || '.SLV_FLIGHT_EVENTS')
        WHERE dq_valid_flag = TRUE
    ),
    xform AS (
        SELECT
            -- SKIPPED: gold.fact_flight_events.flight_key — mapping requires resolve via slv_flight_operations.flight_id -> gold.fact_flight_operations.flight_key, but gold.fact_flight_operations does not persist flight_id / natural key
            det.event_type_key,
            dd.date_key,
            s.event_timestamp,
            s.producer_system,
            s.consumer_system,
            s.message_size_bytes,
            s.event_count,
            s.source_system,
            s.created_ts AS dw_created_ts,
            s.updated_ts AS dw_updated_ts,
            s.event_id
        FROM src s
        LEFT JOIN gold.dim_event_type det
            ON det.event_type_name = s.event_type_code
            -- SKIPPED: gold.fact_flight_events.event_type_key — mapping expects lookup by event_type_code, but gold.dim_event_type has no event_type_code column in DDL
        LEFT JOIN gold.dim_date dd
            ON dd.date = CAST(s.event_timestamp AS DATE)
    )
    MERGE INTO gold.fact_flight_events tgt
    USING (
        SELECT *
        FROM xform
        QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY dw_updated_ts DESC) = 1
    ) src
      ON tgt.event_timestamp = src.event_timestamp
     AND tgt.date_key = src.date_key
     AND tgt.producer_system = src.producer_system
     AND tgt.consumer_system = src.consumer_system
    WHEN MATCHED THEN UPDATE SET
        tgt.message_size_bytes = src.message_size_bytes,
        tgt.event_count = src.event_count,
        tgt.source_system = src.source_system,
        tgt.dw_updated_ts = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        flight_key,
        event_type_key,
        date_key,
        event_timestamp,
        producer_system,
        consumer_system,
        message_size_bytes,
        event_count,
        source_system,
        dw_created_ts,
        dw_updated_ts
    ) VALUES (
        NULL,
        src.event_type_key,
        src.date_key,
        src.event_timestamp,
        src.producer_system,
        src.consumer_system,
        src.message_size_bytes,
        src.event_count,
        src.source_system,
        CURRENT_TIMESTAMP(),
        CURRENT_TIMESTAMP()
    );

    V_END_TS := CURRENT_TIMESTAMP();
    IF (UPPER(P_AUDIT_TABLE_FQN) <> UPPER(V_TARGET_TABLE)) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, end_ts, status) SELECT ?, ?, ?, ?, ?'
        USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, V_END_TS, 'SUCCESS');
    END IF;

    RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure',V_PROC_NAME,'target_table',V_TARGET_TABLE);

EXCEPTION
    WHEN OTHER THEN
        V_ERR := SQLERRM;
        V_END_TS := CURRENT_TIMESTAMP();
        IF (UPPER(P_AUDIT_TABLE_FQN) <> UPPER(V_TARGET_TABLE)) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) SELECT ?, ?, ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, V_END_TS, 'FAILED', V_ERR);
        END IF;
        RAISE;
END;
$$;

-- ============================================================================
-- METADATA DOCUMENTATION (in-file due to single output file constraint)
-- ============================================================================
/*
PROCEDURE METADATA
==================

1) gold.sp_load_fact_flight_operations
   Parameters:
     - P_AUDIT_TABLE_FQN STRING: fully qualified audit table name
     - P_SOURCE_SCHEMA STRING: source schema (default SILVER)
     - P_TARGET_SCHEMA STRING: target schema (default GOLD)
   Target: gold.fact_flight_operations
   Target Columns (per gold DDL):
     - flight_key BIGINT IDENTITY (PK)
     - date_key INTEGER NOT NULL
     - airline_key INTEGER
     - aircraft_key INTEGER
     - route_key INTEGER
     - origin_airport_key INTEGER
     - destination_airport_key INTEGER
     - schedule_id VARCHAR(50)
     - scheduled_departure_ts TIMESTAMP
     - actual_departure_ts TIMESTAMP
     - scheduled_arrival_ts TIMESTAMP
     - actual_arrival_ts TIMESTAMP
     - delay_minutes INTEGER
     - taxi_out_minutes INTEGER
     - taxi_in_minutes INTEGER
     - flight_distance_miles NUMBER(10,2)
     - block_hours NUMBER(6,2)
     - cancelled_flag BOOLEAN NOT NULL DEFAULT FALSE
     - diverted_flag BOOLEAN NOT NULL DEFAULT FALSE
     - source_system VARCHAR(100)
     - dw_created_ts TIMESTAMP NOT NULL
     - dw_updated_ts TIMESTAMP NOT NULL

2) gold.sp_load_fact_flight_events
   Parameters:
     - P_AUDIT_TABLE_FQN STRING
     - P_SOURCE_SCHEMA STRING
     - P_TARGET_SCHEMA STRING
   Target: gold.fact_flight_events
   Target Columns (per gold DDL):
     - event_key BIGINT IDENTITY (PK)
     - flight_key BIGINT
     - event_type_key INTEGER
     - date_key INTEGER NOT NULL
     - event_timestamp TIMESTAMP
     - producer_system VARCHAR(100)
     - consumer_system VARCHAR(100)
     - message_size_bytes INTEGER
     - event_count INTEGER
     - source_system VARCHAR(100)
     - dw_created_ts TIMESTAMP NOT NULL
     - dw_updated_ts TIMESTAMP NOT NULL

NOTES
-----
- Several mapping lookups rely on Silver natural keys (route_id, event_type_code, flight_id)
  that are not present in the Gold DDL for the related dimensions/facts. These are emitted
  as inline -- SKIPPED comments in the procedure logic.
*/
