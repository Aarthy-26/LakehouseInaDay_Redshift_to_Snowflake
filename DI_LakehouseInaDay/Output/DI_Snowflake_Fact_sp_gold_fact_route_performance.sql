CREATE OR REPLACE PROCEDURE gold.sp_load_fact_route_performance(
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
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_route_performance';
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
    V_TARGET_FQN := P_GOLD_SCHEMA || '.FACT_ROUTE_PERFORMANCE';

    V_AUDIT_DB := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 1);
    V_AUDIT_SCHEMA := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 2);
    V_AUDIT_TABLE := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 3);
    V_AUDIT_FQN := V_AUDIT_DB || '.' || V_AUDIT_SCHEMA || '.' || V_AUDIT_TABLE;

    IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, status) ' ||
            'SELECT ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, 'RUNNING');
    END IF;

    LET V_INVALID_CNT NUMBER := (
        SELECT COUNT(*)
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS') f
        WHERE COALESCE(f.DQ_VALID_FLAG, TRUE) = FALSE
    );

    IF (V_INVALID_CNT > 0) THEN
        V_STATUS := 'FAILED';
        V_ERROR := 'DQ validation failed: ' || V_INVALID_CNT || ' rows in ' || P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS have DQ_VALID_FLAG=FALSE.';

        IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) ' ||
                'SELECT ?, ?, ?, ?, ?, ?'
                USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, CURRENT_TIMESTAMP(), V_STATUS, V_ERROR);
        END IF;

        RAISE STATEMENT_ERROR WITH MESSAGE = V_ERROR;
    END IF;

    MERGE INTO IDENTIFIER(V_TARGET_FQN) AS tgt
    USING (
        WITH src AS (
            SELECT
                f.ROUTE_ID,
                f.FLIGHT_DATE,
                f.DELAY_MINUTES,
                f.CANCELLED_FLAG,
                f.SOURCE_SYSTEM,
                f.UPDATED_TS
            FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS') f
            WHERE COALESCE(f.DQ_VALID_FLAG, TRUE) = TRUE
              AND f.ROUTE_ID IS NOT NULL
              AND f.FLIGHT_DATE IS NOT NULL
        ),
        agg AS (
            SELECT
                ROUTE_ID,
                FLIGHT_DATE,
                COUNT(*)::INTEGER AS FLIGHT_COUNT,
                SUM(IFF(DELAY_MINUTES > 15, 1, 0))::INTEGER AS DELAY_COUNT,
                SUM(IFF(CANCELLED_FLAG = TRUE, 1, 0))::INTEGER AS CANCEL_COUNT,
                AVG(DELAY_MINUTES)::NUMBER(10,2) AS AVG_DELAY_MINUTES,
                LISTAGG(DISTINCT SOURCE_SYSTEM, ',') WITHIN GROUP (ORDER BY SOURCE_SYSTEM) AS SOURCE_SYSTEM,
                MAX(UPDATED_TS) AS MAX_UPD_TS
            FROM src
            GROUP BY ROUTE_ID, FLIGHT_DATE
        ),
        lkp AS (
            SELECT
                dd.DATE_KEY,
                -- SKIPPED: gold.fact_route_performance.route_key — Mapping requires lookup dim_route by slv_route.route_id, but gold.dim_route has no route_id natural key column in current Gold DDL.
                CAST(NULL AS INTEGER) AS ROUTE_KEY,
                a.FLIGHT_COUNT,
                a.DELAY_COUNT,
                a.CANCEL_COUNT,
                a.AVG_DELAY_MINUTES,
                -- otp_percentage = (flight_count - delay_count) / flight_count * 100
                IFF(a.FLIGHT_COUNT = 0, NULL, ((a.FLIGHT_COUNT - a.DELAY_COUNT) / a.FLIGHT_COUNT::NUMBER(10,2)) * 100)::NUMBER(5,2) AS OTP_PERCENTAGE,
                a.SOURCE_SYSTEM,
                a.MAX_UPD_TS
            FROM agg a
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_DATE') dd
                ON dd.DATE = a.FLIGHT_DATE
        ),
        dedup AS (
            SELECT *
            FROM lkp
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY DATE_KEY, ROUTE_KEY
                ORDER BY MAX_UPD_TS DESC
            ) = 1
        )
        SELECT
            DATE_KEY,
            ROUTE_KEY,
            FLIGHT_COUNT,
            DELAY_COUNT,
            CANCEL_COUNT,
            AVG_DELAY_MINUTES,
            OTP_PERCENTAGE,
            SOURCE_SYSTEM,
            CURRENT_TIMESTAMP() AS DW_CREATED_TS,
            CURRENT_TIMESTAMP() AS DW_UPDATED_TS
        FROM dedup
    ) AS src
    ON tgt.DATE_KEY = src.DATE_KEY
   AND COALESCE(tgt.ROUTE_KEY, -1) = COALESCE(src.ROUTE_KEY, -1)
    WHEN MATCHED THEN UPDATE SET
        tgt.FLIGHT_COUNT = src.FLIGHT_COUNT,
        tgt.DELAY_COUNT = src.DELAY_COUNT,
        tgt.CANCEL_COUNT = src.CANCEL_COUNT,
        tgt.AVG_DELAY_MINUTES = src.AVG_DELAY_MINUTES,
        tgt.OTP_PERCENTAGE = src.OTP_PERCENTAGE,
        tgt.SOURCE_SYSTEM = src.SOURCE_SYSTEM,
        tgt.DW_UPDATED_TS = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        DATE_KEY,
        ROUTE_KEY,
        FLIGHT_COUNT,
        DELAY_COUNT,
        CANCEL_COUNT,
        AVG_DELAY_MINUTES,
        OTP_PERCENTAGE,
        SOURCE_SYSTEM,
        DW_CREATED_TS,
        DW_UPDATED_TS
    ) VALUES (
        src.DATE_KEY,
        src.ROUTE_KEY,
        src.FLIGHT_COUNT,
        src.DELAY_COUNT,
        src.CANCEL_COUNT,
        src.AVG_DELAY_MINUTES,
        src.OTP_PERCENTAGE,
        src.SOURCE_SYSTEM,
        CURRENT_TIMESTAMP(),
        CURRENT_TIMESTAMP()
    );

    V_AFFECTED := SQLROWCOUNT;

    V_END_TS := CURRENT_TIMESTAMP();
    V_STATUS := 'SUCCESS';

    IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, target_row_count) ' ||
            'SELECT ?, ?, ?, ?, ?, ?'
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
                'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) ' ||
                'SELECT ?, ?, ?, ?, ?, ?'
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
