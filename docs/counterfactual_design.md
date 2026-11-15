# Part 4: Counterfactual design

**Question from leadership:** "What would recovery have looked like if we had not changed the targeting strategy?"

## What the data gives us (and does not)

- `campaigns.strategy_version` has four values (`legacy`, `v1`, `v2`, `v3`) and `daily_targeting` links accounts to campaigns by date.
- There is **no field that says "the new strategy went live on date X"**, and the mix of strategy versions in daily targeting is flat month to month (legacy about 31%, v3 about 26%, every month). So I cannot find the change date from the data.
- I therefore **assume** the change date the brief describes: targeting changed on **1 April 2026**, and `v3` is the new strategy. This is the biggest assumption in this document. If the real change was different, the identification below must be redone.

## Design

| Element | Choice |
|---|---|
| Unit | account x month (30,000 accounts, Jan-Jul, August excluded because it has 8 days) |
| Treatment group | accounts targeted under strategy `v3` at least once in Apr-Jul (5,882 accounts) |
| Control group | accounts targeted in Apr-Jul but never under `v3` (11,118 accounts) |
| Pre / post | Jan-Mar / Apr-Jul |
| Outcome | (1) paid at least once in the month, (2) recovered Rs in the month (SUCCESS payments, de-duplicated) |
| Estimator | difference-in-differences: `outcome ~ treated * post (+ DPD bucket, risk segment, loan type)`, standard errors clustered by account |
| Counterfactual | treated group's Apr-Jul recovery minus the estimated DiD effect x number of treated account-months |

SQL: `analysis.did_panel` in `sql/06_analysis.sql`. Estimation: section 6 of the notebook.

## Identification strategy

The effect is identified by comparing the **change** in treated accounts with the change in control accounts, so anything that moves both groups together (seasonality, month length, collections-wide events) is removed. It needs:

1. **Parallel trends**: without the change, treated and control would have moved the same way.
2. **No anticipation**: nothing changed for treated accounts before April.
3. **SUTVA / no spillover**: a treated account does not change the outcome of a control account (they do not share agents' time).
4. **Group assignment not driven by outcomes**: accounts are not put in `v3` because they were about to pay.

## What I found when checking these

- Parallel trends: partly supported. The event study (notebook 6) shows treated minus control gaps of -1.2pp in January (p = 0.05) and about 0 in February and March. January is a single noisy month, but it means I cannot call the assumption clean.
- Balance: treated and control have the same DPD (p = 0.70), outstanding and risk segment (p = 0.43). **Loan-type mix differs (p = 0.008)**, so loan type is included as a control.
- Assumption 4 cannot be tested. I could not see how `v3` accounts were chosen, and `target_definition` values (DPD>=30, NPA...) do not line up with strategy versions.

## Result

| | Estimate | 95% CI |
|---|---|---|
| Pay-rate effect | -0.16pp | -0.80pp to +0.48pp |
| Recovery per account-month | +Rs 61 | -Rs 533 to +Rs 655 (about -9% to +11%) |
| Treated group Apr-Jul actual vs counterfactual | Rs 13.86 Cr vs Rs 13.72 Cr | effect -1.26 Cr to +1.54 Cr |

**Answer to leadership:** recovery would have looked about the same (within roughly +/-10%). The change did not measurably help or hurt. The data cannot rule out a gain or loss of about 10%.

## Confounding factors

| Factor | Handled? |
|---|---|
| Month length / seasonality | Yes, both groups share the same months |
| DPD, risk, loan type | Controlled in regression |
| Agent capacity, vendor, campaign channel | Not controlled: not reliably linked to accounts (agent profile problem, call-to-disposition link broken) |
| Targeting chosen on unobserved borrower intent | **Not handled** |
| Treatment intensity (how many times an account was targeted) | Not modelled; treated = ever v3 |

## Limitations

1. The change date is assumed, not observed.
2. Treatment is "ever targeted under v3 in Apr-Jul" so it is measured after the fact; accounts targeted more often are more likely to be flagged treated. A cleaner design would assign on a pre-period rule.
3. Power is limited: monthly pay rate is about 7.7%, so a 10% relative change is about 0.8pp, the size of the confidence interval.
4. Only one pre-period trend check is possible with three pre-months.

## Better designs if more data / control were available

1. **Randomised holdout** (preferred): randomly hold out 10-20% of targetable accounts on the old strategy for 8+ weeks. This removes assumptions 1 and 4. Sample size: to detect the break-even lift (+4.6% relative) needs about 47,000 accounts per arm (notebook 7.1), more than the whole book. So use account-weeks or a longer horizon, or accept detecting only a larger lift (about 8% relative with 15,000 per arm).
2. **Synthetic control / matching** on pre-period payment history and DPD if no randomisation is allowed.
3. **Bayesian shrinkage** on segment-level effects (DPD x channel) to stop noisy segments from producing false wins.
