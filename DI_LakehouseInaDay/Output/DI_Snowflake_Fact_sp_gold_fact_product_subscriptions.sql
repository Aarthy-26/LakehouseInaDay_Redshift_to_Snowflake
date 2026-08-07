CREATE OR REPLACE PROCEDURE gold.sp_load_fact_product_subscriptions(
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
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_product_subscriptions';
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
    V_TARGET_FQN := P_GOLD_SCHEMA || '.FACT_PRODUCT_SUBSCRIPTIONS';

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
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_SUBSCRIPTION') s
        WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = FALSE
    );

    IF (V_INVALID_CNT > 0) THEN
        V_STATUS := 'FAILED';
        V_ERROR := 'DQ validation failed: ' || V_INVALID_CNT || ' rows in ' || P_SILVER_SCHEMA || '.SLV_SUBSCRIPTION have DQ_VALID_FLAG=FALSE.';

        IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) SELECT ?, ?, ?, ?, ?, ?'
                USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, CURRENT_TIMESTAMP(), V_STATUS, V_ERROR);
        END IF;

        RAISE STATEMENT_ERROR WITH MESSAGE = V_ERROR;
    END IF;

    V_SRC_COUNT := (
        SELECT COUNT(*)
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_SUBSCRIPTION') s
        WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = TRUE
    );

    MERGE INTO IDENTIFIER(V_TARGET_FQN) AS tgt
    USING (
        WITH src AS (
            SELECT
                s.SUBSCRIPTION_ID,
                s.CUSTOMER_ID,
                s.PRODUCT_CODE,
                s.START_DATE,
                s.END_DATE,
                s.SUBSCRIPTION_TIER,
                s.SUBSCRIPTION_STATUS,
                s.SOURCE_SYSTEM,
                s.CREATED_TS,
                s.UPDATED_TS
            FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_SUBSCRIPTION') s
            WHERE COALESCE(s.DQ_VALID_FLAG, TRUE) = TRUE
        ),
        lkp AS (
            SELECT
                src.SUBSCRIPTION_ID,
                -- SKIPPED: gold.fact_product_subscriptions.customer_key — Mapping requires lookup dim_customer by customer_id, but gold.dim_customer does not carry customer_id.
                CAST(NULL AS INTEGER) AS CUSTOMER_KEY,
                -- SKIPPED: gold.fact_product_subscriptions.product_key — Mapping requires lookup dim_data_product by product_code, but gold.dim_data_product does not carry product_code.
                CAST(NULL AS INTEGER) AS PRODUCT_KEY,
                src.START_DATE,
                src.END_DATE,
                src.SUBSCRIPTION_TIER,
                src.SUBSCRIPTION_STATUS,
                src.SOURCE_SYSTEM,
                src.CREATED_TS,
                src.UPDATED_TS
            FROM src
        ),
        final_rows AS (
            SELECT
                SUBSCRIPTION_ID,
                CUSTOMER_KEY,
                PRODUCT_KEY,
                START_DATE,
                END_DATE,
                SUBSCRIPTION_TIER,
                SUBSCRIPTION_STATUS,
                SOURCE_SYSTEM,
                CREATED_TS AS DW_CREATED_TS,
                UPDATED_TS AS DW_UPDATED_TS
            FROM lkp
        ),
        dedup AS (
            SELECT *
            FROM final_rows
            QUALIFY ROW_NUMBER() OVER (PARTITION BY SUBSCRIPTION_ID ORDER BY DW_UPDATED_TS DESC) = 1
        )
        SELECT * FROM dedup
    ) AS src
    ON COALESCE(tgt.SUBSCRIPTION_TIER, '') = COALESCE(src.SUBSCRIPTION_TIER, '')
   AND COALESCE(tgt.SUBSCRIPTION_STATUS, '') = COALESCE(src.SUBSCRIPTION_STATUS, '')
   AND COALESCE(tgt.START_DATE, '1900-01-01'::DATE) = COALESCE(src.START_DATE, '1900-01-01'::DATE)
   AND COALESCE(tgt.END_DATE, '1900-01-01'::DATE) = COALESCE(src.END_DATE, '1900-01-01'::DATE)
    WHEN MATCHED THEN UPDATE SET
        tgt.CUSTOMER_KEY = src.CUSTOMER_KEY,
        tgt.PRODUCT_KEY = src.PRODUCT_KEY,
        tgt.START_DATE = src.START_DATE,
        tgt.END_DATE = src.END_DATE,
        tgt.SUBSCRIPTION_TIER = src.SUBSCRIPTION_TIER,
        tgt.SUBSCRIPTION_STATUS = src.SUBSCRIPTION_STATUS,
        tgt.SOURCE_SYSTEM = src.SOURCE_SYSTEM,
        tgt.DW_UPDATED_TS = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        CUSTOMER_KEY,
        PRODUCT_KEY,
        START_DATE,
        END_DATE,
        SUBSCRIPTION_TIER,
        SUBSCRIPTION_STATUS,
        SOURCE_SYSTEM,
        DW_CREATED_TS,
        DW_UPDATED_TS
    ) VALUES (
        src.CUSTOMER_KEY,
        src.PRODUCT_KEY,
        src.START_DATE,
        src.END_DATE,
        src.SUBSCRIPTION_TIER,
        src.SUBSCRIPTION_STATUS,
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
