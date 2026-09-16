# AstraPay Trusted Profitability Model
### Task 4 — Logical model, grain, metric definitions, and transformation logic

---

## 1. Layered logical design

The model is built in three layers so that the join-fan-out risks documented
in the DQ report (D09, D10, D18) are fixed structurally, not by convention:

```
LAYER 1 — STAGING (collapse every 1:many table to <=1 row per transaction_id)
    stg_fraud_agg              (fraud_decision:  avg 1.49 rows/txn -> 1 row/txn)
    stg_settlement_agg         (settlement:      0-2 rows/txn      -> 1 row/txn)
    stg_chargeback_agg         (chargeback:      0-1 rows/txn      -> 1 row/txn)
    stg_merchant_risk_snapshot_dedup  (66 duplicate merchant-months -> 1 row/merchant-month)

LAYER 2 — FACT (grain: exactly 1 row per transaction_id, verified = 8,000 rows)
    fact_transaction_attributes
        transaction  --(customer_id)-->            customer            [many:1]
                     --(merchant_id, nullable)-->   merchant            [many:1]
                     --(route_id + created_at date)--> route_cost       [many:1]
                     --(transaction_id)-->  stg_fraud_agg               [1:1 or 1:0]
                     --(transaction_id)-->  stg_settlement_agg          [1:1 or 1:0]
                     --(transaction_id)-->  stg_chargeback_agg          [1:1 or 1:0]
                     --(currency/settlement_currency + date + rate_type)--> fx_rate [many:1, 3x for different purposes]

LAYER 3 — METRICS (same grain; adds the computed USD measures)
    fact_transaction_profit / fact_transaction_profit_final
        amount_usd_attempted, revenue_usd, processing_cost_usd,
        chargeback_cost_usd, contribution_profit_usd, is_profit_kpi_eligible
```

This is a **transaction-grain fact table with conformed dimensions**
(customer, merchant, route, currency/date) — a star schema where
`fact_transaction_profit_final` is the fact and `customer` / `merchant` /
`route_cost` / `fx_rate` are the dimensions. `stg_*` are not dimensions —
they are fan-out guards that make the star possible.

**Verified, not assumed:** `SELECT COUNT(*) FROM fact_transaction_attributes`
= 8,000 = `COUNT(*) FROM transaction`, exactly. No LEFT JOIN in Layer 2
changes the row count (see `04_sql/03_validation_reconciliation.sql`,
Checks 1–2).

---

## 2. Grain statements

| Object | Grain |
|---|---|
| `stg_fraud_agg` | 1 row per `transaction_id` |
| `stg_settlement_agg` | 1 row per `transaction_id` (only for transaction_ids that have >=1 real settlement row) |
| `stg_chargeback_agg` | 1 row per `transaction_id` |
| `fact_transaction_attributes` / `fact_transaction_profit_final` | 1 row per `transaction_id` (= 1 row per row of `transaction.csv`) |

---

## 3. Metric definitions (numerator / denominator / date basis / exclusions)

| Metric | Numerator | Denominator | Date basis | Exclusions |
|---|---|---|---|---|
| **Attempted volume** | COUNT(transaction_id) | — | `created_at` | None — every row in transaction.csv counts as an attempt |
| **Successful volume** | COUNT where `status='success'` | — | `created_at` | None |
| **Success rate** | Successful volume | Attempted volume | `created_at` | None |
| **Gross Payment Value (attempted)** | SUM(`amount_usd_attempted`) | — | `created_at` | `status != 'success'` rows are still counted here if the KPI is "attempted" GPV; for a **successful** GPV variant, filter to `status='success' AND amount>0` (excludes the 35 zero-amount glitches, DQ D03b) |
| **Processing cost per successful transaction** | SUM(`processing_cost_usd`) | COUNT where `status='success' AND amount>0` | `created_at` (route/date lookup) | Same population as successful GPV |
| **Fraud/chargeback cost per successful transaction** | SUM(`chargeback_cost_usd`) | COUNT where `status='success' AND amount>0` | Attributed to the **originating transaction's** `created_at` month; valued as a flat $10 handling fee per case (see §5) | Chargebacks with no matching `transaction_id` are structurally impossible to include (staging view is built from the chargeback side and simply produces nothing to join to a nonexistent transaction — verified 0 orphan chargebacks in this dataset) |
| **FX impact** | SUM(`amount_usd_attempted` using `interbank`) − SUM(`amount_usd_attempted` using `settlement`) for the same population | — | `created_at` | Comparison metric only; not part of the contribution-profit formula itself |
| **Contribution Profit per Successful Transaction (USD)** — **the executive KPI** | SUM(`contribution_profit_usd`) | COUNT where `is_profit_kpi_eligible=1` | `created_at` for which month it counts against; `settlement_date` for revenue/FX; see §4 | `status != 'success'`; the 35 zero-amount glitches (D03b); the 232 transactions with real amount but **no settlement yet** (D16) — these are tracked separately as "settlement pending %" alongside the KPI, never coerced to $0 |

**On "GPV attempted" vs "successful GPV":** the case brief warns not to treat
volume/attempts/successful/settled as the same metric. This model keeps four
distinct, separately queryable counts at all times: `attempted_transactions`,
`successful_transactions`, `profit_kpi_eligible_transactions` (successful +
real amount + settled), and `settlement_leg_count` (raw settlement rows,
which is neither of the above — see DQ D09).

---

## 4. Which date drives which calculation (full rationale in `02_data_contract.xlsx`, "KPI Date Logic" tab)

- **`created_at`** — attempts, success rate, GPV, which month a transaction
  (and any later chargeback against it) counts toward, and the **route_cost**
  lookup (the route did its work then, not at settlement — this matters
  specifically around the 1-Apr-2025 R3 fee change).
- **`settlement_date`** — realized revenue (`settlement.fee_amount`) and its
  FX conversion, because that's when the money and the currency conversion
  actually happen.
- **`interbank` rate at `created_at`** — attempted/indicative USD values and
  the variable-cost component of processing cost (costed pre-settlement).
- **`settlement` rate at `settlement_date`** — realized revenue conversion
  (closest to what AstraPay actually nets).
- **`card_network` rate** — deliberately **never used** in this model. It
  carries a card-scheme markup unrelated to AstraPay's own economics; using
  it would silently overstate the FX drag (this is the exact trap flagged in
  the DQ report, D-series "valuation ambiguity").

---

## 5. Currency conversion logic

`fx_rate.rate_to_usd` = USD value of 1 unit of the row's currency, so
`amount_usd = amount_local × rate_to_usd`. Every join to `fx_rate` in this
model specifies **currency, date, and rate_type explicitly** — never an
unqualified "the" rate — because 3 valid rate_types coexist per currency/day
(DQ report finding: up to ~1.5% apart).

A small subset of settlements (~15% of transactions on routes R3/R5/R6) are
already settled directly in USD in the source data; the model detects this
(`settlement_currency = 'USD'`) and skips conversion for those rows rather
than applying a second, redundant conversion.

## 6. Settlement-fee attribution logic (safe, no fan-out)

`settlement.fee_amount` is AstraPay's merchant-fee **revenue** for that
transaction (separate from `route_cost`, which is AstraPay's **cost** paid
to the processing route — two different economic legs, never confused in
this model). Because up to 2 settlement legs can exist for one transaction
(DQ D09) and some transactions have none yet (D16):

1. `stg_settlement_agg` **sums** `fee_amount` and `settlement_amount` across
   all legs for a `transaction_id` **before** any join to `transaction` — this
   is safe because a single transaction's legs are always in one consistent
   currency (verified: 0 transactions with mixed settlement currency,
   `03_validation_reconciliation.sql` Check 4).
2. Orphan settlement rows (71, no matching `transaction_id`, D17) never reach
   the fact table at all — the staging view is a `GROUP BY` over
   `settlement`, and a row with an unmatched key simply produces a row that
   nothing ever joins to; it cannot inflate `fact_transaction_profit`.
3. Transactions with **zero** settlement rows are **not** treated as $0
   revenue — `is_profit_kpi_eligible = 0` for them, and they are reported
   separately as "settlement pending" so the KPI is never silently deflated
   by unsettled (not unprofitable) transactions.

## 7. Assumption revised during modelling — chargeback cost

Task 1 originally assumed *"AstraPay bears 100% of chargeback cost."* Modelled
literally (the full disputed `chargeback.amount` as a cost), this produced a
structurally impossible result: **contribution profit per successful
transaction was deeply negative in every single month**, because a small
number of large disputes (avg. disputed amount ≈ $185 USD-equivalent)
dwarfed the thin per-transaction margin (≈1.1% of ticket size). That is not
how card-scheme chargebacks actually work: the disputed **principal** is
normally clawed back from the **merchant's own settlement** (merchant
liability), not from the processor's revenue — the processor typically
absorbs only a flat **dispute-handling fee**.

**Revised assumption, used throughout this model:** chargeback cost to
AstraPay = **$10 USD flat fee per chargeback case**, not the disputed
amount. This is a placeholder pending confirmation from Finance/Risk on
AstraPay's actual scheme fee schedule and liability terms — flagged
explicitly rather than silently absorbed, per the same DQ discipline used
throughout this project. Under this corrected assumption the model produces
an economically sane, still-declining KPI (§8) — the deterioration is real
and explained by routing and mix, not an artefact of an unrealistic cost
assumption.

## 8. Resulting Executive KPI (monthly, on the trusted model)

| Month | Attempted | Successful | Success rate | KPI-eligible | Settlement pending % | **Contribution profit / successful txn (USD)** |
|---|---|---|---|---|---|---|
| 2025-01 | 1,000 | 868 | 86.80% | 841 | 2.55% | **$0.290** |
| 2025-02 | 1,172 | 1,038 | 88.57% | 992 | 3.97% | **$0.348** |
| 2025-03 | 1,263 | 1,097 | 86.86% | 1,047 | 4.03% | **$0.271** |
| 2025-04 | 1,338 | 1,198 | 89.54% | 1,159 | 2.77% | **$0.096** |
| 2025-05 | 1,606 | 1,411 | 87.86% | 1,362 | 3.20% | **$0.152** |
| 2025-06 | 1,621 | 1,428 | 88.09% | 1,372 | 3.31% | **$0.042** |

Volume (attempted) grew **62%** Jan→Jun while contribution profit per
successful transaction fell **~85%** ($0.290 → $0.042) — this is the
executive question, now quantified on a defensible, fan-out-proof,
double-counting-proof model. Root-cause attribution is in Task 5.

Full SQL implementing every step above is in `04_sql/` (`01_staging_views.sql`,
`02_fact_transaction_economics.sql`, `03_validation_reconciliation.sql`),
executed and verified against the actual dataset (SQLite; portable to any
ANSI-SQL warehouse with minor date-function changes).
