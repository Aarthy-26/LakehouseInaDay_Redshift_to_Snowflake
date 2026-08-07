CREATE OR REPLACE PROCEDURE gold.sp_load_fact_flight_events(
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
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_flight_events';
    V_TARGET_FQN STRING;
    V_START_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    V_END_TS   TIMESTAMP_NTZ;
    V_STATUS   STRING;
    V_ERROR    STRING;

    V_SRC_COUNT NUMBER;
    V_AFFECTED  NUMBER;

    V_AUDIT_DB STRING;
    V_AUDIT_SCHEMA STRING;
    V_AUDIT_TABLE STRING;
    V_AUDIT_FQN STRING;
BEGIN
    V_TARGET_FQN := P_GOLD_SCHEMA || '.FACT_FLIGHT_EVENTS';

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
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_EVENTS') s
        WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = FALSE
    );

    IF (V_INVALID_CNT > 0) THEN
        V_STATUS := 'FAILED';
        V_ERROR := 'DQ validation failed: ' || V_INVALID_CNT || ' rows in ' || P_SILVER_SCHEMA || '.SLV_FLIGHT_EVENTS have DQ_VALID_FLAG=FALSE.';

        IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) SELECT ?, ?, ?, ?, ?, ?'
                USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, CURRENT_TIMESTAMP(), V_STATUS, V_ERROR);
        END IF;

        RAISE STATEMENT_ERROR WITH MESSAGE = V_ERROR;
    END IF;

    V_SRC_COUNT := (
        SELECT COUNT(*)
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_EVENTS') s
        WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = TRUE
    );

    MERGE INTO IDENTIFIER(V_TARGET_FQN) AS tgt
    USING (
        WITH src AS (
            SELECT
                s.EVENT_ID,
                s.FLIGHT_ID,
                s.EVENT_TYPE_CODE,
                s.EVENT_TIMESTAMP,
                s.PRODUCER_SYSTEM,
                s.CONSUMER_SYSTEM,
                s.MESSAGE_SIZE_BYTES,
                s.EVENT_COUNT,
                s.SOURCE_SYSTEM,
                s.CREATED_TS,
                s.UPDATED_TS
            FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_EVENTS') s
            WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = TRUE
        ),
        lkp AS (
            SELECT
                src.EVENT_ID,
                dd.DATE_KEY AS DATE_KEY,
                -- SKIPPED: gold.fact_flight_events.event_type_key — Mapping requires dim_event_type lookup by event_type_code, but gold.dim_event_type does not carry event_type_code.
                CAST(NULL AS INTEGER) AS EVENT_TYPE_KEY,
                -- SKIPPED: gold.fact_flight_events.flight_key — Mapping requires resolving flight_id to flight_key; gold.fact_flight_operations does not carry flight_id/schedule natural key for deterministic lookup.
                CAST(NULL AS BIGINT) AS FLIGHT_KEY,
                src.EVENT_TIMESTAMP,
                src.PRODUCER_SYSTEM,
                src.CONSUMER_SYSTEM,
                src.MESSAGE_SIZE_BYTES,
                src.EVENT_COUNT,
                src.SOURCE_SYSTEM,
                src.CREATED_TS,
                src.UPDATED_TS
            FROM src
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_DATE') dd
                ON dd.DATE = CAST(src.EVENT_TIMESTAMP AS DATE)
        ),
        final_rows AS (
            SELECT
                EVENT_ID,
                FLIGHT_KEY,
                EVENT_TYPE_KEY,
                DATE_KEY,
                EVENT_TIMESTAMP,
                PRODUCER_SYSTEM,
                CONSUMER_SYSTEM,
                MESSAGE_SIZE_BYTES,
                EVENT_COUNT,
                SOURCE_SYSTEM,
                CREATED_TS AS DW_CREATED_TS,
                UPDATED_TS AS DW_UPDATED_TS
            FROM lkp
        ),
        dedup AS (
            SELECT *
            FROM final_rows
            QUALIFY ROW_NUMBER() OVER (PARTITION BY EVENT_ID ORDER BY DW_UPDATED_TS DESC) = 1
        )
        SELECT * FROM dedup
    ) AS src
    ON tgt.EVENT_TIMESTAMP = src.EVENT_TIMESTAMP
   AND COALESCE(tgt.PRODUCER_SYSTEM, '') = COALESCE(src.PRODUCER_SYSTEM, '')
   AND COALESCE(tgt.CONSUMER_SYSTEM, '') = COALESCE(src.CONSUMER_SYSTEM, '')
   AND COALESCE(tgt.MESSAGE_SIZE_BYTES, -1) = COALESCE(src.MESSAGE_SIZE_BYTES, -1)
    WHEN MATCHED THEN UPDATE SET
        tgt.FLIGHT_KEY = src.FLIGHT_KEY,
        tgt.EVENT_TYPE_KEY = src.EVENT_TYPE_KEY,
        tgt.DATE_KEY = src.DATE_KEY,
        tgt.EVENT_TIMESTAMP = src.EVENT_TIMESTAMP,
        tgt.PRODUCER_SYSTEM = src.PRODUCER_SYSTEM,
        tgt.CONSUMER_SYSTEM = src.CONSUMER_SYSTEM,
        tgt.MESSAGE_SIZE_BYTES = src.MESSAGE_SIZE_BYTES,
        tgt.EVENT_COUNT = src.EVENT_COUNT,
        tgt.SOURCE_SYSTEM = src.SOURCE_SYSTEM,
        tgt.DW_UPDATED_TS = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        FLIGHT_KEY,
        EVENT_TYPE_KEY,
        DATE_KEY,
        EVENT_TIMESTAMP,
        PRODUCER_SYSTEM,
        CONSUMER_SYSTEM,
        MESSAGE_SIZE_BYTES,
        EVENT_COUNT,
        SOURCE_SYSTEM,
        DW_CREATED_TS,
        DW_UPDATED_TS
    ) VALUES (
        src.FLIGHT_KEY,
        src.EVENT_TYPE_KEY,
        src.DATE_KEY,
        src.EVENT_TIMESTAMP,
        src.PRODUCER_SYSTEM,
        src.CONSUMER_SYSTEM,
        src.MESSAGE_SIZE_BYTES,
        src.EVENT_COUNT,
        src.SOURCE_SYSTEM,
        CURRENT_TIMESTAMP(),
        CURRENT_TIMESTAMP()
    );

    V_AFFECTED := SQLROWCOUNT;

    V_END_TS := CURRENT_TIMESTAMP();
    V_STATUS := 'SUCCESS';

    IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, source_row_count, target_row_count) SELECT ?, ?, ?, ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, V_END_TS, V_STATUS, V_SRC_COUNT, V_AFFECTED);
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'procedure_name', V_PROC_NAME,
        'target_table', V_TARGET_FQN,
        'status', V_STATUS,
        'source_row_count', V_SRC_COUNT,
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
