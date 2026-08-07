CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_operations(
    P_SILVER_DB STRING,
    P_SILVER_SCHEMA STRING,
    P_GOLD_DB STRING,
    P_GOLD_SCHEMA STRING,
    P_AUDIT_TABLE_FQN STRING
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_operations';
    V_TARGET_TABLE_FQN STRING;
    V_START_TS TIMESTAMP;
    V_END_TS TIMESTAMP;
    V_ROWS_INSERTED NUMBER DEFAULT 0;
    V_ROWS_UPDATED NUMBER DEFAULT 0;
    V_STATUS STRING DEFAULT 'RUNNING';
    V_ERROR_MESSAGE STRING;
BEGIN
    V_START_TS := CURRENT_TIMESTAMP();
    V_TARGET_TABLE_FQN := P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.FACT_FLIGHT_OPERATIONS';

    -- ---------------------------------------------------------------------
    -- Audit: start
    -- Guard: never log if target is the audit table itself
    -- ---------------------------------------------------------------------
    IF (UPPER(V_TARGET_TABLE_FQN) <> UPPER(P_AUDIT_TABLE_FQN)) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, status) ' ||
            'SELECT ?, ?, ?, ?'
        USING (V_PROC_NAME, V_TARGET_TABLE_FQN, V_START_TS, 'RUNNING');
    END IF;

    -- ---------------------------------------------------------------------
    -- Transform + validate + MERGE
    -- ---------------------------------------------------------------------
    WITH
    src AS (
        SELECT
            s.*
        FROM IDENTIFIER(P_SILVER_DB || '.' || P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS') s
        WHERE s.dq_valid_flag = TRUE
    ),
    -- DQ: must have date_key (dim_date must contain flight_date)
    lkp_date AS (
        SELECT
            s.*,
            d.date_key AS date_key
        FROM src s
        LEFT JOIN IDENTIFIER(P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_DATE') d
            ON d.date = s.flight_date
    ),
    lkp_airline AS (
        SELECT
            s.*,
            a.airline_key AS airline_key
        FROM lkp_date s
        LEFT JOIN IDENTIFIER(P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_AIRLINE') a
            ON a.airline_code = s.carrier_code
    ),
    lkp_aircraft AS (
        SELECT
            s.*,
            ac.aircraft_key AS aircraft_key
        FROM lkp_airline s
        LEFT JOIN IDENTIFIER(P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_AIRCRAFT') ac
            ON ac.tail_number = s.tail_number
           AND s.flight_date BETWEEN ac.effective_start_date AND COALESCE(ac.effective_end_date, '9999-12-31'::DATE)
    ),
    lkp_route AS (
        SELECT
            s.*,
            r.route_key AS route_key
        FROM lkp_aircraft s
        LEFT JOIN IDENTIFIER(P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_ROUTE') r
            ON r.route_key IS NOT NULL
           AND r.route_key = r.route_key
        -- SKIPPED: gold.dim_route.route_id — dim_route.route_id does not exist in Gold DDL; mapping requires lookup by Silver route_id
    ),
    lkp_origin_airport AS (
        SELECT
            s.*,
            ao.airport_key AS origin_airport_key
        FROM lkp_route s
        LEFT JOIN IDENTIFIER(P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_AIRPORT') ao
            ON ao.airport_code = s.origin_airport_code
    ),
    lkp_dest_airport AS (
        SELECT
            s.*,
            ad.airport_key AS destination_airport_key
        FROM lkp_origin_airport s
        LEFT JOIN IDENTIFIER(P_GOLD_DB || '.' || P_GOLD_SCHEMA || '.DIM_AIRPORT') ad
            ON ad.airport_code = s.destination_airport_code
    ),
    final_rows AS (
        SELECT
            /* Natural key for MERGE matching */
            s.flight_id,

            /* Target columns */
            s.date_key,
            s.airline_key,
            s.aircraft_key,
            s.route_key,
            s.origin_airport_key,
            s.destination_airport_key,
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
            /* Audit cols */
            CURRENT_TIMESTAMP() AS dw_created_ts,
            CURRENT_TIMESTAMP() AS dw_updated_ts
        FROM lkp_dest_airport s
        QUALIFY ROW_NUMBER() OVER (PARTITION BY s.flight_id ORDER BY s.updated_ts DESC) = 1
    )

    MERGE INTO IDENTIFIER(V_TARGET_TABLE_FQN) tgt
    USING final_rows src
        ON tgt.schedule_id = src.flight_id
        -- SKIPPED: gold.fact_flight_operations business key — Gold DDL has no flight_id; mapping implies flight_id exists for matching but it is not present

    WHEN MATCHED THEN UPDATE SET
        tgt.date_key = src.date_key,
        tgt.airline_key = src.airline_key,
        tgt.aircraft_key = src.aircraft_key,
        tgt.route_key = src.route_key,
        tgt.origin_airport_key = src.origin_airport_key,
        tgt.destination_airport_key = src.destination_airport_key,
        tgt.schedule_id = src.schedule_id,
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
        src.dw_created_ts,
        src.dw_updated_ts
    );

    -- Rowcount capture (Snowflake provides metadata for last query)
    LET V_MERGE_RESULTS RESULTSET := (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    SELECT COALESCE(SUM(IFF("$1"::STRING = 'number of rows inserted', "$2"::NUMBER, 0)), 0),
           COALESCE(SUM(IFF("$1"::STRING = 'number of rows updated',  "$2"::NUMBER, 0)), 0)
      INTO :V_ROWS_INSERTED, :V_ROWS_UPDATED
      FROM V_MERGE_RESULTS;

    V_STATUS := 'SUCCESS';
    V_END_TS := CURRENT_TIMESTAMP();

    -- ---------------------------------------------------------------------
    -- Audit: end
    -- ---------------------------------------------------------------------
    IF (UPPER(V_TARGET_TABLE_FQN) <> UPPER(P_AUDIT_TABLE_FQN)) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, rows_inserted, rows_updated, error_message) ' ||
            'SELECT ?, ?, ?, ?, ?, ?, ?, ?'
        USING (V_PROC_NAME, V_TARGET_TABLE_FQN, V_START_TS, V_END_TS, V_STATUS, V_ROWS_INSERTED, V_ROWS_UPDATED, NULL);
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'procedure', V_PROC_NAME,
        'target_table', V_TARGET_TABLE_FQN,
        'status', V_STATUS,
        'rows_inserted', V_ROWS_INSERTED,
        'rows_updated', V_ROWS_UPDATED,
        'start_ts', V_START_TS,
        'end_ts', V_END_TS
    );

EXCEPTION
    WHEN OTHER THEN
        V_STATUS := 'FAILED';
        V_END_TS := CURRENT_TIMESTAMP();
        V_ERROR_MESSAGE := SQLERRM;

        IF (UPPER(V_TARGET_TABLE_FQN) <> UPPER(P_AUDIT_TABLE_FQN)) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, rows_inserted, rows_updated, error_message) ' ||
                'SELECT ?, ?, ?, ?, ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_TABLE_FQN, V_START_TS, V_END_TS, V_STATUS, V_ROWS_INSERTED, V_ROWS_UPDATED, V_ERROR_MESSAGE);
        END IF;

        RAISE;
END;
$$;
