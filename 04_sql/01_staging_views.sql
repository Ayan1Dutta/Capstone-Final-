-- ============================================================================
-- 01_staging_views.sql
-- AstraPay Trusted Profitability Model — Layer 1: Staging
--
-- Purpose: every table that has a 1:many relationship to transaction.csv is
-- collapsed to exactly one row per transaction_id HERE, before it is allowed
-- anywhere near a join to transaction. This is the structural fix for the
-- join fan-out problem documented in the DQ report (D09, D10, D18): if a
-- downstream query only ever joins to these staging views (never to the raw
-- fraud_decision / settlement tables), transaction.amount cannot be inflated,
-- because each staging view guarantees <= 1 row per transaction_id.
--
-- Dialect: SQLite (validated against the actual dataset). Portable to any
-- ANSI-SQL engine (Snowflake/BigQuery/Postgres) with GROUP BY semantics
-- unchanged; only date functions (date(), substr()) would need swapping.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- stg_fraud_agg
-- Grain: 1 row per transaction_id (down from 1 row per rule evaluation).
-- Collapses fraud_decision's avg 1.49 rows/transaction (max 3) into a single
-- row so a later join can never fan out transaction.amount.
-- risk_score values outside the documented [0,1] range (22 rows, all on
-- model_version = fraud_v4.0-beta per the DQ report, D04) are EXCLUDED from
-- avg_valid_risk_score rather than repaired — there is no way to infer the
-- intended value, so they are quarantined from any score-based average and
-- surfaced instead via has_oor_score for downstream flagging.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS stg_fraud_agg;
CREATE VIEW stg_fraud_agg AS
SELECT
    transaction_id,
    COUNT(*)                                                        AS fraud_rule_count,
    MAX(CASE WHEN decision = 'Decline' THEN 1 ELSE 0 END)           AS has_decline,
    MAX(CASE WHEN decision = 'Review'  THEN 1 ELSE 0 END)           AS has_review,
    AVG(CASE WHEN risk_score BETWEEN 0 AND 1 THEN risk_score END)   AS avg_valid_risk_score,
    MAX(CASE WHEN risk_score < 0 OR risk_score > 1 THEN 1 ELSE 0 END) AS has_oor_score
FROM fraud_decision
GROUP BY transaction_id;

-- ---------------------------------------------------------------------------
-- stg_settlement_agg
-- Grain: 1 row per transaction_id (down from 1 row per settlement leg).
-- Collapses the 352 two-leg transactions (DQ report D09) via SUM, which is
-- safe here because generation/business rule guarantees a single
-- transaction's legs always share one settlement_currency (verified: no
-- mixed-currency transaction exists in this dataset — see
-- 03_validation_reconciliation.sql, check #5). Orphan settlement rows (71,
-- D17: no matching transaction_id) are automatically excluded because this
-- view is built FROM settlement and will simply produce a row that later
-- LEFT-JOINs to nothing in transaction — they never reach the fact table.
-- transaction_ids with ZERO settlement rows (232 successful, real-amount
-- transactions, D16) correctly produce NO row here at all; the fact table
-- must LEFT JOIN and treat the resulting NULLs as "settlement pending", not
-- as zero.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS stg_settlement_agg;
CREATE VIEW stg_settlement_agg AS
SELECT
    transaction_id,
    COUNT(*)                    AS settlement_leg_count,
    SUM(settlement_amount)      AS settlement_amount_sum,
    SUM(fee_amount)             AS fee_amount_sum,
    MIN(settlement_currency)    AS settlement_currency,   -- constant per txn; MIN just selects it
    MIN(settlement_date)        AS settlement_date_first
FROM settlement
GROUP BY transaction_id;

-- ---------------------------------------------------------------------------
-- stg_chargeback_agg
-- Grain: 1 row per transaction_id. A transaction could in principle receive
-- more than one chargeback; none do in this dataset (verified below), but
-- the SUM/COUNT pattern is applied defensively regardless.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS stg_chargeback_agg;
CREATE VIEW stg_chargeback_agg AS
SELECT
    transaction_id,
    COUNT(*)             AS chargeback_count,
    SUM(amount)          AS chargeback_amount_sum,
    MIN(opened_at)       AS first_opened_at
FROM chargeback
GROUP BY transaction_id;

-- ---------------------------------------------------------------------------
-- stg_merchant_risk_snapshot_dedup
-- Grain: 1 row per (merchant_id, snapshot_month), per the case's stated
-- grain for this table. 66 combinations currently violate that grain
-- (DQ report D08). Deduplication rule (documented, disclosed, conservative):
-- keep the HIGHER risk_score per (merchant_id, snapshot_month) — i.e. treat
-- a merchant as at least as risky as its most recent/highest observed score
-- until the source system adds a scored_at timestamp to break ties properly.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS stg_merchant_risk_snapshot_dedup;
CREATE VIEW stg_merchant_risk_snapshot_dedup AS
SELECT merchant_id, snapshot_month, MAX(risk_score) AS risk_score,
       CASE WHEN MAX(risk_score) < 40 THEN 'Low'
            WHEN MAX(risk_score) < 70 THEN 'Medium'
            ELSE 'High' END AS risk_band   -- recomputed from the (post-dedup) score, not trusted from source (DQ report D12)
FROM merchant_risk_snapshot
GROUP BY merchant_id, snapshot_month;
