CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_operations(
    P_AUDIT_TABLE_FQN VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_operations';
    V_TARGET_TABLE STRING DEFAULT 'gold.fact_flight_operations';
    V_START_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    V_END_TS TIMESTAMP_NTZ;
    V_STATUS STRING;
    V_ERROR_MSG STRING;
    V_ROWS_INSERTED NUMBER DEFAULT 0;
    V_ROWS_UPDATED NUMBER DEFAULT 0;
BEGIN
    /* ----------------------------------------------------------------------
       AUDIT: PRE-STEP
       Guard: do not log if target is the audit table (prevents recursion)
    ---------------------------------------------------------------------- */
    IF (UPPER(V_TARGET_TABLE) <> UPPER(P_AUDIT_TABLE_FQN)) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, status)\n' ||
            'SELECT ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, 'RUNNING');
    END IF;

    /* ----------------------------------------------------------------------
       SOURCE -> TRANSFORM
       Only load Silver rows marked valid.
    ---------------------------------------------------------------------- */
    WITH src AS (
        SELECT
            s.*
        FROM silver.slv_flight_operations s
        WHERE s.dq_valid_flag = TRUE
    ),
    xform AS (
        SELECT
            /* FK lookups */
            TO_NUMBER(TO_CHAR(s.flight_date, 'YYYYMMDD'))                                     AS date_key,
            da.airline_key                                                                    AS airline_key,
            dac.aircraft_key                                                                  AS aircraft_key,
            dr.route_key                                                                      AS route_key,
            dao.airport_key                                                                   AS origin_airport_key,
            dad.airport_key                                                                   AS destination_airport_key,

            /* degenerate/natural identifiers */
            s.flight_id                                                                       AS flight_id,

            /* measures & attributes */
            s.schedule_id                                                                     AS schedule_id,
            s.scheduled_departure_ts                                                          AS scheduled_departure_ts,
            s.actual_departure_ts                                                             AS actual_departure_ts,
            s.scheduled_arrival_ts                                                            AS scheduled_arrival_ts,
            s.actual_arrival_ts                                                               AS actual_arrival_ts,
            s.delay_minutes                                                                   AS delay_minutes,
            s.taxi_out_minutes                                                                AS taxi_out_minutes,
            s.taxi_in_minutes                                                                 AS taxi_in_minutes,
            s.flight_distance_miles                                                           AS flight_distance_miles,
            s.block_hours                                                                     AS block_hours,
            s.cancelled_flag                                                                  AS cancelled_flag,
            s.diverted_flag                                                                   AS diverted_flag,
            s.source_system                                                                   AS source_system,

            /* audit */
            s.created_ts                                                                      AS src_created_ts,
            s.updated_ts                                                                      AS src_updated_ts
        FROM src s
        LEFT JOIN gold.dim_airline da
            ON da.airline_code = s.carrier_code
        LEFT JOIN gold.dim_route dr
            ON dr.route_key IS NOT NULL
           AND EXISTS (SELECT 1) /* placeholder to preserve structure */
        LEFT JOIN gold.dim_route dr
            ON dr.route_key IS NOT NULL
        QUALIFY 1=1
    ),
    resolved AS (
        SELECT
            x.date_key,
            x.airline_key,
            /* SCD2 point-in-time lookup for aircraft */
            dac.aircraft_key                                                                  AS aircraft_key,
            dr.route_key                                                                      AS route_key,
            dao.airport_key                                                                   AS origin_airport_key,
            dad.airport_key                                                                   AS destination_airport_key,
            x.schedule_id,
            x.scheduled_departure_ts,
            x.actual_departure_ts,
            x.scheduled_arrival_ts,
            x.actual_arrival_ts,
            x.delay_minutes,
            x.taxi_out_minutes,
            x.taxi_in_minutes,
            x.flight_distance_miles,
            x.block_hours,
            x.cancelled_flag,
            x.diverted_flag,
            x.source_system,
            x.src_created_ts,
            x.src_updated_ts,
            x.flight_id
        FROM (
            SELECT
                s.flight_id,
                TO_NUMBER(TO_CHAR(s.flight_date, 'YYYYMMDD'))                                 AS date_key,
                da.airline_key                                                                AS airline_key,
                s.tail_number                                                                 AS tail_number,
                s.flight_date                                                                 AS flight_date,
                s.route_id                                                                    AS route_id,
                s.origin_airport_code                                                         AS origin_airport_code,
                s.destination_airport_code                                                    AS destination_airport_code,
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
                s.created_ts                                                                  AS src_created_ts,
                s.updated_ts                                                                  AS src_updated_ts
            FROM src s
            LEFT JOIN gold.dim_airline da
                ON da.airline_code = s.carrier_code
        ) s
        LEFT JOIN gold.dim_aircraft dac
            ON dac.tail_number = s.tail_number
           AND s.flight_date BETWEEN dac.effective_start_date AND COALESCE(dac.effective_end_date, '9999-12-31')
        LEFT JOIN gold.dim_route dr
            ON dr.route_key IS NOT NULL
        -- SKIPPED: gold.dim_route.route_key — mapping requires lookup by slv_route.route_id, but dim_route DDL does not include route_id natural key.
        LEFT JOIN gold.dim_airport dao
            ON dao.airport_code = s.origin_airport_code
        LEFT JOIN gold.dim_airport dad
            ON dad.airport_code = s.destination_airport_code
    ),
    deduped AS (
        SELECT
            r.*
        FROM resolved r
        QUALIFY ROW_NUMBER() OVER (PARTITION BY r.flight_id ORDER BY r.src_updated_ts DESC) = 1
    )

    /* ----------------------------------------------------------------------
       DATA QUALITY ASSERTIONS (do not silently drop)
    ---------------------------------------------------------------------- */
    SELECT
        CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
    INTO :V_STATUS
    FROM (
        SELECT 1
        FROM deduped
        WHERE date_key IS NULL
    );

    IF (V_STATUS = 1) THEN
        V_ERROR_MSG := 'Validation failed: date_key is NULL for one or more rows.';
        RAISE STATEMENT_ERROR WITH MESSAGE = V_ERROR_MSG;
    END IF;

    /* ----------------------------------------------------------------------
       MERGE (UPSERT) into Gold fact
       Note: flight_key is identity; do not set.
       Natural match key for merge not explicitly provided in Gold DDL.
    ---------------------------------------------------------------------- */
    MERGE INTO gold.fact_flight_operations tgt
    USING (
        SELECT
            d.date_key,
            d.airline_key,
            d.aircraft_key,
            d.route_key,
            d.origin_airport_key,
            d.destination_airport_key,
            d.schedule_id,
            d.scheduled_departure_ts,
            d.actual_departure_ts,
            d.scheduled_arrival_ts,
            d.actual_arrival_ts,
            d.delay_minutes,
            d.taxi_out_minutes,
            d.taxi_in_minutes,
            d.flight_distance_miles,
            d.block_hours,
            d.cancelled_flag,
            d.diverted_flag,
            d.source_system,
            /* dw timestamps */
            CURRENT_TIMESTAMP() AS dw_updated_ts,
            CURRENT_TIMESTAMP() AS dw_created_ts,
            d.flight_id
        FROM deduped d
    ) src
        ON (tgt.schedule_id = src.schedule_id AND tgt.date_key = src.date_key)
        -- SKIPPED: gold.fact_flight_operations.flight_key — no deterministic natural key defined in Gold DDL; using (schedule_id, date_key) as best-effort match.
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
        tgt.dw_updated_ts = src.dw_updated_ts
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

    /* MERGE row counts are available via RESULT_SCAN(LAST_QUERY_ID()) */
    LET v_merge_qid STRING := LAST_QUERY_ID();
    SELECT
        COALESCE(SUM(IFF("action" = 'INSERT', "rows", 0)), 0),
        COALESCE(SUM(IFF("action" = 'UPDATE', "rows", 0)), 0)
    INTO :V_ROWS_INSERTED, :V_ROWS_UPDATED
    FROM TABLE(RESULT_SCAN(:v_merge_qid));

    V_END_TS := CURRENT_TIMESTAMP();
    V_STATUS := 'SUCCESS';

    /* ----------------------------------------------------------------------
       AUDIT: POST-STEP
    ---------------------------------------------------------------------- */
    IF (UPPER(V_TARGET_TABLE) <> UPPER(P_AUDIT_TABLE_FQN)) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, rows_inserted, rows_updated, error_message)\n' ||
            'SELECT ?, ?, ?, ?, ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, V_END_TS, V_STATUS, V_ROWS_INSERTED, V_ROWS_UPDATED, NULL);
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'procedure', V_PROC_NAME,
        'target_table', V_TARGET_TABLE,
        'status', V_STATUS,
        'rows_inserted', V_ROWS_INSERTED,
        'rows_updated', V_ROWS_UPDATED,
        'start_ts', V_START_TS,
        'end_ts', V_END_TS
    );

EXCEPTION
    WHEN OTHER THEN
        V_END_TS := CURRENT_TIMESTAMP();
        V_STATUS := 'FAILED';
        V_ERROR_MSG := ERROR_MESSAGE();

        IF (UPPER(V_TARGET_TABLE) <> UPPER(P_AUDIT_TABLE_FQN)) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || P_AUDIT_TABLE_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message)\n' ||
                'SELECT ?, ?, ?, ?, ?, ?'
                USING (V_PROC_NAME, V_TARGET_TABLE, V_START_TS, V_END_TS, V_STATUS, V_ERROR_MSG);
        END IF;

        RETURN OBJECT_CONSTRUCT(
            'procedure', V_PROC_NAME,
            'target_table', V_TARGET_TABLE,
            'status', V_STATUS,
            'start_ts', V_START_TS,
            'end_ts', V_END_TS,
            'error_message', V_ERROR_MSG
        );
END;
$$;
