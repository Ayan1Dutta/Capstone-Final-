# Task 6 — Operational vs Commercial Diagnosis

Built on the trusted model (Task 4) and the segmentation evidence (Task 5).
All figures below are measured, not assumed.

## The observed decline, restated
Contribution profit per successful transaction fell from **$0.290 (Jan) to
$0.042 (Jun)** — roughly an **85% decline** — while attempted volume grew
**62%** over the same period. Six candidate drivers were named across the
case brief and the four stakeholders: **latency, fraud controls, routing
cost, pricing, FX, and chargebacks.** Each is tested below against the
segmented evidence, then grouped into two operational drivers and two
commercial/risk drivers as the case requires.

---

## Operational driver #1 — Processing latency (10–25 Mar 2025 incident)

**What's real:** processing time on routes R3/R5 spiked ~5.7x during this
16-day window (4,264ms vs 747ms median, DQ report D15) — a genuine,
dateable operational incident, invisible in an unsegmented average.

**Does it explain the profit decline?** Not plausibly, on the evidence:
- The incident is a **16-day event concentrated in March**; the profit
  decline is a **6-month, steadily worsening trend** that continues long
  after the incident ended (April and June are both worse than March).
- Latency does not enter the contribution-profit formula directly (it
  affects processing time, not fees or costs).
- A direct check — R3 transactions inside the 10–25 Mar window vs the rest
  of March on the same route — showed average profit of $0.217 vs $0.380.
  This is directionally suggestive but built on small samples (186 vs 199
  transactions) and has no mechanical link in the cost model; it is **not
  strong evidence of a causal effect**, and should not be reported as one.

**Verdict:** Real operational issue, worth fixing for customer experience
and reliability reasons — **but not a plausible explanation for the
profit-per-transaction trend.** This is one of the two required
operational drivers.

---

## Operational driver #2 — Fraud controls / false declines

**What's real:** from April, a new scoring rule (`R_ML_SCORE`, running on a
beta model `fraud_v4.0-beta`) is applied increasingly to **High-risk-tier**
merchants. The decline rate for that specific tier genuinely **doubles**
(8.25% in Jan → 16.35% in May) while every other risk tier's decline rate
stays flat (~7–8.7%) throughout — see Task 5, "Risk Tier – Fraud Test."
This is exactly the Risk Head's concern, and it is confirmed.

**Does it explain the profit decline?** This is the **disproven/weakened
stakeholder assumption** the case brief asks for. Transactions from
High-risk merchants that DO succeed show **no worse profit trend** than any
other tier — $0.33 (Jan) → $0.23 (Jun), a milder decline than the *untouched*
Low-risk tier, which falls from $0.30 to **–$0.04** over the same period.
Tighter fraud rules changed **who gets through** (success rate, a real and
separate problem worth fixing), not **the economics of the transactions that
succeed** (the executive KPI in question).

**Verdict:** Real, well-targeted, but **explains a volume/success-rate
problem, not the contribution-profit-per-successful-transaction problem.**
The Risk Head's implied causal link to the executive KPI is not supported —
state this plainly rather than letting the (real) decline-rate finding be
mistaken for an explanation of the (separate) profit finding.

---

## Commercial/risk driver #1 — Routing cost & mix (Head of Payments)

**What's real:** Route R3 (PayGlobal)'s variable fee stepped from 1.2% to
1.6% on 1-Apr-2025, and R3's share of successful volume grew every month in
every country served (24.9% in Jan → 37.9% in Jun).

**Does it explain the profit decline?** This is the **dominant driver**.
The mix-vs-rate decomposition (Task 5) shows Route R3 alone explains **61.7%
of the total observed decline**, and — critically — almost all of that
(**–$0.171 of –$0.139 net**) comes from R3's own economics deteriorating
(the **rate** effect), not simply more volume moving there (the **mix**
effect for R3 is actually slightly *positive*, +$0.032, because R3 was a
comparably profitable route before April). Route R4 adds a further 22.5%,
also via its own declining economics as blended country averages get pulled
down by the R3 mix shift.

**Verdict:** Confirmed as the primary, structural driver — a real fee
increase, compounding with continued volume growth into the affected route.

---

## Commercial/risk driver #2 — Chargeback drift by merchant category

**What's real:** chargeback incidence and cost have been rising since
roughly March, concentrated in **Electronics** and **Digital Goods**
merchants — total chargeback cost more than doubled over the period
($230 in Jan to $580 in Jun, Task 4 model output).

**Does it explain the profit decline?** Partially, and it is the
**second-largest single-category** explanation: Electronics alone explains
**42.9%** of the merchant-attributable decline (baseline profit $1.168 →
$0.596), with Digital Goods (19.5%) and Retail Goods (24.8%) adding most of
the rest. This is a real, independent commercial driver — not simply an
artefact of the route story — though the two are likely correlated (these
categories may disproportionately use the routes shifting toward R3; Task 5
flags this as a caveat rather than double-counting it).

**Verdict:** Confirmed as a real, secondary driver, concentrated in specific
merchant categories — worth its own remediation track (dispute prevention/
underwriting for those categories), separate from the routing fix.

---

## Also tested: Pricing (CFO) and FX

**Pricing:** the known Singapore-Enterprise fee renegotiation (2.6%→1.5%,
Feb 2025) is real by construction but **too small and too narrow a slice**
to detect cleanly against normal month-to-month noise at this sample size —
consistent with Task 1's assessment that pricing is "real but minor," not
the primary driver. No broader, undocumented pricing erosion was found.

**FX:** not a driver of the *actual* decline — it is a **measurement risk**.
Using `card_network` instead of `settlement` rate would change the computed
USD figures by ~1.1 percentage points, which is large enough to distort a
period-over-period comparison if the rate choice were ever applied
inconsistently, but this is a data-trust/methodology risk (the Data Head's
concern), not a business event that occurred. The trusted model in Task 4
fixes the rate choice explicitly for this reason.

---

## Summary verdict table

| Candidate driver | Type | Real & confirmed? | Explains the profit-per-successful-txn decline? |
|---|---|---|---|
| Processing latency (Mar incident) | Operational | Yes (5.7x spike, R3/R5, 10–25 Mar) | No — wrong time horizon, no cost-model linkage |
| Fraud controls / false declines | Operational | Yes (decline rate doubles, High-risk only) | No — hits success rate, not per-transaction economics (**Risk Head's implied assumption disproven for this KPI**) |
| Routing cost & mix (Route R3) | Commercial/Cost | Yes (fee +33%, share +52%) | **Yes — 61.7% of the total decline, primarily via rate, not mix** |
| Chargeback drift (Electronics/Digital Goods) | Commercial/Risk | Yes (cost +152% over the period) | **Yes — 42.9% of the merchant-attributable decline (Electronics alone)** |
| Merchant pricing (CFO) | Commercial | Yes, but narrow (SG-Enterprise only) | Not detectably at this sample size — minor |
| FX rate-type choice | Data/Methodology | Yes (~1.1pp swing possible) | Not a driver of the real decline — a risk to how it's *measured* |

**Bottom line for the 60-day plan (Task 8):** prioritize the routing
cost/mix issue first (largest, most structural, single lever — renegotiate
or rebalance away from R3), then the Electronics/Digital Goods chargeback
drift (second largest, needs its own track). Fraud tightening and the
latency incident are legitimate operational fixes but should be scoped and
resourced separately — fixing them will not, on this evidence, move the
executive KPI.
