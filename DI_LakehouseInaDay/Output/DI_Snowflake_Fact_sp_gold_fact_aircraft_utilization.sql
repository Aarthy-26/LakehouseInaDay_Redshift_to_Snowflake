CREATE OR REPLACE PROCEDURE gold.sp_load_fact_aircraft_utilization(
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
    V_PROC_NAME STRING DEFAULT 'gold.sp_load_fact_aircraft_utilization';
    V_TARGET_FQN STRING;
    V_START_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    V_END_TS   TIMESTAMP_NTZ;
    V_STATUS   STRING;
    V_ERROR    STRING;

    V_AFFECTED  NUMBER;

    V_AUDIT_DB STRING;
    V_AUDIT_SCHEMA STRING;
    V_AUDIT_TABLE STRING;
    V_AUDIT_FQN STRING;
BEGIN
    V_TARGET_FQN := P_GOLD_SCHEMA || '.FACT_AIRCRAFT_UTILIZATION';

    V_AUDIT_DB := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 1);
    V_AUDIT_SCHEMA := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 2);
    V_AUDIT_TABLE := SPLIT_PART(P_AUDIT_TABLE_FQN, '.', 3);
    V_AUDIT_FQN := V_AUDIT_DB || '.' || V_AUDIT_SCHEMA || '.' || V_AUDIT_TABLE;

    IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
        EXECUTE IMMEDIATE
            'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, status) SELECT ?, ?, ?, ?'
            USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, 'RUNNING');
    END IF;

    LET V_INV_FLT NUMBER := (
        SELECT COUNT(*)
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS') f
        WHERE COALESCE(f.DQ_VALID_FLAG, TRUE) = FALSE
    );

    LET V_INV_MAINT NUMBER := (
        SELECT COUNT(*)
        FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_AIRCRAFT_MAINTENANCE') m
        WHERE COALESCE(m.DQ_VALID_FLAG, TRUE) = FALSE
    );

    IF (V_INV_FLT > 0 OR V_INV_MAINT > 0) THEN
        V_STATUS := 'FAILED';
        V_ERROR := 'DQ validation failed: invalid rows exist in Silver inputs. SLV_FLIGHT_OPERATIONS invalid=' || V_INV_FLT || ', SLV_AIRCRAFT_MAINTENANCE invalid=' || V_INV_MAINT;

        IF UPPER(V_TARGET_FQN) <> UPPER(V_AUDIT_FQN) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO ' || V_AUDIT_FQN || ' (procedure_name, target_table, start_ts, end_ts, status, error_message) SELECT ?, ?, ?, ?, ?, ?'
                USING (V_PROC_NAME, V_TARGET_FQN, V_START_TS, CURRENT_TIMESTAMP(), V_STATUS, V_ERROR);
        END IF;

        RAISE STATEMENT_ERROR WITH MESSAGE = V_ERROR;
    END IF;

    MERGE INTO IDENTIFIER(V_TARGET_FQN) AS tgt
    USING (
        WITH flt AS (
            SELECT
                f.TAIL_NUMBER,
                f.FLIGHT_DATE,
                f.BLOCK_HOURS,
                f.DELAY_MINUTES,
                f.SOURCE_SYSTEM,
                f.UPDATED_TS
            FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_FLIGHT_OPERATIONS') f
            WHERE COALESCE(f.DQ_VALID_FLAG, TRUE) = TRUE
              AND f.TAIL_NUMBER IS NOT NULL
              AND f.FLIGHT_DATE IS NOT NULL
        ),
        maint AS (
            SELECT
                m.TAIL_NUMBER,
                CAST(m.MAINTENANCE_START_TS AS DATE) AS MAINT_DATE,
                m.DOWNTIME_HOURS,
                m.TOTAL_LABOR_HOURS,
                m.PARTS_COUNT,
                m.DISCREPANCY_COUNT,
                m.SOURCE_SYSTEM,
                m.UPDATED_TS
            FROM IDENTIFIER(P_SILVER_SCHEMA || '.SLV_AIRCRAFT_MAINTENANCE') m
            WHERE COALESCE(m.DQ_VALID_FLAG, TRUE) = TRUE
              AND m.TAIL_NUMBER IS NOT NULL
              AND m.MAINTENANCE_START_TS IS NOT NULL
        ),
        agg_flt AS (
            SELECT
                TAIL_NUMBER,
                FLIGHT_DATE,
                COUNT(*)::INTEGER AS FLIGHT_COUNT,
                SUM(BLOCK_HOURS)::NUMBER(10,2) AS UTILIZATION_HOURS,
                AVG(DELAY_MINUTES)::NUMBER(10,2) AS AVERAGE_DELAY_MINUTES,
                LISTAGG(DISTINCT SOURCE_SYSTEM, ',') WITHIN GROUP (ORDER BY SOURCE_SYSTEM) AS FLT_SOURCE_SYSTEM,
                MAX(UPDATED_TS) AS MAX_UPD_TS
            FROM flt
            GROUP BY TAIL_NUMBER, FLIGHT_DATE
        ),
        agg_maint AS (
            SELECT
                TAIL_NUMBER,
                MAINT_DATE,
                SUM(DOWNTIME_HOURS)::NUMBER(10,2) AS MAINTENANCE_HOURS,
                SUM(TOTAL_LABOR_HOURS)::NUMBER(10,2) AS TOTAL_LABOR_HOURS,
                SUM(PARTS_COUNT)::INTEGER AS TOTAL_PARTS_USED,
                SUM(DISCREPANCY_COUNT)::INTEGER AS TOTAL_DISCREPANCIES,
                LISTAGG(DISTINCT SOURCE_SYSTEM, ',') WITHIN GROUP (ORDER BY SOURCE_SYSTEM) AS MAINT_SOURCE_SYSTEM,
                MAX(UPDATED_TS) AS MAX_UPD_TS
            FROM maint
            GROUP BY TAIL_NUMBER, MAINT_DATE
        ),
        spine AS (
            SELECT TAIL_NUMBER, FLIGHT_DATE AS CAL_DATE FROM agg_flt
            UNION
            SELECT TAIL_NUMBER, MAINT_DATE AS CAL_DATE FROM agg_maint
        ),
        joined AS (
            SELECT
                s.TAIL_NUMBER,
                s.CAL_DATE,
                COALESCE(f.FLIGHT_COUNT, 0) AS FLIGHT_COUNT,
                f.UTILIZATION_HOURS,
                m.MAINTENANCE_HOURS,
                m.TOTAL_LABOR_HOURS,
                m.TOTAL_PARTS_USED,
                m.TOTAL_DISCREPANCIES,
                f.AVERAGE_DELAY_MINUTES,
                COALESCE(f.FLT_SOURCE_SYSTEM, '') AS FLT_SOURCE_SYSTEM,
                COALESCE(m.MAINT_SOURCE_SYSTEM, '') AS MAINT_SOURCE_SYSTEM,
                GREATEST(COALESCE(f.MAX_UPD_TS, '1970-01-01'::TIMESTAMP), COALESCE(m.MAX_UPD_TS, '1970-01-01'::TIMESTAMP)) AS MAX_UPD_TS
            FROM spine s
            LEFT JOIN agg_flt f
                ON f.TAIL_NUMBER = s.TAIL_NUMBER
               AND f.FLIGHT_DATE = s.CAL_DATE
            LEFT JOIN agg_maint m
                ON m.TAIL_NUMBER = s.TAIL_NUMBER
               AND m.MAINT_DATE = s.CAL_DATE
        ),
        lkp AS (
            SELECT
                dd.DATE_KEY,
                da.AIRCRAFT_KEY,
                da.OPERATOR_AIRLINE_KEY,
                j.FLIGHT_COUNT,
                j.UTILIZATION_HOURS,
                -- SKIPPED: gold.fact_aircraft_utilization.ground_hours — No explicit formula provided for "turnaround/idle time between flights".
                CAST(NULL AS NUMBER(10,2)) AS GROUND_HOURS,
                j.MAINTENANCE_HOURS,
                -- SKIPPED: gold.fact_aircraft_utilization.available_hours — Depends on ground_hours residual; mapping requires reconciliation to 24.
                CAST(NULL AS NUMBER(10,2)) AS AVAILABLE_HOURS,
                j.TOTAL_LABOR_HOURS,
                j.TOTAL_PARTS_USED,
                j.TOTAL_DISCREPANCIES,
                j.AVERAGE_DELAY_MINUTES,
                NULLIF(
                    TRIM(BOTH ',' FROM CONCAT(
                        IFF(j.FLT_SOURCE_SYSTEM <> '', j.FLT_SOURCE_SYSTEM, ''),
                        IFF(j.MAINT_SOURCE_SYSTEM <> '' AND j.FLT_SOURCE_SYSTEM <> '', ',', ''),
                        IFF(j.MAINT_SOURCE_SYSTEM <> '', j.MAINT_SOURCE_SYSTEM, '')
                    )),
                '') AS SOURCE_SYSTEM,
                j.MAX_UPD_TS
            FROM joined j
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_DATE') dd
                ON dd.DATE = j.CAL_DATE
            LEFT JOIN IDENTIFIER(P_GOLD_SCHEMA || '.DIM_AIRCRAFT') da
                ON da.TAIL_NUMBER = j.TAIL_NUMBER
               AND j.CAL_DATE BETWEEN da.EFFECTIVE_START_DATE AND COALESCE(da.EFFECTIVE_END_DATE, '9999-12-31')
        ),
        dedup AS (
            SELECT *
            FROM lkp
            QUALIFY ROW_NUMBER() OVER (PARTITION BY DATE_KEY, AIRCRAFT_KEY, OPERATOR_AIRLINE_KEY ORDER BY MAX_UPD_TS DESC) = 1
        )
        SELECT
            DATE_KEY,
            AIRCRAFT_KEY,
            OPERATOR_AIRLINE_KEY,
            FLIGHT_COUNT,
            UTILIZATION_HOURS,
            GROUND_HOURS,
            MAINTENANCE_HOURS,
            AVAILABLE_HOURS,
            TOTAL_LABOR_HOURS,
            TOTAL_PARTS_USED,
            TOTAL_DISCREPANCIES,
            AVERAGE_DELAY_MINUTES,
            SOURCE_SYSTEM,
            CURRENT_TIMESTAMP() AS DW_CREATED_TS,
            CURRENT_TIMESTAMP() AS DW_UPDATED_TS
        FROM dedup
    ) AS src
    ON tgt.DATE_KEY = src.DATE_KEY
   AND COALESCE(tgt.AIRCRAFT_KEY, -1) = COALESCE(src.AIRCRAFT_KEY, -1)
   AND COALESCE(tgt.OPERATOR_AIRLINE_KEY, -1) = COALESCE(src.OPERATOR_AIRLINE_KEY, -1)
    WHEN MATCHED THEN UPDATE SET
        tgt.FLIGHT_COUNT = src.FLIGHT_COUNT,
        tgt.UTILIZATION_HOURS = src.UTILIZATION_HOURS,
        tgt.GROUND_HOURS = src.GROUND_HOURS,
        tgt.MAINTENANCE_HOURS = src.MAINTENANCE_HOURS,
        tgt.AVAILABLE_HOURS = src.AVAILABLE_HOURS,
        tgt.TOTAL_LABOR_HOURS = src.TOTAL_LABOR_HOURS,
        tgt.TOTAL_PARTS_USED = src.TOTAL_PARTS_USED,
        tgt.TOTAL_DISCREPANCIES = src.TOTAL_DISCREPANCIES,
        tgt.AVERAGE_DELAY_MINUTES = src.AVERAGE_DELAY_MINUTES,
        tgt.SOURCE_SYSTEM = src.SOURCE_SYSTEM,
        tgt.DW_UPDATED_TS = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        DATE_KEY,
        AIRCRAFT_KEY,
        OPERATOR_AIRLINE_KEY,
        FLIGHT_COUNT,
        UTILIZATION_HOURS,
        GROUND_HOURS,
        MAINTENANCE_HOURS,
        AVAILABLE_HOURS,
        TOTAL_LABOR_HOURS,
        TOTAL_PARTS_USED,
        TOTAL_DISCREPANCIES,
        AVERAGE_DELAY_MINUTES,
        SOURCE_SYSTEM,
        DW_CREATED_TS,
        DW_UPDATED_TS
    ) VALUES (
        src.DATE_KEY,
        src.AIRCRAFT_KEY,
        src.OPERATOR_AIRLINE_KEY,
        src.FLIGHT_COUNT,
        src.UTILIZATION_HOURS,
        src.GROUND_HOURS,
        src.MAINTENANCE_HOURS,
        src.AVAILABLE_HOURS,
        src.TOTAL_LABOR_HOURS,
        src.TOTAL_PARTS_USED,
        src.TOTAL_DISCREPANCIES,
        src.AVERAGE_DELAY_MINUTES,
        src.SOURCE_SYSTEM,
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
