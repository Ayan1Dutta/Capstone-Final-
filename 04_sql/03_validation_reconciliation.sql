-- ============================================================================
-- 03_validation_reconciliation.sql
-- AstraPay Trusted Profitability Model — validation & reconciliation queries
-- Depends on: 01_staging_views.sql, 02_fact_transaction_economics.sql
-- Every query below was executed against the real dataset; results are
-- reproduced in profitability_model.md and task5_root_cause_analysis.xlsx.
-- ============================================================================

-- CHECK 1 — Grain proof: each staging view has <= 1 row per transaction_id
-- (i.e. the fan-out risk documented in the DQ report cannot reach the fact table)
SELECT 'stg_fraud_agg' AS view_name, COUNT(*) AS n_rows, COUNT(DISTINCT transaction_id) AS n_distinct_txn
FROM stg_fraud_agg
UNION ALL
SELECT 'stg_settlement_agg', COUNT(*), COUNT(DISTINCT transaction_id) FROM stg_settlement_agg
UNION ALL
SELECT 'stg_chargeback_agg', COUNT(*), COUNT(DISTINCT transaction_id) FROM stg_chargeback_agg;
-- Expect n_rows = n_distinct_txn in all three rows. Confirms the "no fan-out" property.

-- CHECK 2 — fact_transaction_attributes must have exactly one row per transaction.csv row
SELECT
    (SELECT COUNT(*) FROM "transaction")                    AS raw_transaction_rows,
    (SELECT COUNT(*) FROM fact_transaction_attributes)    AS fact_rows,
    (SELECT COUNT(DISTINCT transaction_id) FROM fact_transaction_attributes) AS fact_distinct_txn;
-- Expect all three numbers identical (8,000). Proves the LEFT JOINs to staging
-- views did not fan the fact table out, unlike a naive join straight to
-- fraud_decision/settlement would.

-- CHECK 3 — Formal fan-out PROOF: naive join vs. the corrected (staged) join,
-- reproducing and quantifying DQ report finding D10/D18
SELECT
    'naive: transaction JOIN fraud_decision (raw)' AS method,
    COUNT(*) AS row_count,
    ROUND(SUM(CASE WHEN t.currency='INR' THEN t.amount END), 2) AS inr_amount_sum_DISTORTED
FROM "transaction" t JOIN fraud_decision fd ON fd.transaction_id = t.transaction_id
UNION ALL
SELECT
    'corrected: transaction JOIN stg_fraud_agg (pre-aggregated)',
    COUNT(*),
    ROUND(SUM(CASE WHEN t.currency='INR' THEN t.amount END), 2)
FROM "transaction" t JOIN stg_fraud_agg fd ON fd.transaction_id = t.transaction_id
UNION ALL
SELECT
    'baseline: transaction alone',
    COUNT(*),
    ROUND(SUM(CASE WHEN currency='INR' THEN amount END), 2)
FROM "transaction";
-- Expect: naive row_count = 11,953 and INR sum inflated to ~8.01M; corrected
-- and baseline both = 8,000 rows and ~5.35M INR. This is the required proof
-- that a 1:many join, once pre-aggregated, does not inflate payment amount.

-- CHECK 4 — Settlement currency is constant within a transaction (justifies
-- SUM(settlement_amount)/SUM(fee_amount) in stg_settlement_agg without a
-- mixed-currency error)
SELECT COUNT(*) AS transactions_with_mixed_settlement_currency
FROM (
    SELECT transaction_id, COUNT(DISTINCT settlement_currency) AS n_ccy
    FROM settlement
    GROUP BY transaction_id
    HAVING n_ccy > 1
);
-- Expect 0.

-- CHECK 5 — Transaction-side vs settlement-side reconciliation (funnel)
SELECT
    (SELECT COUNT(*) FROM "transaction" WHERE status='success')                                   AS successful_transactions,
    (SELECT COUNT(*) FROM "transaction" WHERE status='success' AND amount=0)                       AS zero_amount_glitch,
    (SELECT COUNT(*) FROM "transaction" WHERE status='success' AND amount>0)                        AS successful_real_amount,
    (SELECT COUNT(*) FROM "transaction" t WHERE t.status='success' AND t.amount>0
        AND EXISTS (SELECT 1 FROM stg_settlement_agg se WHERE se.transaction_id=t.transaction_id)) AS covered_by_settlement,
    (SELECT COUNT(*) FROM "transaction" t WHERE t.status='success' AND t.amount>0
        AND NOT EXISTS (SELECT 1 FROM stg_settlement_agg se WHERE se.transaction_id=t.transaction_id)) AS settlement_pending,
    (SELECT COUNT(*) FROM settlement s WHERE NOT EXISTS
        (SELECT 1 FROM "transaction" t WHERE t.transaction_id = s.transaction_id))                  AS orphan_settlement_rows;

-- CHECK 6 — FX / route_cost lookup coverage: any successful, real-amount
-- transaction should resolve every FX/route lookup it needs. A NULL here
-- would mean a broken join, not a business-real "missing" value.
SELECT
    SUM(CASE WHEN fx_interbank_at_created IS NULL THEN 1 ELSE 0 END)               AS missing_fx_interbank_created,
    SUM(CASE WHEN status='success' AND amount>0 AND route_fixed_fee_usd IS NULL THEN 1 ELSE 0 END) AS missing_route_cost_lookup,
    SUM(CASE WHEN settlement_currency IS NOT NULL AND settlement_currency<>'USD'
             AND fx_settlement_at_settle_date IS NULL THEN 1 ELSE 0 END)           AS missing_fx_settlement_lookup
FROM fact_transaction_attributes;
-- Expect all three = 0.

-- CHECK 7 — Executive KPI, monthly, on the trusted model
SELECT
    created_month,
    COUNT(*)                                                     AS attempted_transactions,
    SUM(CASE WHEN status='success' THEN 1 ELSE 0 END)            AS successful_transactions,
    ROUND(1.0*SUM(CASE WHEN status='success' THEN 1 ELSE 0 END)/COUNT(*), 4) AS success_rate,
    SUM(is_profit_kpi_eligible)                                  AS profit_kpi_eligible_transactions,
    ROUND(1.0*SUM(CASE WHEN is_profit_kpi_eligible=0 AND status='success' AND amount>0 THEN 1 ELSE 0 END)
          / NULLIF(SUM(CASE WHEN status='success' AND amount>0 THEN 1 ELSE 0 END),0), 4) AS pct_settlement_pending,
    ROUND(SUM(CASE WHEN is_profit_kpi_eligible=1 THEN contribution_profit_usd END)
          / NULLIF(SUM(is_profit_kpi_eligible),0), 4)            AS contribution_profit_per_successful_txn_usd
FROM fact_transaction_profit_final
GROUP BY created_month
ORDER BY created_month;
