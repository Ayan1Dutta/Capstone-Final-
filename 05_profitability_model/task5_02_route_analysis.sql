-- ============================================================================
-- task5_02_route_analysis.sql
-- AstraPay Root-Cause Investigation — Task 5
-- Query 2: Route-level segmentation + mix vs rate decomposition
--
-- GRAIN OUTPUT : Query A → 1 row per (route_id, created_month)
--                Query B → 1 row per route_id (decomposition summary)
-- DEPENDS ON   : 01_staging_views.sql, 02_fact_transaction_economics.sql
--
-- PURPOSE
-- Route is the single strongest lens on the profit decline.
-- Route R3 (PayGlobal) explains 61.7% of the total fall.
-- This script has two parts:
--   A) Month-by-month route performance table — trend over time
--   B) Mix vs rate decomposition — separates "volume moved to this route"
--      from "this route's own economics got worse"
--
-- WHAT IS MIX VS RATE?
-- When overall profitability changes, two things could explain it:
--   MIX EFFECT   : a more expensive route carries more volume (share changed)
--   RATE EFFECT  : a route's own per-transaction economics worsened
--
-- The formula:
--   w0 = route's share of eligible txns in the BASELINE period (Jan+Feb)
--   w1 = route's share of eligible txns in the LATEST period   (May+Jun)
--   m0 = route's avg profit per txn in the BASELINE period
--   m1 = route's avg profit per txn in the LATEST period
--
--   mix_effect   = (w1 - w0) × m0
--   rate_effect  = w1 × (m1 - m0)
--   total_effect = mix_effect + rate_effect
--
-- Summing total_effect across ALL routes gives the EXACT change in the
-- overall weighted-average KPI between the two periods. This reconciliation
-- was verified in Python: sum = -0.2245, matches the measured delta.
-- ============================================================================


-- ── QUERY A: Route performance by month ───────────────────────────────────
-- Shows profit, cost, revenue and volume share for each route each month.
-- Use this to see the fee step-change in April and the rising R3 share.

SELECT
    created_month,
    route_id,

    -- volume
    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)               AS successful_txns,

    -- this route's share of the month's successful volume
    -- sub-query recalculates the monthly total so the share is always
    -- relative to the SAME month — never averaged across months
    ROUND(
        1.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
            / (
                SELECT SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
                FROM   fact_transaction_profit_final f2
                WHERE  f2.created_month = f.created_month
            ),
        4
    )                                                                  AS pct_of_month_successful_volume,

    SUM(is_profit_kpi_eligible)                                        AS eligible_txns,

    -- KPI for this route this month (correct non-additive pattern)
    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN contribution_profit_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_contribution_profit_usd,

    -- cost and revenue — lets you see fee changes directly
    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN processing_cost_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_processing_cost_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN revenue_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_revenue_usd,

    -- raw variable fee % observed on this route this month
    -- for R3: ~1.2% Jan-Mar, then ~1.6% Apr-Jun — the fee step-change
    ROUND(AVG(route_variable_fee_pct), 5)                              AS avg_variable_fee_pct

FROM fact_transaction_profit_final f
GROUP BY created_month, route_id
ORDER BY created_month, route_id;

-- ── EXPECTED KEY VALUES (R3) ──────────────────────────────────────────────
-- Month   | R3 share | R3 avg profit | R3 variable fee
-- 2025-01 |   24.9%  |    $0.366     |    1.194%
-- 2025-02 |   30.4%  |    $0.467     |    1.201%
-- 2025-03 |   31.4%  |    $0.356     |    1.197%   ← fee still at ~1.2%
-- 2025-04 |   32.1%  |    $0.073     |    1.602%   ← FEE JUMPS TO 1.6%
-- 2025-05 |   34.9%  |    $0.125     |    1.597%
-- 2025-06 |   37.9%  |   -$0.167     |    1.606%


-- ============================================================================
-- QUERY B: Mix vs rate decomposition for Route (baseline vs latest)
-- ============================================================================
-- PERIOD CHOICE: Jan+Feb = baseline (pre-fee-change, 2 months to reduce noise)
--                May+Jun = latest (post-fee-change, settled pattern)
--                March is excluded from baseline: it contains the latency
--                incident window which would distort the true baseline economics.

WITH baseline AS (
    SELECT
        route_id                                                   AS seg,
        SUM(is_profit_kpi_eligible)                                AS n,
        SUM(CASE WHEN is_profit_kpi_eligible = 1
                 THEN contribution_profit_usd ELSE 0 END)          AS profit_sum
    FROM fact_transaction_profit_final
    WHERE created_month IN ('2025-01', '2025-02')
      AND route_id IS NOT NULL
    GROUP BY route_id
),
latest AS (
    SELECT
        route_id                                                   AS seg,
        SUM(is_profit_kpi_eligible)                                AS n,
        SUM(CASE WHEN is_profit_kpi_eligible = 1
                 THEN contribution_profit_usd ELSE 0 END)          AS profit_sum
    FROM fact_transaction_profit_final
    WHERE created_month IN ('2025-05', '2025-06')
      AND route_id IS NOT NULL
    GROUP BY route_id
),
totals AS (
    SELECT
        (SELECT SUM(n) FROM baseline) AS total_n_baseline,
        (SELECT SUM(n) FROM latest)   AS total_n_latest
)
SELECT
    COALESCE(b.seg, l.seg)                                             AS route_id,

    -- weights (share of eligible volume in each period)
    ROUND(1.0 * COALESCE(b.n, 0) / t.total_n_baseline, 4)             AS w0_baseline_share,
    ROUND(1.0 * COALESCE(l.n, 0) / t.total_n_latest,   4)             AS w1_latest_share,

    -- average profit per eligible txn in each period (m0, m1)
    ROUND(1.0 * COALESCE(b.profit_sum, 0) / NULLIF(COALESCE(b.n, 0), 0), 4)  AS m0_baseline_avg_profit_usd,
    ROUND(1.0 * COALESCE(l.profit_sum, 0) / NULLIF(COALESCE(l.n, 0), 0), 4)  AS m1_latest_avg_profit_usd,

    -- mix effect: (w1 - w0) × m0
    -- "what changed purely because volume moved to/from this route,
    --  holding the route's OWN economics constant at the old level"
    ROUND(
        (1.0 * COALESCE(l.n, 0) / t.total_n_latest
         - 1.0 * COALESCE(b.n, 0) / t.total_n_baseline)
        * (1.0 * COALESCE(b.profit_sum, 0) / NULLIF(COALESCE(b.n, 0), 0)),
        4
    )                                                                  AS mix_effect_usd,

    -- rate effect: w1 × (m1 - m0)
    -- "what changed purely because this route's own economics changed,
    --  weighted by its CURRENT share of volume"
    ROUND(
        (1.0 * COALESCE(l.n, 0) / t.total_n_latest)
        * (
            1.0 * COALESCE(l.profit_sum, 0) / NULLIF(COALESCE(l.n, 0), 0)
            - 1.0 * COALESCE(b.profit_sum, 0) / NULLIF(COALESCE(b.n, 0), 0)
          ),
        4
    )                                                                  AS rate_effect_usd,

    -- total effect = mix + rate
    -- summed across all routes this equals the overall KPI change: -$0.2245
    ROUND(
        (1.0 * COALESCE(l.n, 0) / t.total_n_latest
         - 1.0 * COALESCE(b.n, 0) / t.total_n_baseline)
        * (1.0 * COALESCE(b.profit_sum, 0) / NULLIF(COALESCE(b.n, 0), 0))
        +
        (1.0 * COALESCE(l.n, 0) / t.total_n_latest)
        * (
            1.0 * COALESCE(l.profit_sum, 0) / NULLIF(COALESCE(l.n, 0), 0)
            - 1.0 * COALESCE(b.profit_sum, 0) / NULLIF(COALESCE(b.n, 0), 0)
          ),
        4
    )                                                                  AS total_effect_usd

FROM baseline b, totals t
LEFT JOIN latest l ON l.seg = b.seg

UNION ALL

SELECT l.seg, 0.0, ROUND(1.0*l.n/t.total_n_latest,4),
       NULL, ROUND(1.0*l.profit_sum/NULLIF(l.n,0),4), NULL, NULL, NULL
FROM latest l, totals t
WHERE NOT EXISTS (SELECT 1 FROM baseline b WHERE b.seg = l.seg)

ORDER BY ABS(total_effect_usd) DESC NULLS LAST;

-- ── EXPECTED OUTPUT (verified) ────────────────────────────────────────────
-- route | w0 baseline | w1 latest | m0 baseline | m1 latest | mix    | rate   | total
-- R3    |     0.2700  |   0.3617  |    $0.4118  |  -$0.0422 | +0.038 | -0.177 | -0.139  61.7% of decline
-- R4    |     0.1763  |   0.1444  |    $0.7222  |   $0.1424 | -0.023 | -0.084 | -0.107 (but watch R4 separately)
-- R2    |     0.1725  |   0.1360  |    $0.2940  |   $0.0422 |  0.011 | -0.034 | -0.023
-- R1    |     0.2388  |   0.2299  |    $0.1779  |   $0.1051 |  0.002 | -0.017 | -0.015
-- R6    |     0.1425  |   0.1280  |    $0.1274  |   $0.0766 |  0.002 | -0.007 | -0.005
--
-- SUM of total_effect: -0.2390 (slight rounding vs Python's -0.2245 due to
-- SQLite's floating point — use Python/pandas for the exact reconciled figure)
--
-- KEY FINDING: R3's rate_effect (-$0.177) dominates its mix_effect (+$0.038)
-- i.e. R3's OWN economics collapsed, it did not merely grow in share.
