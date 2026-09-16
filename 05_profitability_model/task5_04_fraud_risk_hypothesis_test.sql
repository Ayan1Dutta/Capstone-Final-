-- ============================================================================
-- task5_04_fraud_risk_hypothesis_test.sql
-- AstraPay Root-Cause Investigation — Task 5
-- Query 4: Testing the Risk Head's hypothesis (H3)
--
-- GRAIN OUTPUT : Query A → 1 row per (merchant_risk_tier, created_month)
--                Query B → 1 row per created_month (decline rate comparison)
--                Query C → 1 row per (model_version, created_month)
-- DEPENDS ON   : 01_staging_views.sql, 02_fact_transaction_economics.sql
--
-- HYPOTHESIS BEING TESTED (H3)
-- "Tighter fraud controls are causing false declines that suppress
--  contribution profit per successful transaction."
--
-- VERDICT: CONFIRMED for the volume metric, DISPROVED for the profit KPI.
-- This script produces the evidence for both halves of that finding.
--
-- HOW TO PRESENT THIS TO AN EXECUTIVE
-- "The Risk Head is right that decline rates doubled for High-risk merchants
--  from April onward. But when we look at the transactions that DID succeed
--  on those same merchants, their per-transaction profit is no worse than
--  any other tier. The fraud model changed who gets through, not the
--  economics of the transactions that succeed. This is a volume problem,
--  not a profitability problem — and they need separate fixes."
-- ============================================================================


-- ── QUERY A: Risk tier performance — success rate vs profit per txn ────────
-- The key question: does tighter fraud screening make each successful
-- transaction LESS profitable? This query answers it directly.
-- Look at avg_contribution_profit_usd across tiers over time — if H3
-- were correct, High-risk tier profit should fall RELATIVE to Low/Medium.

SELECT
    created_month,
    merchant_risk_tier,

    -- total attempts for this tier this month
    COUNT(*)                                                           AS attempted_txns,

    -- successful transactions
    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)               AS successful_txns,

    -- success rate — THIS is what the fraud controls affect
    ROUND(
        1.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)
            / COUNT(*),
        4
    )                                                                  AS success_rate,

    -- failed transactions (declined or blocked)
    SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END)                AS failed_txns,

    SUM(is_profit_kpi_eligible)                                        AS eligible_txns,

    -- profit per successful txn — THIS is the executive KPI
    -- if H3 were correct, this should be worse for High-risk tier
    -- RESULT: it is NOT. High-risk profit trend is similar to Low/Medium.
    ROUND(
        SUM(CASE WHEN is_profit_kpi_eligible = 1 THEN contribution_profit_usd END)
            / NULLIF(SUM(is_profit_kpi_eligible), 0),
        4
    )                                                                  AS avg_contribution_profit_usd

FROM fact_transaction_profit_final
WHERE merchant_risk_tier IS NOT NULL
GROUP BY created_month, merchant_risk_tier
ORDER BY merchant_risk_tier, created_month;

-- ── EXPECTED KEY VALUES ───────────────────────────────────────────────────
-- merchant_risk_tier | month   | success_rate | avg_profit_usd
-- High               | 2025-01 |   91.75%     |   $0.334
-- High               | 2025-05 |   83.65%     |   $0.173    ← success rate FELL
-- High               | 2025-06 |   85.21%     |   $0.229
-- Low                | 2025-01 |   86.15%     |   $0.303
-- Low                | 2025-06 |   88.06%     |   -$0.040   ← profit FELL MORE for Low
--
-- INTERPRETATION: High-risk success rate dropped (8.25%→16.35% decline rate)
-- but the LOW-RISK tier's PROFIT fell more steeply. This disproves the idea
-- that fraud tightening is hurting per-transaction profitability.


-- ── QUERY B: Decline rate comparison — High risk vs all others ─────────────
-- This is the CONFIRMATION side: yes, fraud controls are working.
-- The High-risk decline rate doubled from May onward.
-- Other tiers stayed flat. This is real, targeted, and effective — just
-- the wrong explanation for the PROFITABILITY decline.

SELECT
    created_month,

    -- High-risk tier
    SUM(CASE WHEN merchant_risk_tier = 'High' THEN 1 ELSE 0 END)      AS high_risk_attempts,
    SUM(CASE WHEN merchant_risk_tier = 'High' AND status = 'failed'
             THEN 1 ELSE 0 END)                                        AS high_risk_failed,
    ROUND(
        1.0 * SUM(CASE WHEN merchant_risk_tier = 'High' AND status = 'failed' THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN merchant_risk_tier = 'High' THEN 1 ELSE 0 END), 0),
        4
    )                                                                  AS high_risk_decline_rate,

    -- Medium + Low tiers combined
    SUM(CASE WHEN merchant_risk_tier != 'High' THEN 1 ELSE 0 END)     AS other_tier_attempts,
    ROUND(
        1.0 * SUM(CASE WHEN merchant_risk_tier != 'High' AND status = 'failed' THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN merchant_risk_tier != 'High' THEN 1 ELSE 0 END), 0),
        4
    )                                                                  AS other_tier_decline_rate,

    -- ratio: how much worse is High-risk compared to others this month?
    ROUND(
        (1.0 * SUM(CASE WHEN merchant_risk_tier = 'High' AND status = 'failed' THEN 1 ELSE 0 END)
             / NULLIF(SUM(CASE WHEN merchant_risk_tier = 'High' THEN 1 ELSE 0 END), 0))
        /
        NULLIF(
            1.0 * SUM(CASE WHEN merchant_risk_tier != 'High' AND status = 'failed' THEN 1 ELSE 0 END)
                / NULLIF(SUM(CASE WHEN merchant_risk_tier != 'High' THEN 1 ELSE 0 END), 0),
            0
        ),
        2
    )                                                                  AS high_vs_other_decline_ratio

FROM fact_transaction_profit_final
WHERE merchant_risk_tier IS NOT NULL
GROUP BY created_month
ORDER BY created_month;

-- ── EXPECTED OUTPUT ───────────────────────────────────────────────────────
-- month   | high_decline | other_decline | ratio
-- 2025-01 |    8.25%     |     7.91%     |  1.04x  ← essentially same
-- 2025-02 |    9.45%     |     7.52%     |  1.26x
-- 2025-03 |    9.24%     |     8.56%     |  1.08x
-- 2025-04 |    8.40%     |     7.30%     |  1.15x
-- 2025-05 |   16.35%     |     8.42%     |  1.94x  ← DOUBLES — beta model rollout
-- 2025-06 |   14.79%     |     7.12%     |  2.08x  ← still double
--
-- PRESENTATION POINT: the ratio jumps from ~1.0-1.3x to ~2.0x from May.
-- May is exactly when fraud_v4.0-beta became the dominant model for
-- High-risk merchants (from fraud_decision.csv model_version analysis).


-- ── QUERY C: Fraud model version activity over time ────────────────────────
-- Shows when the beta model was introduced and how prevalent it became.
-- Supports the narrative: the model rollout timing explains the May jump.

SELECT
    SUBSTR(t.created_at, 1, 7)                                        AS created_month,
    fd.model_version,
    COUNT(DISTINCT fd.transaction_id)                                  AS transactions_evaluated,
    SUM(CASE WHEN fd.decision = 'Decline' THEN 1 ELSE 0 END)          AS declines,
    ROUND(
        1.0 * SUM(CASE WHEN fd.decision = 'Decline' THEN 1 ELSE 0 END)
            / COUNT(DISTINCT fd.transaction_id),
        4
    )                                                                  AS decline_rate_by_model,
    -- out-of-range scores: only beta model produces these (DQ report D04)
    SUM(CASE WHEN fd.risk_score < 0 OR fd.risk_score > 1 THEN 1 ELSE 0 END)
                                                                       AS oor_score_count

FROM fraud_decision fd
JOIN "transaction" t ON t.transaction_id = fd.transaction_id
GROUP BY SUBSTR(t.created_at, 1, 7), fd.model_version
ORDER BY created_month, model_version;
