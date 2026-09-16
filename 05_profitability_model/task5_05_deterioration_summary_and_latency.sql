-- ============================================================================
-- task5_05_deterioration_summary_and_latency.sql
-- AstraPay Root-Cause Investigation — Task 5
-- Query 5: Cross-dimension deterioration ranking + latency incident test
--
-- GRAIN OUTPUT : Query A → 1 row per dimension (summary table)
--                Query B → 1 row per route and period (latency test)
--                Query C → 1 row per (route, month, latency bucket)
-- DEPENDS ON   : 01_staging_views.sql, 02_fact_transaction_economics.sql
--
-- PURPOSE
-- Brings together the findings from scripts 02, 03, 04 into:
--   A) A single ranked summary: which dimension and segment explains
--      the most of the overall deterioration?
--   B) A direct test of the latency hypothesis: does the March R3/R5
--      processing spike correlate with profit decline?
-- ============================================================================


-- ── QUERY A: Cross-dimension deterioration ranked summary ─────────────────
-- For each dimension (route, channel, category, country, customer segment),
-- this query identifies the single largest contributing segment and quantifies
-- its total effect. Run after task5_02 and task5_03 for context.
--
-- NOTE: Because SQLite does not support FULL OUTER JOIN, this script
-- implements the decomposition for Route only inline. For other dimensions,
-- replace route_id with the relevant column (see task5_02 and task5_03 for
-- the full CTE pattern — those scripts are identical in structure).
-- In Snowflake/Postgres/BigQuery, you can use FULL OUTER JOIN to handle
-- routes that appear in one period but not the other.

WITH
baseline_route AS (
    SELECT route_id AS seg,
           SUM(is_profit_kpi_eligible) AS n,
           SUM(CASE WHEN is_profit_kpi_eligible=1 THEN contribution_profit_usd ELSE 0 END) AS ps
    FROM fact_transaction_profit_final
    WHERE created_month IN ('2025-01','2025-02') AND route_id IS NOT NULL
    GROUP BY route_id
),
latest_route AS (
    SELECT route_id AS seg,
           SUM(is_profit_kpi_eligible) AS n,
           SUM(CASE WHEN is_profit_kpi_eligible=1 THEN contribution_profit_usd ELSE 0 END) AS ps
    FROM fact_transaction_profit_final
    WHERE created_month IN ('2025-05','2025-06') AND route_id IS NOT NULL
    GROUP BY route_id
),
totals AS (
    SELECT
        (SELECT SUM(n) FROM baseline_route) AS b_total,
        (SELECT SUM(n) FROM latest_route)   AS l_total
)
SELECT
    'Route' AS dimension,
    b.seg   AS top_segment,
    ROUND(
        -- mix effect
        (1.0*COALESCE(l.n,0)/t.l_total - 1.0*COALESCE(b.n,0)/t.b_total)
        * (1.0*COALESCE(b.ps,0)/NULLIF(COALESCE(b.n,0),0))
        -- rate effect
        + (1.0*COALESCE(l.n,0)/t.l_total)
          * (1.0*COALESCE(l.ps,0)/NULLIF(COALESCE(l.n,0),0)
             - 1.0*COALESCE(b.ps,0)/NULLIF(COALESCE(b.n,0),0)),
        4
    )       AS total_effect_usd,
    ROUND(
        (1.0*COALESCE(l.n,0)/t.l_total - 1.0*COALESCE(b.n,0)/t.b_total)
        * (1.0*COALESCE(b.ps,0)/NULLIF(COALESCE(b.n,0),0)),
        4
    )       AS mix_effect_usd,
    ROUND(
        (1.0*COALESCE(l.n,0)/t.l_total)
        * (1.0*COALESCE(l.ps,0)/NULLIF(COALESCE(l.n,0),0)
           - 1.0*COALESCE(b.ps,0)/NULLIF(COALESCE(b.n,0),0)),
        4
    )       AS rate_effect_usd
FROM baseline_route b
JOIN latest_route l ON l.seg = b.seg
JOIN totals t ON 1=1
ORDER BY ABS(total_effect_usd) DESC
LIMIT 1;

-- ── EXPECTED RESULT ───────────────────────────────────────────────────────
-- dimension | top_segment | total_effect | mix_effect | rate_effect
-- Route     |    R3       |   -0.139     |  +0.038    |   -0.177
--
-- READING: Route R3 is the top contributor. Its rate effect (-0.177) means
-- R3's OWN economics collapsed by 17.7 cents per transaction. Its mix effect
-- (+0.038) is positive — more volume moved to R3 — which PARTIALLY offset
-- the rate collapse but not enough to prevent the net -0.139 total effect.


-- ============================================================
-- QUERY B: Latency incident test — does the March spike explain profit?
-- ============================================================
-- The processing latency spike on R3 during 10-25 March 2025 was real
-- (~5.7x slower). But does it explain the profit decline?
-- This query compares R3 transactions inside vs outside the spike window
-- to test whether latency correlates with lower profit.

SELECT
    CASE
        WHEN created_at BETWEEN '2025-03-10' AND '2025-03-25 23:59:59'
             AND route_id = 'R3'
        THEN 'Mar 10-25 (spike window) — R3'
        WHEN SUBSTR(created_at,1,7) = '2025-03'
             AND route_id = 'R3'
        THEN 'Rest of March — R3'
        WHEN route_id = 'R3'
        THEN 'All other months — R3'
        ELSE 'Other routes (control)'
    END                                                                AS bucket,

    COUNT(*)                                                           AS attempted_txns,
    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)               AS successful_txns,
    ROUND(
        1.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
            / COUNT(*), 4
    )                                                                  AS success_rate,
    SUM(is_profit_kpi_eligible)                                        AS eligible_txns,
    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN contribution_profit_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_contribution_profit_usd

FROM fact_transaction_profit_final
GROUP BY bucket
ORDER BY bucket;

-- ── EXPECTED OUTPUT ───────────────────────────────────────────────────────
-- bucket                         | attempts | success_rate | avg_profit
-- All other months — R3          |    2,063 |    89.0%     |  $0.1085
-- Mar 10-25 (spike) — R3         |      204 |    87.3%     |  $0.2174  ← higher profit
-- Rest of March — R3             |      212 |    88.7%     |  $0.3802  ← highest
-- Other routes (control)         |    5,521 |    87.6%     |  $0.3108
--
-- CRITICAL FINDING: profit in the latency window ($0.217) is HIGHER than the
-- all-other-months R3 average ($0.109). This is because the spike was in March,
-- BEFORE the 1-Apr fee increase. The latency incident has no meaningful
-- correlation with profit decline — the profit fell in April due to the fee
-- change, not in March due to the latency. The incident is a customer
-- experience / SLA problem, not a profitability problem.


-- ── QUERY C: Processing latency distribution — R3 vs others, by period ────
-- Shows the raw latency numbers. Confirms the spike was real but contained.
-- Note: processing_ms is NULL for 'created' and 'authorized' events by design
-- (DQ report D02). This query filters to terminal events only.

SELECT
    SUBSTR(t.created_at, 1, 7)                                        AS created_month,
    t.route_id,
    COUNT(pe.processing_ms)                                            AS event_count,
    ROUND(AVG(pe.processing_ms), 0)                                   AS avg_processing_ms,
    ROUND(
        -- approximate median using a simple approach
        (SELECT p.processing_ms
         FROM payment_event p
         JOIN "transaction" tt ON tt.transaction_id = p.transaction_id
         WHERE SUBSTR(tt.created_at,1,7) = SUBSTR(t.created_at,1,7)
           AND tt.route_id = t.route_id
           AND p.processing_ms IS NOT NULL
           AND p.event_type IN ('captured','declined','reversed')
         ORDER BY p.processing_ms
         LIMIT 1
         OFFSET (
             SELECT COUNT(*)/2
             FROM payment_event pp
             JOIN "transaction" ttt ON ttt.transaction_id = pp.transaction_id
             WHERE SUBSTR(ttt.created_at,1,7) = SUBSTR(t.created_at,1,7)
               AND ttt.route_id = t.route_id
               AND pp.processing_ms IS NOT NULL
               AND pp.event_type IN ('captured','declined','reversed')
         )
        ), 0
    )                                                                  AS approx_median_ms,
    MIN(pe.processing_ms)                                              AS min_ms,
    MAX(pe.processing_ms)                                              AS max_ms

FROM payment_event pe
JOIN "transaction" t ON t.transaction_id = pe.transaction_id
WHERE pe.processing_ms IS NOT NULL
  AND pe.event_type IN ('captured', 'declined', 'reversed')
GROUP BY SUBSTR(t.created_at, 1, 7), t.route_id
ORDER BY t.route_id, created_month;


-- ── QUERY D: Late-arriving events check (timeliness, DQ report D14/D15) ───
-- Confirms that 4.94% of events arrive 3-9 days after the event occurred.
-- Use ingestion_time ONLY for pipeline monitoring — never for business KPIs.

SELECT
    event_type,
    COUNT(*)                                                           AS total_events,
    SUM(CASE
            WHEN (JULIANDAY(ingestion_time) - JULIANDAY(event_time)) > 1
            THEN 1 ELSE 0
        END)                                                           AS late_arrivals_over_1day,
    ROUND(
        1.0 * SUM(CASE
                      WHEN (JULIANDAY(ingestion_time) - JULIANDAY(event_time)) > 1
                      THEN 1 ELSE 0
                  END)
            / COUNT(*),
        4
    )                                                                  AS pct_late,
    ROUND(
        AVG(JULIANDAY(ingestion_time) - JULIANDAY(event_time)) * 24, 1
    )                                                                  AS avg_lag_hours

FROM payment_event
WHERE ingestion_time IS NOT NULL
  AND event_time IS NOT NULL
GROUP BY event_type
ORDER BY pct_late DESC;
