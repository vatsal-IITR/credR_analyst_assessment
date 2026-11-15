# Executive memo: was recovery really up 11%?

**To:** Leadership team  **Data:** 1 Jan - 8 Aug 2026, 30,000 accounts, Rs 1,049 Cr outstanding  **Detail:** `notebooks/collections_analysis.ipynb`

## What happened

The reported "+11% month-on-month" is arithmetically correct and operationally meaningless. Recovery rose 11.0% from February (Rs 17.0 Cr) to March (Rs 18.9 Cr) because **February has 28 days and March has 31**, which alone adds 10.7%. Per calendar day, recovery moved **+0.3%** (95% range about -6% to +7%). Across January to July there is no trend (-2.5%, not significant). The month before the "gain" showed a 9.1% fall for the same reason. Recovery runs at about **Rs 60 lakh per day**, every month.

Other reported numbers that mislead: the raw payment file overstates recovery by 2.0% (500 duplicate payment ids) and by 45.7% if failed, pending and reversed payments are counted; the reported PTP kept rate (about 25%) falls to about 3% when checked against actual payments.

## Why

I tested portfolio mix, DPD, cohort, selection, denominators, time zones, vendors, calling hour, attempt frequency and tenure. **None explains an improvement, because there was none to explain.**

| Finding | Label |
|---|---|
| The +11% is the number of days in the month | Fact |
| Per-day recovery is flat Jan-Jul | Strong evidence |
| No change in portfolio mix; the book is a fixed 30,000 accounts | Fact |
| Segment swings (DPD 1-30 +10.9%, DPD 91+ -9.1%) are within what chance produces | Strong evidence |
| The April targeting change had no measurable effect (range -9% to +11%) | Strong evidence, assumes the change date |
| Effective contacts (call, WhatsApp, SMS, field) do not raise next-week payment (1.80% vs 1.85%) | Strong evidence |
| No available field predicts who pays (AUC 0.50) | Strong evidence |
| Attribution reports are unreliable: 90.6% of payments have no contact in the prior 7 days | Fact |
| Agent tenure, language, geography drive recovery | Not testable: agent identity and borrower links are broken |
| The pattern of "nothing links to payment" comes from data-linking faults, not from channels truly not working | Hypothesis |

## How confident are we

- **High** that the +11% is not a performance gain (arithmetic, plus bootstrap test).
- **Medium** that underlying recovery was flat.
- **Low** on what drives recovery. Event tables (calls, dispositions, agents) have broken keys: dispositions never match the account of their call, 1,000 agent ids carry 30 conflicting profiles each, borrower ids do not link to accounts, payments and digital events carry no time zone. Because of this I could not measure language, geography, tenure, cost or agent productivity.

## What we should do

1. **Stop reporting month-on-month totals.** Report recovery per calendar day, and rate on the full 30,000-account book.
2. **Do not release the Rs 10 Cr on current evidence.** Contact-based options (telephony, more agents, AI voice, WhatsApp, field) show no measurable effect; even on the optimistic 95% bound they return about Rs 5 Cr a year against Rs 10 Cr. If one option must be named, choose **better borrower targeting, released in tranches**: Rs 1 Cr now for a randomised test, the balance only if it beats break-even.
3. **Run a randomised holdout** (50/50 old vs new targeting, 8+ weeks, payment-validated outcomes). It also needs cost per touch, which we do not have.
4. **Fix the data**: time zones on payments and events, the call-to-disposition key, a unique agent master, a payment-reversal link, and cost data.

## Expected financial impact

| Item | Estimate |
|---|---|
| Value of the reported "+11%" | Rs 0. Nothing was gained |
| Recovery run-rate | about Rs 218 Cr a year (20.8% of the book) |
| Targeting option, expected incremental recovery | +Rs 2.2 Cr a year (95% range -Rs 19 Cr to +Rs 24 Cr) |
| Cost | Rs 10 Cr (first tranche Rs 1 Cr) |
| ROI, (gain - cost) / cost | central -78%; range -292% to +136% |
| Break-even | +4.6% of annual recovery (Rs 10 Cr); payback 4.6 years central, about 5 months at the upper bound, never at the lower bound |
| Downside | Rs 10 Cr spent with no gain, and a loss of up to Rs 19 Cr a year if the new targeting hurts; tranching caps first exposure at Rs 1 Cr |
| Confidence | Low. A reliable decision needs the randomised test and cost data |
