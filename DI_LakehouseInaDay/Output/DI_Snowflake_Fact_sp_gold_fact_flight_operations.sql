CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_operations(
    P_SILVER_SCHEMA STRING,
    P_GOLD_SCHEMA   STRING,
    P_AUDIT_TABLE_FQN STRING,
    P_LOAD_MODE     STRING DEFAULT 'INCREMENTAL'
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_operations';
    V_TARGET_FQN STRING;
    V_START_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    V_END_TS   TIMESTAMP_NTZ;
    V_STATUS   STRING;
    V_ERROR    STRING;

    V_SRC_COUNT NUMBER;
    V_UPSERTED  NUMBER;

    V_AUDIT_DB STRING;
    V_AUDIT_SCHEMA STRING;
    V_AUDIT_TABLE STRING;
    V_AUDIT_FQN STRING;
BEGIN
    V_TARGET_FQN := P_GOLD_SCHEMA || '.FACT_FLIGHT_OPERATIONS';

    V_AUDIT_DB := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 1);
    V_AUDIT_SCHEMA := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 2);
    V_AUDIT_TABLE := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 3);
    V_AUDIT_FQN := V_AUDIT_DB || '.' || V_AUDIT_SCHEMA || '.' || V_AUDIT_TABLE;

    IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, status) SELECT ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, 'RUNNING');
    END IF;

    LET V_INVALID_CNT NUMBER := (
        SELECT COUNT(*)
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS') s
        WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = FALSE
    );

    IF (V_INVALID_CNT > 0) THEN
        V_STATUS := 'FAILED';
        V_ERROR := 'DQ validation failed: ' || V_INVALID_CNT || ' rows in ' || P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS have DQ_VALID_FLAG=FALSE.';

        IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) SELECT ?, ?, ?, ?, ?, ?'
                USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, CURRENT_TIMESTAMP(), V_STATUS, V_ERROR);
        END IF;

        RAISE STATEMENT_ERROR WITH MESSAGE = V_ERROR;
    END IF;

    V_SRC_COUNT := (
        SELECT COUNT(*)
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS') s
        WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = TRUE
    );

    MERGE INTO IDENTIFIER(V_TARGET_FQN) AS tgt
    USING (
        WITH src AS (
            SELECT
                s.FLIGHT_ID,
                s.SCHEDULE_ID,
                s.CARRIER_CODE,
                s.TAIL_NUMBER,
                s.ORIGIN_AIRPORT_CODE,
                s.DESTINATION_AIRPORT_CODE,
                s.ROUTE_ID,
                s.FLIGHT_DATE,
                s.SCHEDULED_DEPARTURE_TS,
                s.ACTUAL_DEPARTURE_TS,
                s.SCHEDULED_ARRIVAL_TS,
                s.ACTUAL_ARRIVAL_TS,
                s.DELAY_MINUTES,
                s.TAXI_OUT_MINUTES,
                s.TAXI_IN_MINUTES,
                s.FLIGHT_DISTANCE_MILES,
                s.BLOCK_HOURS,
                s.CANCELLED_FLAG,
                s.DIVERTED_FLAG,
                s.SOURCE_SYSTEM,
                s.CREATED_TS,
                s.UPDATED_TS
            FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS') s
            WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = TRUE
        ),
        lkp AS (
            SELECT
                src.FLIGHT_ID,
                dd.DATE_KEY AS DATE_KEY,
                da.AIRLINE_KEY AS AIRLINE_KEY,
                oap.AIRPORT_KEY AS ORIGIN_AIRPORT_KEY,
                dap.AIRPORT_KEY AS DESTINATION_AIRPORT_KEY,
                dac.AIRCRAFT_KEY AS AIRCRAFT_KEY,
                src.SCHEDULE_ID,
                src.SCHEDULED_DEPARTURE_TS,
                src.ACTUAL_DEPARTURE_TS,
                src.SCHEDULED_ARRIVAL_TS,
                src.ACTUAL_ARRIVAL_TS,
                src.DELAY_MINUTES,
                src.TAXI_OUT_MINUTES,
                src.TAXI_IN_MINUTES,
                src.FLIGHT_DISTANCE_MILES,
                src.BLOCK_HOURS,
                src.CANCELLED_FLAG,
                src.DIVERTED_FLAG,
                src.SOURCE_SYSTEM,
                src.CREATED_TS,
                src.UPDATED_TS
            FROM src
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_DATE') dd
                ON dd.DATE = src.FLIGHT_DATE
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_AIRLINE') da
                ON da.AIRLINE_CODE = src.CARRIER_CODE
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_AIRPORT') oap
                ON oap.AIRPORT_CODE = src.ORIGIN_AIRPORT_CODE
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_AIRPORT') dap
                ON dap.AIRPORT_CODE = src.DESTINATION_AIRPORT_CODE
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_AIRCRAFT') dac
                ON dac.TAIL_NUMBER = src.TAIL_NUMBER
               AND src.FLIGHT_DATE BETWEEN dac.EFFECTIVE_START_DATE AND COALESCE(dac.EFFECTIVE_END_DATE, '9999-12-31')
        ),
        final_rows AS (
            SELECT
                lkp.FLIGHT_ID,
                lkp.DATE_KEY,
                lkp.AIRLINE_KEY,
                lkp.AIRCRAFT_KEY,
                -- SKIPPED: gold.fact_flight_operations.route_key — Mapping requires lookup by slv_route.route_id, but gold.dim_route has no route_id natural key column in current Gold DDL.
                CAST(NULL AS INTEGER) AS ROUTE_KEY,
                lkp.ORIGIN_AIRPORT_KEY,
                lkp.DESTINATION_AIRPORT_KEY,
                lkp.SCHEDULE_ID,
                lkp.SCHEDULED_DEPARTURE_TS,
                lkp.ACTUAL_DEPARTURE_TS,
                lkp.SCHEDULED_ARRIVAL_TS,
                lkp.ACTUAL_ARRIVAL_TS,
                lkp.DELAY_MINUTES,
                lkp.TAXI_OUT_MINUTES,
                lkp.TAXI_IN_MINUTES,
                lkp.FLIGHT_DISTANCE_MILES,
                lkp.BLOCK_HOURS,
                lkp.CANCELLED_FLAG,
                lkp.DIVERTED_FLAG,
                lkp.SOURCE_SYSTEM,
                lkp.CREATED_TS AS DW_CREATED_TS,
                lkp.UPDATED_TS AS DW_UPDATED_TS
            FROM lkp
        ),
        dedup AS (
            SELECT *
            FROM final_rows
            QUALIFY ROW_NUMBER() OVER (PARTITION BY FLIGHT_ID ORDER BY DW_UPDATED_TS DESC) = 1
        )
        SELECT * FROM dedup
    ) AS src
    ON tgt.SCHEDULE_ID = src.SCHEDULE_ID
   AND tgt.DATE_KEY = src.DATE_KEY
   AND COALESCE(tgt.AIRLINE_KEY, -1) = COALESCE(src.AIRLINE_KEY, -1)
   AND COALESCE(tgt.ORIGIN_AIRPORT_KEY, -1) = COALESCE(src.ORIGIN_AIRPORT_KEY, -1)
   AND COALESCE(tgt.DESTINATION_AIRPORT_KEY, -1) = COALESCE(src.DESTINATION_AIRPORT_KEY, -1)
    WHEN MATCHED THEN UPDATE SET
        tgt.AIRCRAFT_KEY = src.AIRCRAFT_KEY,
        tgt.ROUTE_KEY = src.ROUTE_KEY,
        tgt.SCHEDULED_DEPARTURE_TS = src.SCHEDULED_DEPARTURE_TS,
        tgt.ACTUAL_DEPARTURE_TS = src.ACTUAL_DEPARTURE_TS,
        tgt.SCHEDULED_ARRIVAL_TS = src.SCHEDULED_ARRIVAL_TS,
        tgt.ACTUAL_ARRIVAL_TS = src.ACTUAL_ARRIVAL_TS,
        tgt.DELAY_MINUTES = src.DELAY_MINUTES,
        tgt.TAXI_OUT_MINUTES = src.TAXI_OUT_MINUTES,
        tgt.TAXI_IN_MINUTES = src.TAXI_IN_MINUTES,
        tgt.FLIGHT_DISTANCE_MILES = src.FLIGHT_DISTANCE_MILES,
        tgt.BLOCK_HOURS = src.BLOCK_HOURS,
        tgt.CANCELLED_FLAG = src.CANCELLED_FLAG,
        tgt.DIVERTED_FLAG = src.DIVERTED_FLAG,
        tgt.SOURCE_SYSTEM = src.SOURCE_SYSTEM,
        tgt.DW_UPDATED_TS = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        DATE_KEY,
        AIRLINE_KEY,
        AIRCRAFT_KEY,
        ROUTE_KEY,
        ORIGIN_AIRPORT_KEY,
        DESTINATION_AIRPORT_KEY,
        SCHEDULE_ID,
        SCHEDULED_DEPARTURE_TS,
        ACTUAL_DEPARTURE_TS,
        SCHEDULED_ARRIVAL_TS,
        ACTUAL_ARRIVAL_TS,
        DELAY_MINUTES,
        TAXI_OUT_MINUTES,
        TAXI_IN_MINUTES,
        FLIGHT_DISTANCE_MILES,
        BLOCK_HOURS,
        CANCELLED_FLAG,
        DIVERTED_FLAG,
        SOURCE_SYSTEM,
        DW_CREATED_TS,
        DW_UPDATED_TS
    ) VALUES (
        src.DATE_KEY,
        src.AIRLINE_KEY,
        src.AIRCRAFT_KEY,
        src.ROUTE_KEY,
        src.ORIGIN_AIRPORT_KEY,
        src.DESTINATION_AIRPORT_KEY,
        src.SCHEDULE_ID,
        src.SCHEDULED_DEPARTURE_TS,
        src.ACTUAL_DEPARTURE_TS,
        src.SCHEDULED_ARRIVAL_TS,
        src.ACTUAL_ARRIVAL_TS,
        src.DELAY_MINUTES,
        src.TAXI_OUT_MINUTES,
        src.TAXI_IN_MINUTES,
        src.FLIGHT_DISTANCE_MILES,
        src.BLOCK_HOURS,
        src.CANCELLED_FLAG,
        src.DIVERTED_FLAG,
        src.SOURCE_SYSTEM,
        CURRENT_TIMESTAMP(),
        CURRENT_TIMESTAMP()
    );

    V_UPSERTED := SQLROWCOUNT;

    V_END_TS := CURRENT_TIMESTAMP();
    V_STATUS := 'SUCCESS';

    IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, source_row_count, target_row_count) SELECT ?, ?, ?, ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, V_END_TS, V_STATUS, V_SRC_COUNT, V_UPSERTED);
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'procedure_name', V_PROC_NAME,
        'target_table', V_TARGET_FQN,
        'status', V_STATUS,
        'source_row_count', V_SRC_COUNT,
        'merge_affected_rows', V_UPSERTED,
        'start_ts', V_START_TS,
        'end_ts', V_END_TS
    );

EXCEPTION
    WHEN OTHER THEN
        V_END_TS := CURRENT_TIMESTAMP();
        V_STATUS := 'FAILED';
        V_ERROR := SQLERRM;

        IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) SELECT ?, ?, ?, ?, ?, ?'
                USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, V_END_TS, V_STATUS, V_ERROR);
        END IF;

        RETURN OBJECT_CONSTRUCT(
            'procedure_name', V_PROC_NAME,
            'target_table', V_TARGET_FQN,
            'status', V_STATUS,
            'error_message', V_ERROR,
            'start_ts', V_START_TS,
            'end_ts', V_END_TS
        );
END;
$$;
