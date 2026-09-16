-- ============================================================================
-- task5_01_executive_kpi_monthly.sql
-- AstraPay Root-Cause Investigation — Task 5
-- Query 1: Executive KPI monthly trend (the headline)
--
-- GRAIN OUTPUT : 1 row per calendar month (6 rows for Jan-Jun 2025)
-- DEPENDS ON   : 01_staging_views.sql, 02_fact_transaction_economics.sql
-- VERIFIED     : Ran against astrapay.db (SQLite); portable to any ANSI-SQL
--                warehouse — replace substr() with DATE_TRUNC or FORMAT_DATE
--
-- PURPOSE
-- This is the starting point for the entire root-cause investigation.
-- It quantifies the executive KPI — contribution profit per successful
-- transaction — month by month, and surfaces the core paradox:
-- volume grew 62% while profit per transaction fell ~85%.
--
-- KEY DESIGN DECISIONS
-- 1. success_rate    = DIVIDE(count of successes, count of ALL attempts)
--                      NOT AVERAGE of any pre-computed ratio column.
--                      Averaging per-row ratios would weight Jan (1,000 rows)
--                      the same as Jun (1,621 rows) — wrong for a trend.
-- 2. contribution_profit_per_txn = SUM(profit) / SUM(eligible_flag)
--                      The denominator is the sum of is_profit_kpi_eligible,
--                      which equals the count of rows where the flag = 1.
--                      Using COUNT(*) would divide by ALL 8,000 rows and
--                      produce a meaninglessly diluted number.
-- 3. pct_settlement_pending is shown alongside the KPI so the reader knows
--                      how much of that month's eligible population was
--                      actually measured vs still-in-transit.
-- ============================================================================

SELECT
    created_month,

    -- ── Volume funnel ──────────────────────────────────────────────────
    COUNT(*)                                                           AS attempted_transactions,

    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)               AS successful_transactions,

    -- success_rate: additive counts in numerator and denominator — safe
    ROUND(
        1.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
            / COUNT(*),
        4
    )                                                                  AS success_rate,

    -- ── KPI population ─────────────────────────────────────────────────
    -- is_profit_kpi_eligible = 1 only when:
    --   status='success' AND amount>0 AND a settlement row exists
    -- (see 02_fact_transaction_economics.sql for the full definition)
    SUM(is_profit_kpi_eligible)                                        AS profit_kpi_eligible_transactions,

    -- proportion of real successful transactions still awaiting settlement
    -- if this grows, the KPI denominator shrinks — track separately
    ROUND(
        1.0 * SUM(
            CASE WHEN is_profit_kpi_eligible = 0
                  AND status = 'success'
                  AND amount > 0
            THEN 1 ELSE 0 END
        ) / NULLIF(
            SUM(CASE WHEN status = 'success' AND amount > 0 THEN 1 ELSE 0 END),
            0
        ),
        4
    )                                                                  AS pct_settlement_pending,

    -- ── The executive KPI ──────────────────────────────────────────────
    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN contribution_profit_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS contribution_profit_per_successful_txn_usd,

    -- ── Economic components (for decomposition) ────────────────────────
    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN revenue_usd END),
        2
    )                                                                  AS total_revenue_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN processing_cost_usd END),
        2
    )                                                                  AS total_processing_cost_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN chargeback_cost_usd END),
        2
    )                                                                  AS total_chargeback_cost_usd,

    -- average revenue and cost per eligible transaction
    -- useful for spotting whether revenue, cost, or both are moving
    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN revenue_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_revenue_per_eligible_txn_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN processing_cost_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_processing_cost_per_eligible_txn_usd

FROM fact_transaction_profit_final
GROUP BY created_month
ORDER BY created_month;

-- ── EXPECTED OUTPUT (verified against astrapay.db) ────────────────────
-- created_month | attempted | successful | success_rate | eligible | kpi_usd
-- 2025-01       |     1,000 |        868 |       0.8680 |      841 |  $0.2899
-- 2025-02       |     1,172 |      1,038 |       0.8857 |      992 |  $0.3480  ← peak
-- 2025-03       |     1,263 |      1,097 |       0.8686 |    1,047 |  $0.2712
-- 2025-04       |     1,338 |      1,198 |       0.8954 |    1,159 |  $0.0962  ← R3 fee step change
-- 2025-05       |     1,606 |      1,411 |       0.8786 |    1,362 |  $0.1518
-- 2025-06       |     1,621 |      1,428 |       0.8809 |    1,372 |  $0.0422  ← latest
--
-- Observation: Volume grew 62% (1,000→1,621 attempts). KPI fell 85%
-- ($0.290→$0.042). The two move in opposite directions — this is the
-- central paradox the rest of Task 5 explains.
