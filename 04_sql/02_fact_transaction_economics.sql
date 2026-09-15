-- ============================================================================
-- 02_fact_transaction_economics.sql
-- AstraPay Trusted Profitability Model — Layer 2: Fact table + Layer 3: Metrics
--
-- Depends on: 01_staging_views.sql
--
-- NOTE: "transaction" is a reserved word in standard SQL (and in SQLite,
-- which backs this validation run) — every reference to the transaction.csv
-- table is written as the quoted identifier "transaction" for that reason.
-- A production warehouse would more commonly rename the table itself
-- (e.g. transactions) rather than quote it everywhere; either is fine as
-- long as it's applied consistently.
--
-- fact_transaction_attributes  — grain: 1 row per transaction_id (= 1 row per
--   row of transaction.csv; LEFT JOINs to staging views never change this
--   because every staging view is already deduplicated to <=1 row/transaction_id).
--
-- fact_transaction_profit      — same grain, adds the computed USD measures.
--   Kept as a separate view so the join logic (Layer 2) and the money math
--   (Layer 3) can be audited independently.
-- ============================================================================

DROP VIEW IF EXISTS fact_transaction_attributes;
CREATE VIEW fact_transaction_attributes AS
SELECT
    t.transaction_id,
    t.created_at,
    substr(t.created_at, 1, 7)                         AS created_month,      -- 'YYYY-MM', activity-date basis (Data Contract: KPI Date Logic)
    date(t.created_at)                                  AS created_date,
    t.customer_id,
    c.segment                                           AS customer_segment,
    c.country                                           AS customer_country,
    CASE WHEN t.merchant_id = '' THEN NULL ELSE t.merchant_id END AS merchant_id,
    CASE WHEN t.merchant_id = '' THEN 1 ELSE 0 END      AS flag_missing_merchant,   -- DQ D01
    m.category                                          AS merchant_category,
    m.country                                           AS merchant_country,
    m.pricing_plan                                      AS merchant_pricing_plan,
    m.risk_tier                                         AS merchant_risk_tier,
    t.channel,
    t.route_id,
    t.status,
    t.currency,
    t.amount,
    CASE WHEN t.status = 'success' AND t.amount = 0 THEN 1 ELSE 0 END AS flag_zero_amount_glitch,  -- DQ D03b
    CASE WHEN t.status = 'reversed' THEN 1 ELSE 0 END   AS flag_reversed,

    -- fraud (pre-aggregated, cannot fan out — see stg_fraud_agg)
    COALESCE(fd.fraud_rule_count, 0)                    AS fraud_rule_count,
    COALESCE(fd.has_decline, 0)                         AS fraud_has_decline,
    COALESCE(fd.has_review, 0)                          AS fraud_has_review,
    fd.avg_valid_risk_score,
    COALESCE(fd.has_oor_score, 0)                       AS fraud_has_oor_score,
    CASE WHEN t.status = 'success' AND COALESCE(fd.has_decline,0) = 1 THEN 1 ELSE 0 END AS flag_success_with_decline, -- DQ D11

    -- settlement (pre-aggregated, cannot fan out — see stg_settlement_agg)
    se.settlement_leg_count,
    se.settlement_currency,
    se.settlement_date_first                            AS settlement_date,
    se.settlement_amount_sum,
    se.fee_amount_sum,
    CASE WHEN t.status = 'success' AND t.amount > 0 AND se.transaction_id IS NULL THEN 1 ELSE 0 END AS flag_settlement_pending, -- DQ D16

    -- chargeback (pre-aggregated)
    COALESCE(cb.chargeback_amount_sum, 0)               AS chargeback_amount_local,
    COALESCE(cb.chargeback_count, 0)                    AS chargeback_count,
    cb.first_opened_at                                  AS chargeback_opened_at,

    -- FX lookups: each keyed explicitly by (currency, date, rate_type) — never an implicit/unspecified rate_type
    fx_created.rate_to_usd    AS fx_interbank_at_created,   -- for attempted GPV & the variable-cost component (Data Contract: KPI Date Logic)
    fx_settle.rate_to_usd     AS fx_settlement_at_settle_date, -- for realized revenue (Data Contract: KPI Date Logic)
    fx_cb.rate_to_usd         AS fx_settlement_at_cb_open,     -- retained for audit/local-currency reference only; NOT used in the revised flat-fee chargeback cost (see fact_transaction_profit)

    -- route cost, looked up on created_at's calendar date (never settlement_date — Data Contract: KPI Date Logic, avoids mis-costing around the 1-Apr-2025 R3 step change)
    rc.fixed_fee              AS route_fixed_fee_usd,
    rc.variable_fee_pct       AS route_variable_fee_pct

FROM "transaction" t
LEFT JOIN customer c              ON c.customer_id = t.customer_id
LEFT JOIN merchant m              ON m.merchant_id = t.merchant_id AND t.merchant_id <> ''
LEFT JOIN stg_fraud_agg fd        ON fd.transaction_id = t.transaction_id
LEFT JOIN stg_settlement_agg se   ON se.transaction_id = t.transaction_id
LEFT JOIN stg_chargeback_agg cb   ON cb.transaction_id = t.transaction_id
LEFT JOIN fx_rate fx_created      ON fx_created.currency = t.currency
                                  AND fx_created.rate_date = date(t.created_at)
                                  AND fx_created.rate_type = 'interbank'
LEFT JOIN fx_rate fx_settle       ON fx_settle.currency = se.settlement_currency
                                  AND fx_settle.rate_date = se.settlement_date_first
                                  AND fx_settle.rate_type = 'settlement'
LEFT JOIN fx_rate fx_cb           ON fx_cb.currency = t.currency
                                  AND fx_cb.rate_date = date(cb.first_opened_at)
                                  AND fx_cb.rate_type = 'settlement'
LEFT JOIN route_cost rc           ON rc.route_id = t.route_id
                                  AND rc.cost_date = date(t.created_at);

-- ============================================================================
-- fact_transaction_profit — adds the USD money math on top of the attributes
-- ============================================================================
DROP VIEW IF EXISTS fact_transaction_profit;
CREATE VIEW fact_transaction_profit AS
SELECT
    a.*,

    -- Attempted value in USD (indicative — same-day interbank rate), used for GPV / volume-side KPIs only
    ROUND(a.amount * a.fx_interbank_at_created, 4) AS amount_usd_attempted,

    -- Realized merchant-fee revenue in USD. NULL (not zero) when settlement hasn't happened yet.
    CASE
        WHEN a.settlement_currency IS NULL THEN NULL
        WHEN a.settlement_currency = 'USD' THEN a.fee_amount_sum
        ELSE ROUND(a.fee_amount_sum * a.fx_settlement_at_settle_date, 4)
    END AS revenue_usd,

    -- Route processing cost in USD. Defined only for successful, real-amount transactions
    -- (the population the executive KPI is about); fixed_fee is already USD, variable
    -- component uses the interbank rate at created_at (cost is incurred pre-settlement).
    CASE
        WHEN a.status = 'success' AND a.amount > 0 AND a.route_fixed_fee_usd IS NOT NULL
        THEN ROUND(a.route_fixed_fee_usd + a.route_variable_fee_pct * (a.amount * a.fx_interbank_at_created), 4)
        ELSE NULL
    END AS processing_cost_usd,

    -- Chargeback cost in USD — REVISED ASSUMPTION (see profitability_model.md,
    -- "Assumption revised during modelling"): a flat $10 USD dispute-handling
    -- fee per chargeback case, NOT the disputed principal amount. Standard
    -- card-scheme practice claws the disputed principal back from the
    -- MERCHANT's own settlement (merchant liability), not from the
    -- processor's revenue; modelling the full principal as AstraPay's cost
    -- was tried first and produced a structurally impossible result (deeply
    -- negative contribution profit in every month, driven by a handful of
    -- large disputes) — flagged here rather than silently forced positive.
    -- This is a placeholder assumption to validate with Finance/Risk, not a
    -- measured figure.
    a.chargeback_count * 10.0 AS chargeback_cost_usd,

    -- Is this transaction usable for the REALIZED contribution-profit KPI this period?
    -- Excludes: non-successful, the 35 zero-amount glitches, and settlement-pending rows
    -- (DQ report D03b, D16) — none of these are silently coerced to zero.
    CASE
        WHEN a.status = 'success' AND a.amount > 0 AND a.settlement_currency IS NOT NULL
        THEN 1 ELSE 0
    END AS is_profit_kpi_eligible

FROM fact_transaction_attributes a;

-- Final derived column (contribution_profit_usd) needs the CASE outputs above as inputs,
-- so it is expressed as one more layer to keep each view single-purpose and auditable.
DROP VIEW IF EXISTS fact_transaction_profit_final;
CREATE VIEW fact_transaction_profit_final AS
SELECT
    p.*,
    CASE
        WHEN p.is_profit_kpi_eligible = 1
        THEN ROUND(p.revenue_usd - p.processing_cost_usd - p.chargeback_cost_usd, 4)
        ELSE NULL
    END AS contribution_profit_usd
FROM fact_transaction_profit p;
