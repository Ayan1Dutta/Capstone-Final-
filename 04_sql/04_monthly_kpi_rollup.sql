-- ============================================================================
-- 04_monthly_kpi_rollup.sql
-- AstraPay Trusted Profitability Model — reusable executive & segment rollups
-- Depends on: 01_staging_views.sql, 02_fact_transaction_economics.sql
-- These are the queries behind profitability_model.md §8 and every table in
-- task5_root_cause_analysis.xlsx. Parameterize created_month or add a WHERE
-- clause to reuse for ad-hoc slices.
-- ============================================================================

-- Executive KPI, monthly (the headline number)
SELECT
    created_month,
    COUNT(*)                                                        AS attempted_transactions,
    SUM(CASE WHEN status='success' THEN 1 ELSE 0 END)               AS successful_transactions,
    ROUND(1.0*SUM(CASE WHEN status='success' THEN 1 ELSE 0 END)/COUNT(*), 4) AS success_rate,
    SUM(is_profit_kpi_eligible)                                     AS profit_kpi_eligible_transactions,
    ROUND(1.0*SUM(CASE WHEN is_profit_kpi_eligible=0 AND status='success' AND amount>0 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN status='success' AND amount>0 THEN 1 ELSE 0 END),0), 4) AS pct_settlement_pending,
    ROUND(SUM(CASE WHEN is_profit_kpi_eligible=1 THEN contribution_profit_usd END)
        / NULLIF(SUM(is_profit_kpi_eligible),0), 4)                 AS contribution_profit_per_successful_txn_usd
FROM fact_transaction_profit_final
GROUP BY created_month
ORDER BY created_month;

-- Generic segment-by-month template. Replace {segment_column} with any of:
-- route_id, channel, merchant_category, merchant_country, customer_segment,
-- merchant_risk_tier, merchant_pricing_plan.
--
-- SELECT
--     created_month,
--     {segment_column} AS segment,
--     SUM(CASE WHEN status='success' THEN 1 ELSE 0 END)                       AS successful_transactions,
--     ROUND(1.0*SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) /
--         (SELECT SUM(CASE WHEN status='success' THEN 1 ELSE 0 END)
--            FROM fact_transaction_profit_final f2
--           WHERE f2.created_month = f.created_month), 4)                    AS share_of_month_successful_volume,
--     SUM(is_profit_kpi_eligible)                                            AS eligible_transactions,
--     ROUND(SUM(CASE WHEN is_profit_kpi_eligible=1 THEN contribution_profit_usd END)
--         / NULLIF(SUM(is_profit_kpi_eligible),0), 4)                        AS avg_contribution_profit_usd,
--     ROUND(SUM(CASE WHEN is_profit_kpi_eligible=1 THEN processing_cost_usd END)
--         / NULLIF(SUM(is_profit_kpi_eligible),0), 4)                        AS avg_processing_cost_usd,
--     ROUND(SUM(CASE WHEN is_profit_kpi_eligible=1 THEN revenue_usd END)
--         / NULLIF(SUM(is_profit_kpi_eligible),0), 4)                        AS avg_revenue_usd
-- FROM fact_transaction_profit_final f
-- WHERE {segment_column} IS NOT NULL
-- GROUP BY created_month, {segment_column}
-- ORDER BY created_month, {segment_column};

-- Mix-vs-rate decomposition, two named periods (baseline vs latest), any segment column.
-- w = the segment's share of KPI-eligible transactions in the period; m = its
-- average contribution_profit_usd in the period.
-- mix_effect  = (w1 - w0) * m0   -- "what changed because volume moved, holding old economics fixed"
-- rate_effect = w1 * (m1 - m0)   -- "what changed because the segment's own economics moved"
-- mix_effect + rate_effect, summed across all segments, reconciles exactly to
-- the total change in the overall weighted-average KPI (verified in Python/pandas
-- against this exact query pattern for route_id, channel, merchant_country,
-- merchant_category and customer_segment — see task5_root_cause_analysis.xlsx).
--
-- WITH baseline AS (
--     SELECT {segment_column} AS seg, SUM(is_profit_kpi_eligible) AS n,
--            SUM(CASE WHEN is_profit_kpi_eligible=1 THEN contribution_profit_usd ELSE 0 END) AS profit_sum
--     FROM fact_transaction_profit_final
--     WHERE created_month IN ('2025-01','2025-02') AND {segment_column} IS NOT NULL
--     GROUP BY {segment_column}
-- ),
-- latest AS (
--     SELECT {segment_column} AS seg, SUM(is_profit_kpi_eligible) AS n,
--            SUM(CASE WHEN is_profit_kpi_eligible=1 THEN contribution_profit_usd ELSE 0 END) AS profit_sum
--     FROM fact_transaction_profit_final
--     WHERE created_month IN ('2025-05','2025-06') AND {segment_column} IS NOT NULL
--     GROUP BY {segment_column}
-- )
-- SELECT
--     COALESCE(b.seg, l.seg) AS segment,
--     1.0*b.n / SUM(b.n) OVER () AS w0, 1.0*l.n / SUM(l.n) OVER () AS w1,
--     1.0*b.profit_sum/b.n AS m0, 1.0*l.profit_sum/l.n AS m1
-- FROM baseline b FULL OUTER JOIN latest l ON b.seg = l.seg;
-- (SQLite lacks FULL OUTER JOIN natively; the decomposition in this project
--  was computed in pandas for portability — see the Methodology tab of
--  task5_root_cause_analysis.xlsx for the exact equivalent logic.)
