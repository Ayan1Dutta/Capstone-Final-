-- ============================================================================
-- task5_03_segment_analysis.sql
-- AstraPay Root-Cause Investigation — Task 5
-- Query 3: Segment-level analysis across 4 dimensions
--
-- GRAIN OUTPUT : 1 row per (segment_value, created_month) for each dimension
-- DEPENDS ON   : 01_staging_views.sql, 02_fact_transaction_economics.sql
--
-- PURPOSE
-- Repeats the same profitability analysis across four different slicing
-- dimensions: channel, merchant category, merchant country, customer segment.
-- Every query uses the same CTE pattern so results can be compared
-- consistently and the KPI formula is never accidentally changed between cuts.
--
-- IMPORTANT NOTE ON MERCHANT ATTRIBUTES (category, country, pricing_plan):
-- 2.60% of transactions have a blank merchant_id (DQ report D01).
-- These rows have NULL values for all merchant-derived attributes.
-- The WHERE clause excludes them from the relevant queries so shares add
-- to 100% over the non-null population.
-- ============================================================================


-- ============================================================
-- SECTION 1: Channel × Month
-- ============================================================
-- Wallet channel grew from 14.3% share (Jan+Feb avg) to 21.3% (May+Jun avg)
-- No single channel explains the decline as clearly as route does — channel
-- is a correlate of routing, not an independent cause.

SELECT
    created_month,
    channel                                                            AS segment,

    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)               AS successful_txns,

    -- share of month's successful volume going through this channel
    ROUND(
        1.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
            / (SELECT SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
               FROM fact_transaction_profit_final f2
               WHERE f2.created_month = f.created_month),
        4
    )                                                                  AS pct_of_month_volume,

    SUM(is_profit_kpi_eligible)                                        AS eligible_txns,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN contribution_profit_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_contribution_profit_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN processing_cost_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_processing_cost_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN revenue_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_revenue_usd

FROM fact_transaction_profit_final f
WHERE channel IS NOT NULL
GROUP BY created_month, channel
ORDER BY created_month, channel;


-- ============================================================
-- SECTION 2: Merchant Category × Month
-- ============================================================
-- Electronics explains 42.9% of the merchant-attributable decline.
-- Digital Goods shows the steepest chargeback-driven deterioration.
-- Both are independent of the routing story — they are the SECOND driver.

SELECT
    created_month,
    merchant_category                                                  AS segment,

    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)               AS successful_txns,

    ROUND(
        1.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
            / (SELECT SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
               FROM fact_transaction_profit_final f2
               WHERE f2.created_month = f.created_month
                 AND f2.merchant_category IS NOT NULL),
        4
    )                                                                  AS pct_of_month_volume,

    SUM(is_profit_kpi_eligible)                                        AS eligible_txns,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN contribution_profit_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_contribution_profit_usd,

    -- chargeback rate: chargebacks filed per successful transaction
    -- ATTRIBUTED TO created_month of the originating transaction
    -- (not the month the dispute was opened — see Data Contract KPI Date Logic)
    ROUND(
        1.0 * SUM(chargeback_count)
            / NULLIF(SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END), 0),
        4
    )                                                                  AS chargeback_rate,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN processing_cost_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_processing_cost_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN revenue_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_revenue_usd

FROM fact_transaction_profit_final f
WHERE merchant_category IS NOT NULL
GROUP BY created_month, merchant_category
ORDER BY created_month, merchant_category;

-- ── KEY VALUES TO HIGHLIGHT ───────────────────────────────────────────────
-- Electronics chargeback_rate: 2025-01 = 1.37%  →  2025-06 = 6.46%  (+372%)
-- Digital Goods chargeback_rate: 2025-01 = 1.95% → 2025-06 = 7.34%  (+276%)
-- All other categories: flat at ~2.5-3.5% throughout


-- ============================================================
-- SECTION 3: Merchant Country × Month
-- ============================================================
-- UAE has the best baseline economics ($0.72 avg profit in Jan+Feb)
-- yet shows the steepest absolute decline — because UAE volume is
-- disproportionately routed through R3 (PayGlobal cross-border).
-- This shows how routing is THE common underlying cause across countries.

SELECT
    created_month,
    merchant_country                                                   AS segment,

    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)               AS successful_txns,

    ROUND(
        1.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
            / (SELECT SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
               FROM fact_transaction_profit_final f2
               WHERE f2.created_month = f.created_month
                 AND f2.merchant_country IS NOT NULL),
        4
    )                                                                  AS pct_of_month_volume,

    SUM(is_profit_kpi_eligible)                                        AS eligible_txns,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN contribution_profit_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_contribution_profit_usd,

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

    -- R3 share within this country, this month
    -- rising share = the routing mix shift is happening inside every country
    ROUND(
        1.0 * SUM(CASE WHEN route_id = 'R3' AND status = 'success' THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END), 0),
        4
    )                                                                  AS r3_share_within_country

FROM fact_transaction_profit_final f
WHERE merchant_country IS NOT NULL
GROUP BY created_month, merchant_country
ORDER BY created_month, merchant_country;


-- ============================================================
-- SECTION 4: Customer Segment × Month
-- ============================================================
-- Retail (52%) and SME (43%) explain almost all of the customer-segment
-- decline. Enterprise is comparatively insulated. This is expected —
-- Enterprise merchants tend to use lower-fee routes and pricing plans.

SELECT
    created_month,
    customer_segment                                                   AS segment,

    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)               AS successful_txns,

    ROUND(
        1.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
            / (SELECT SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
               FROM fact_transaction_profit_final f2
               WHERE f2.created_month = f.created_month
                 AND f2.customer_segment IS NOT NULL),
        4
    )                                                                  AS pct_of_month_volume,

    SUM(is_profit_kpi_eligible)                                        AS eligible_txns,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN contribution_profit_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_contribution_profit_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN processing_cost_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_processing_cost_usd,

    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN revenue_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_revenue_usd

FROM fact_transaction_profit_final f
WHERE customer_segment IS NOT NULL
GROUP BY created_month, customer_segment
ORDER BY created_month, customer_segment;
