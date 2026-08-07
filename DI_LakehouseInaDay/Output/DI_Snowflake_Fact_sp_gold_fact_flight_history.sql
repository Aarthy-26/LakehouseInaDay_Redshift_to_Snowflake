CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_history(
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
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_history';
    V_TARGET_FQN STRING;
    V_START_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    V_END_TS   TIMESTAMP_NTZ;
    V_STATUS   STRING;
    V_ERROR    STRING;

    V_AFFECTED NUMBER;

    V_AUDIT_DB STRING;
    V_AUDIT_SCHEMA STRING;
    V_AUDIT_TABLE STRING;
    V_AUDIT_FQN STRING;
BEGIN
    V_TARGET_FQN := P_GOLD_SCHEMA || '.FACT_FLIGHT_HISTORY';

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
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_HISTORY') h
        WHERE COALESCE(h.DQ_VALID_FLAG, TRUE) = FALSE
    );

    IF (V_INVALID_CNT > 0) THEN
        V_STATUS := 'FAILED';
        V_ERROR := 'DQ validation failed: ' || V_INVALID_CNT || ' rows in ' || P_SILVER_SCHEMA || '.SLV_FLIGHT_HISTORY have DQ_VALID_FLAG=FALSE.';

        IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) SELECT ?, ?, ?, ?, ?, ?'
                USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, CURRENT_TIMESTAMP(), V_STATUS, V_ERROR);
        END IF;

        RAISE STATEMENT_ERROR WITH MESSAGE = V_ERROR;
    END IF;

    MERGE INTO IDENTIFIER(V_TARGET_FQN) AS tgt
    USING (
        WITH src AS (
            SELECT
                h.HISTORY_ID,
                h.CARRIER_CODE,
                h.ROUTE_ID,
                h.FLIGHT_DATE,
                h.DELAY_MINUTES,
                h.CANCELLED_FLAG,
                h.LOAD_FACTOR,
                h.DATA_SOURCE,
                h.CREATED_TS,
                h.UPDATED_TS
            FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_HISTORY') h
            WHERE COALESCE(h.DQ_VALID_FLAG, TRUE) = TRUE
        ),
        lkp AS (
            SELECT
                src.HISTORY_ID,
                da.AIRLINE_KEY AS AIRLINE_KEY,
                -- SKIPPED: gold.fact_flight_history.route_key — Mapping requires lookup dim_route by slv_route.route_id, but gold.dim_route has no route_id natural key column in current Gold DDL.
                CAST(NULL AS INTEGER) AS ROUTE_KEY,
                dd.DATE_KEY AS DATE_KEY,
                src.DELAY_MINUTES,
                src.CANCELLED_FLAG,
                src.LOAD_FACTOR,
                src.DATA_SOURCE,
                src.CREATED_TS,
                src.UPDATED_TS
            FROM src
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_AIRLINE') da
                ON da.AIRLINE_CODE = src.CARRIER_CODE
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_DATE') dd
                ON dd.DATE = src.FLIGHT_DATE
        ),
        final_rows AS (
            SELECT
                HISTORY_ID,
                -- SKIPPED: gold.fact_flight_history.flight_key — Mapping requires lookup through operational flight identifiers not present in Gold.
                CAST(NULL AS BIGINT) AS FLIGHT_KEY,
                AIRLINE_KEY,
                ROUTE_KEY,
                DATE_KEY,
                DELAY_MINUTES,
                CANCELLED_FLAG,
                LOAD_FACTOR,
                DATA_SOURCE,
                DW_CREATED_TS,
                DW_UPDATED_TS
            FROM (
                SELECT
                    HISTORY_ID,
                    AIRLINE_KEY,
                    ROUTE_KEY,
                    DATE_KEY,
                    DELAY_MINUTES,
                    CANCELLED_FLAG,
                    LOAD_FACTOR,
                    DATA_SOURCE,
                    CREATED_TS AS DW_CREATED_TS,
                    UPDATED_TS AS DW_UPDATED_TS
                FROM lkp
            )
        ),
        dedup AS (
            SELECT *
            FROM final_rows
            QUALIFY ROW_NUMBER() OVER (PARTITION BY HISTORY_ID ORDER BY DW_UPDATED_TS DESC) = 1
        )
        SELECT * FROM dedup
    ) AS src
    ON tgt.DATE_KEY = src.DATE_KEY
   AND COALESCE(tgt.AIRLINE_KEY, -1) = COALESCE(src.AIRLINE_KEY, -1)
   AND COALESCE(tgt.DATA_SOURCE, '') = COALESCE(src.DATA_SOURCE, '')
   AND COALESCE(tgt.DELAY_MINUTES, -1) = COALESCE(src.DELAY_MINUTES, -1)
    WHEN MATCHED THEN UPDATE SET
        tgt.FLIGHT_KEY = src.FLIGHT_KEY,
        tgt.AIRLINE_KEY = src.AIRLINE_KEY,
        tgt.ROUTE_KEY = src.ROUTE_KEY,
        tgt.DELAY_MINUTES = src.DELAY_MINUTES,
        tgt.CANCELLED_FLAG = src.CANCELLED_FLAG,
        tgt.LOAD_FACTOR = src.LOAD_FACTOR,
        tgt.DATA_SOURCE = src.DATA_SOURCE,
        tgt.DW_UPDATED_TS = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        FLIGHT_KEY,
        AIRLINE_KEY,
        ROUTE_KEY,
        DATE_KEY,
        DELAY_MINUTES,
        CANCELLED_FLAG,
        LOAD_FACTOR,
        DATA_SOURCE,
        DW_CREATED_TS,
        DW_UPDATED_TS
    ) VALUES (
        src.FLIGHT_KEY,
        src.AIRLINE_KEY,
        src.ROUTE_KEY,
        src.DATE_KEY,
        src.DELAY_MINUTES,
        src.CANCELLED_FLAG,
        src.LOAD_FACTOR,
        src.DATA_SOURCE,
        CURRENT_TIMESTAMP(),
        CURRENT_TIMESTAMP()
    );

    V_AFFECTED := SQLROWCOUNT;

    V_END_TS := CURRENT_TIMESTAMP();
    V_STATUS := 'SUCCESS';

    IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, target_row_count) SELECT ?, ?, ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, V_END_TS, V_STATUS, V_AFFECTED);
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'procedure_name', V_PROC_NAME,
        'target_table', V_TARGET_FQN,
        'status', V_STATUS,
        'merge_affected_rows', V_AFFECTED,
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
