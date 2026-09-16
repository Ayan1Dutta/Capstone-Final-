

---

## 1.Task 6 

Task 5 found **where** the profit is falling — Route R3, and chargebacks on
Electronics/Digital Goods merchants. it is about  **why**, and more
importantly, it forces every possible explanation to be tested against real
numbers before it's allowed to be called a cause.

The case gave four stakeholders, each blaming something different. Add the
full list of possible causes and there are six suspects on trial:

| # | Suspect | Owner | Type |
|---|---|---|---|
| 1 | Processing latency | Head of Payments | Operational |
| 2 | Fraud controls | Risk Head | Operational |
| 3 | Routing cost | Head of Payments | Commercial |
| 4 | Merchant pricing | CFO | Commercial |
| 5 | FX rate movement | Data Head | Measurement |
| 6 | Chargeback drift | — | Commercial/Risk |

Each one gets confirmed, rejected, or — the more interesting middle case —
found to be **real, but explaining the wrong thing.**

---

## 2. What "operational" vs "commercial" actually means

- **Operational driver** — something goes wrong in the plumbing. A system
  malfunction, a performance issue, a rule firing more often than intended.
  Nothing about the underlying business economics changed.
- **Commercial driver** — a structural economic change. A price moved, a
  fee changed, the mix of business shifted. The business itself changed,
  not just a system's behaviour.

This distinction matters because the fix is completely different in each
case: you patch a system for an operational problem, and you renegotiate or
restructure for a commercial one.

---

## 3. Operational driver #1 — Processing latency

**What happened:** Between 10–25 March 2025, Routes R3 and R5 processed
payments in ~4,264 milliseconds on average — about 4.3 seconds. Normal is
~747 milliseconds. That's 5.7x slower than usual, a genuine 16-day incident
on PayGlobal's infrastructure.

**Why it does not explain the profit decline:**

```
Latency incident:   10 Mar → 25 Mar 2025   (16 days, one month)
Profit decline:     Jan → Jun 2025         (6 months, continuous)
```

A 16-day event cannot explain a 6-month trend. Profit was healthy in
January and February. It was already collapsing in April and stayed down
through June — long after the incident ended.

The direct test made this undeniable:

| Period | Route R3 avg profit/txn |
|---|---|
| During the spike (10–25 Mar) | **$0.217** |
| Outside the spike (other months) | **$0.041** |

Transactions *during* the spike were actually **more** profitable than
those outside it — the opposite of what a "latency hurts profit" theory
would predict. The reason: the spike happened in March, before the April
fee increase. Slow processing, cheap fees. After April: fast processing,
expensive fees.

**Verdict:** Real operational problem. Wrong timeline, wrong mechanism.
Does not explain the profit decline.

---

## 4. Operational driver #2 — Fraud controls / false declines

**What happened:** From April 2025, a new fraud scoring model
(`fraud_v4.0-beta`) was applied increasingly to **High-risk tier**
merchants. It declined more payments than the older models. The decline
rate for High-risk merchants genuinely doubled:

| Month | High-risk decline rate |
|---|---|
| January | 8.25% |
| May | 16.35% |

Low and Medium risk tiers stayed flat at 7–8% throughout. This is real,
targeted, and measurable.

**The critical test:** fraud controls can only affect payments *being
attempted*. Once a payment succeeds, the fraud engine has nothing more to
do with its economics. So the real question is: do successful High-risk
transactions earn *less* profit than other successful transactions?

| Tier | January profit/txn | June profit/txn |
|---|---|---|
| High-risk | $0.334 | $0.229 |
| Low-risk | $0.303 | **−$0.040** |

The Low-risk tier — never touched by the new fraud model — shows a
*steeper* profit decline than the tier that was specifically targeted. If
fraud controls were the cause, the opposite pattern would be expected.

**The analogy:** a restaurant bouncer turning away more customers at the
door changes *who gets in* (a volume problem), not the food quality or
bill for the customers who *do* get seated. Fraud controls are the
bouncer.

**Verdict:** Real operational problem — confirmed for the volume/success-
rate KPI. **Disproved** for the profit-per-successful-transaction KPI.
The Risk Head is right about a real problem, but the wrong metric.

---

## 5. Commercial driver #1 — Routing cost & mix (the primary driver)

Two things happened to Route R3 at the same time, and they compounded.

**Thing 1 — the fee went up.** On 1 April 2025, PayGlobal raised its
variable fee from 1.2% to 1.6% of every transaction — a 33% cost increase,
overnight, on AstraPay's main cross-border route.

**Thing 2 — volume kept moving there anyway.** Independent of the fee
change, R3's share of successful volume climbed every single month:

| Month | R3 share of successful volume |
|---|---|
| January | 24.9% |
| June | 37.9% |

More volume flowing into a route that just became significantly more
expensive — these two effects multiply rather than simply add.

**Separating the two effects (mix vs rate):**

| Effect | Meaning | Value |
|---|---|---|
| Mix effect | Impact of volume moving to R3, using R3's *old* (cheaper) economics | **+$0.032** (slightly positive) |
| Rate effect | Impact of R3's *own* economics getting worse | **−$0.171** (large) |

The mix effect is actually positive — sending more volume to R3 at the old
fee would have been fine, even good. It's the fee increase itself — the
rate effect — that destroyed R3's profitability.

**Combined: Route R3 explains 61.7% of the entire profit decline** measured
between the January–February baseline and the May–June latest period.

**Verdict:** Confirmed as the primary driver. Two separable sub-causes —
a structural fee increase on a specific date, and an ongoing volume shift
throughout the period.

---

## 6. Commercial driver #2 — Chargeback drift

A chargeback is a customer-disputed payment — the bank reverses the
transaction and AstraPay pays a dispute-handling fee for each case.

The chargeback cost was not spread evenly. It concentrated in two merchant
categories:

| Category | January rate | June rate | Change |
|---|---|---|---|
| Electronics | 1.37% | 6.46% | ~4.7x worse |
| Digital Goods | 1.95% | 7.34% | ~3.8x worse |
| All other categories | ~2.5–3.5% | ~2.5–3.5% | Stable |

This is independent of the routing story. Even a fully fixed Route R3
would not touch this problem — it needs its own remediation track.

**Why these two categories:** electronics are high-value (bigger incentive
to dispute), digital goods are intangible (easier to claim non-delivery),
and both attract more fraud attempts than lower-value physical categories.

**Verdict:** Confirmed as a real, secondary commercial driver, concentrated
in two specific merchant categories.

---

## 7. Also tested — Pricing (CFO) and FX (Data Head)

### Pricing

Singapore Enterprise merchants had their fee cut from 2.6% to 1.5%
starting February 2025 — a real, confirmed revenue reduction. But it
touches only one pricing plan in one country. Far too narrow to explain a
six-month, three-country, 85% profit collapse.

**Verdict:** Real but minor. Not a primary driver.

### FX rate movement

Unlike the other five, this isn't a business event — it's a **measurement
risk**. The `fx_rate` table carries three different rate types per
currency per day. Using `interbank` instead of `settlement` would make
computed USD profit look about 1.1 percentage points healthier than
reality — a silent, invisible distortion.

This was fixed at the model layer (Task 4) by explicitly specifying
`rate_type = 'settlement'` everywhere revenue is calculated. Once applied
consistently, currency movement over this period is small and non-
directional — it does not drive an 85% decline.

**Verdict:** Not a business driver of the decline. A data-trust risk,
already corrected in the trusted model.

---

## 8. Final verdict table

| Suspect | Type | Is it real? | Explains the profit-per-txn KPI? |
|---|---|---|---|
| Processing latency | Operational | Yes — 5.7x spike in March | **No** — wrong timeline; profit was *higher* during the spike |
| Fraud controls | Operational | Yes — decline rate doubled for High-risk | **No** — hits volume, not per-transaction economics |
| Routing cost & mix | Commercial | Yes — fee +33%, share +52% | **Yes — 61.7% of the total decline** |
| Chargeback drift | Commercial/Risk | Yes — Electronics ~4.7x worse | **Yes — secondary driver, two categories** |
| Merchant pricing | Commercial | Yes — Singapore Enterprise only | **No** — too small and too narrow |
| FX rate choice | Measurement | Yes — up to 1.1pp swing possible | **No** — a reporting risk, already fixed upstream |

---

## 9. The bottom line

The entire purpose of this exercise is to be able to walk into the
executive meeting and say:

> "We tested all six possible explanations against real data. Two are
> confirmed drivers and need fixing now — routing cost/mix, and
> chargeback drift on two merchant categories. Two are real problems, but
> they explain a different metric than the one being asked about — fraud
> tightening and processing latency. One is real but too small to matter
> at this scale — the pricing change. One was a data-quality risk that has
> already been corrected upstream — FX rate selection. Here are five
> actions, in priority order, with owners and success metrics."

Without this step, Task 5's finding — "Route R3 is the problem" — would
just invite the Risk Head to ask "but what about my fraud controls?" and
the CFO to ask "but what about pricing?", and the meeting goes in circles.
Task 6 answers every question before it's asked.
