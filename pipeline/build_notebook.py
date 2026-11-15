"""Builds notebooks/collections_analysis.ipynb from the cell list below and executes it.
Kept as a script so the notebook can be regenerated; the notebook itself is the deliverable.
"""
import pathlib
import nbformat as nbf
from nbclient import NotebookClient

ROOT = pathlib.Path(__file__).resolve().parents[1]
cells = []


def md(s):
    cells.append(nbf.v4.new_markdown_cell(s.strip("\n")))


def code(s):
    cells.append(nbf.v4.new_code_cell(s.strip("\n")))


md("""
# Collections analysis: is "recovery up 11% month-on-month" real?

All numbers come from the DuckDB file built by `pipeline/run_pipeline.py`. Nothing here reads the raw CSVs
directly except where I deliberately compare raw vs clean.

**Short answer (details below):** the 11% exists as arithmetic (Feb -> Mar, +11.0%) but it is a calendar effect.
February has 28 days and March has 31. Per day, recovery moved by +0.3%, which is well inside normal day-to-day noise.
Over Jan-Jul there is no trend at all.

Evidence labels used: **Fact** (directly computed from data), **Strong evidence** (several independent tests agree),
**Correlation** (association only), **Hypothesis** (plausible but not testable with this data).
""")

code("""
import duckdb, numpy as np, pandas as pd, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy import stats
import statsmodels.formula.api as smf
pd.set_option("display.width", 200); pd.set_option("display.max_columns", 40)
plt.rcParams.update({"figure.figsize": (8, 3.4), "axes.spines.top": False, "axes.spines.right": False})
con = duckdb.connect("../data/collections.duckdb", read_only=True)
q = lambda s: con.sql(s).df()
rng = np.random.default_rng(42)
""")

md("""
## 1. Raw -> Rejected/Corrected -> Golden

Every cleaning step writes a row to `dq.cleaning_log`. The `rows_corrected` column is the number of rows that were
kept but changed or flagged.
""")
code("""
log = q("select dataset, step, rows_in, rows_out, rows_rejected, rows_corrected from dq.cleaning_log")
log
""")
code("""
# Impact of cleaning on the headline number: total successful recovery, Jan 1 - Aug 8
raw_success = q("select sum(amount) v from stg.payments where payment_status='SUCCESS'").v[0]
clean_success = q("select sum(amount) v from golden.fact_payment where is_recovery").v[0]
raw_all = q("select sum(amount) v from stg.payments").v[0]
print(f"raw, all statuses (FAILED/PENDING/REVERSED included): {raw_all/1e7:8.1f} Cr")
print(f"raw, SUCCESS only (duplicates still in):              {raw_success/1e7:8.1f} Cr")
print(f"golden, SUCCESS only, de-duplicated:                  {clean_success/1e7:8.1f} Cr")
print(f"duplicates inflate SUCCESS by {100*(raw_success/clean_success-1):.2f}% ; ignoring status inflates by {100*(raw_all/clean_success-1):.1f}%")
""")

md("""
## 2. What happened

### 2.1 Monthly recovery, the way it was probably reported
""")
code("""
m = q("select * from metrics.monthly order by month_start")
m["month"] = m.month_start.dt.strftime("%b")
t = m[["month","days_with_data","recovery_raw_all_statuses","recovery_raw_success","recovery_clean"]].copy()
for c in ["recovery_raw_all_statuses","recovery_raw_success","recovery_clean"]:
    t[c+"_mom%"] = (t[c].pct_change()*100).round(2)
t[["month","days_with_data","recovery_raw_all_statuses_mom%","recovery_raw_success_mom%","recovery_clean_mom%"]]
""")
md("""
The "11%" shows up in the Mar row whichever way recovery is counted (raw all statuses +12.2%, raw success +11.0%,
clean +11.0%). It is a **Fact** that the number is reproducible. The next question is why it happened.
Note also that February was -9.1% the month before. A +11% right after a -9% looks like a rebound, not growth.
""")

md("### 2.2 Normalise for days in the month")
code("""
mm = m[m.month_start < "2026-08-01"].copy()
mm["per_day"] = mm.recovery_clean / mm.days_with_data
mm["mom_total_%"] = mm.recovery_clean.pct_change()*100
mm["mom_per_day_%"] = mm.per_day.pct_change()*100
mm[["month","days_with_data","recovery_clean","per_day","mom_total_%","mom_per_day_%"]].round(2)
""")
code("""
fig, ax = plt.subplots(1, 2, figsize=(11, 3.4))
ax[0].bar(mm.month, mm.recovery_clean/1e7, color="#3b82d4"); ax[0].set_title("Recovery per month (Cr)")
ax[1].bar(mm.month, mm.per_day/1e5, color="#7c5cd8"); ax[1].set_title("Recovery per calendar day (lakh)")
ax[1].set_ylim(0, 70)
plt.tight_layout(); plt.show()
""")
md("""
The left chart (what leadership sees) moves up and down with month length. The right chart is flat.
Feb -> Mar: 28 -> 31 days is +10.7% by itself, and the reported rise is +11.0%.
""")

md("### 2.3 Is the per-day change distinguishable from noise?")
code("""
d = q("select pay_date, sum(amount) a from golden.fact_payment where is_recovery and pay_date < '2026-08-01' group by 1 order by 1")
d["pay_date"] = pd.to_datetime(d.pay_date); d["month"] = d.pay_date.dt.month
feb, mar = d[d.month==2].a.values, d[d.month==3].a.values
boot = [(rng.choice(mar, len(mar)).mean() / rng.choice(feb, len(feb)).mean() - 1)*100 for _ in range(5000)]
lo, mid, hi = np.percentile(boot, [2.5, 50, 97.5])
print(f"Feb -> Mar change in average daily recovery: {mid:+.2f}%  (95% bootstrap interval {lo:+.1f}% to {hi:+.1f}%)")
print("Welch t-test on daily values:", stats.ttest_ind(mar, feb, equal_var=False))

x = (d.pay_date - d.pay_date.min()).dt.days
lr = stats.linregress(x, d.a)
print(f"Jan-Jul linear trend on daily recovery: {lr.slope:,.0f} Rs per day per day (p = {lr.pvalue:.2f}); "
      f"= {100*lr.slope*213/d.a.mean():+.1f}% over the 7 months")
h1, h2 = d[d.month<=3].a, d[d.month>3].a
print(f"Jan-Mar mean/day {h1.mean()/1e5:.1f} lakh vs Apr-Jul {h2.mean()/1e5:.1f} lakh ; p = {stats.ttest_ind(h1,h2).pvalue:.2f}")
""")
code("""
# weekday structure and autocorrelation: is there a weekly rhythm that could also move monthly totals?
d["dow"] = d.pay_date.dt.dayofweek
print(d.groupby("dow").a.mean().round(0).to_dict())
print("lag-1 autocorrelation of daily recovery:", round(d.a.autocorr(1), 3), " lag-7:", round(d.a.autocorr(7), 3))
""")
md("""
**Conclusion for "what happened"** (**Strong evidence**): there was no change in underlying recovery performance in the
period. The Feb -> Mar per-day change is +0.3% with an interval of roughly -6% to +7%, and the Jan-Jul trend is
indistinguishable from zero. The reported +11% is explained by the number of days in the month.

Which metrics are misleading: monthly total recovery (calendar), PTP kept rate as reported (see 5.4),
recovery per agent hour (see 5.5), and anything built on raw payments (duplicates, non-success statuses).
""")

md("""
## 3. Data forensics (A-G)

Each of these is a table in the `forensics` schema (`sql/05_forensics.sql`).
""")
md("### A. Duplicate payments")
code("""
a = q("select * from forensics.a_duplicate_payments")
a["inflation_%"] = (a.raw_success_amt/a.dedup_success_amt - 1)*100
print(a.round(2).to_string())
print(q("select * from forensics.a_reference_reuse").T)
""")
md("""
**Fact:** 500 payment_ids appear twice (ingestion retries). They inflate SUCCESS amount by about 2.0% in total.
It is spread across all months so it does not create the month-on-month jump, but it does overstate the level.

**Fact:** `payment_reference` is NOT a transaction id. 7,218 payment rows share a reference with a different row, and
in none of those cases is the other row on the same account. Removing "duplicate references" would wrongly delete up to 7,218
real payments, so I de-duplicate on `payment_id` only.
""")

md("### B. Attribution errors")
code("""
print(q("select * from forensics.b_attribution_window").round(3).to_string())
ch = q("select * from forensics.b_attribution_channel")
ch.pivot(index="channel", columns="method", values="payments").fillna(0).astype(int)
""")
md("""
**Fact:** only 9.4% of successful payments have any effective contact (answered call, delivered message, field contact)
in the 7 days before them, and 33.9% with a 30 day window. 90.6% of recovered rupees cannot be linked to a
7-day interaction. Any report that credits payments to "the latest campaign or interaction" is therefore attributing
most payments to something that has not happened inside a sensible window.

**Strong evidence** that attribution is unreliable: the share attributed rises almost linearly with window length,
which is what you get when touches are unrelated to payments (more window = more random overlap). Section 5.3
tests this directly.
""")

md("### C. Time zones")
code("q('select * from forensics.c_timezone').round(4)")
md("""
**Fact:** calls carry a `timezone` column (UTC, Asia/Kolkata, Asia/Dubai). Converting to IST changes the hour for every
UTC and Dubai call, changes the calendar day for 22.9% of UTC calls and 6.3% of Dubai calls, and moves 0.8% / 0.2% of
them into a different month. Roughly half of all calls are placed outside 08:00-20:00 on either clock, so the
call-hour field is unreliable as a "best time to call" signal either way (answer rate by hour is flat, p = 0.25).
Payments and digital events have no timezone column, so I treat them as IST and say so in the DQ report.
""")

md("### D. Vendor / disposition mapping")
code("""
dv = q("select * from forensics.d_disposition_versions")
print(dv.pivot_table(index="month_start", columns="disposition_version", values="n", aggfunc="sum"))
print(q("select * from forensics.d_disposition_linkage").T)
vr = q("select vendor_name, vendor_status, count(*) vendors, sum(calls) calls, sum(calls*answer_rate)/sum(calls) answer_rate from forensics.d_vendor_answer_rate group by 1,2 order by 1,2")
vr
""")
md("""
**Fact:** disposition versions (`legacy`, `v1`, `v2`) are used side by side in every month, in roughly equal shares,
so there is no cut-over date where definitions changed. But the two code sets `PTP` and `PROMISE_TO_PAY` mean the same
thing; a report that counts only one of them under-counts PTPs by half. I merge them.

**Fact (important):** a disposition's `account_id` matches the account on its parent call 0.0% of the time, its agent
0.09% of the time, and its timestamp is within a day of the call 0.9% of the time. The `call_id` link is not usable. Any
metric that joins dispositions to calls to get "contact -> outcome" is built on a broken key. I therefore use
dispositions only on their own `account_id` and never as a conversion funnel.

Vendors: answer rate ranges 19.3% - 21.1% across 15 vendor ids; the only significant grouping is by vendor name
(p = 0.04, Knowlarity 20.7% vs about 19.6% for the rest) which is **Correlation**, not strong, and not significant
after correcting for the five name groups tested.
""")

md("### E. Agent identity")
code("q('select * from forensics.e_agent_identity').T")
md("""
**Fact:** `agents.csv` has 30,000 rows but only 1,000 distinct `agent_id`. Each id has about 30 conflicting profiles
(different employee code, name, vendor, team, join date). Employee codes (1,099 distinct) map to many agent ids,
so neither key is a clean entity key. The calls table references `agent_id` (100% of non-null values exist), so I use it as
the key and take the latest profile. The practical consequence: **tenure, team and vendor-of-agent are not reliable**,
and I do not draw conclusions from them.

Also: only 1.4% of calls fall inside a logged agent session. The sessions table covers 15,000 sessions
(78,871 hours) so "recovery per agent-hour" cannot be built from it with any confidence.
""")

md("### F. Portfolio mix")
code("""
fm = q("select * from forensics.f_mix_summary")
fm.round(3)
""")
code("""
# test: is the DPD mix of targeted accounts different in Apr-Jul from Jan-Mar?
t = q("select date_trunc('month', t.target_date)::date m, a.dpd_bucket from clean.daily_targeting t join clean.accounts a using(account_id) where t.target_date < '2026-08-01'")
t["period"] = np.where(t.m < pd.Timestamp("2026-04-01"), "Jan-Mar", "Apr-Jul")
ct = pd.crosstab(t.period, t.dpd_bucket)
print((ct.div(ct.sum(1), axis=0)).round(3))
print("chi-square p =", round(stats.chi2_contingency(ct)[1], 3))
""")
md("""
**Fact:** the book is a fixed set of 30,000 accounts opened between Jan 2024 and Nov 2025. Nothing was acquired during the
8 months, and DPD, risk segment and outstanding are single snapshots per account. The DPD mix of the accounts being worked does not
change between periods (share 61+ DPD is 35-38% every month, chi-square p = 0.35 for Jan-Mar vs Apr-Jul). **There is no evidence of a portfolio
change that could explain an improvement.** (Limit: DPD is a snapshot, so I cannot see accounts roll between buckets.)
""")

md("### G. Denominator manipulation")
code("""
g = q("select * from forensics.g_denominator")
g[["month_start","accounts_called","accounts_targeted","accounts_paid","pay_rate_full_book","pay_rate_called_only","pay_rate_targeted_only"]].round(4)
""")
code("""
print(q("select * from forensics.g_closed_still_worked"))
print(q("select * from forensics.g_status_history_check").T)
""")
md("""
Rates computed on three different denominators (full book, called accounts, targeted accounts) all peak in March and
fall back after. The full book rate is the stable choice. Choosing "accounts called" as denominator makes Mar
look like +18.7% vs Feb (0.0856 vs 0.0721) because the Feb dip is on a smaller called base; that is the kind of
denominator choice that can produce a headline. **Hypothesis** only: I cannot show anybody did this.

**Fact:** accounts whose snapshot status is PAID / CLOSED / WRITEOFF still receive about 75% of targeting rows, and the
share is the same every month, so unsuccessful accounts are not disappearing from the population over time. The status
history cannot rebuild a denominator: its latest status matches the account snapshot 14% of the time. If the two were
unrelated the match rate would be 1/7 = 14.3% (the snapshot has 4 statuses, the history 7, all roughly equally likely),
so there is no relationship, and 40% of entries were recorded before the event they describe.
""")

md("""
## 4. Statistical investigation

### 4.1 Feb -> Mar bridge: calendar, volume, ticket size
""")
code("""
b = q("select * from analysis.recovery_bridge")
b.round(4)
""")
code("""
f, mr = b.iloc[1], b.iloc[2]
total = mr.recovery_clean / f.recovery_clean - 1
days_part = mr.days / f.days - 1
vol_part = mr.payments_per_day / f.payments_per_day - 1
tick_part = mr.avg_ticket / f.avg_ticket - 1
print(f"total +{total:.2%} = days x payments/day x ticket = (1{days_part:+.2%}) x (1{vol_part:+.2%}) x (1{tick_part:+.2%})")
print("check:", round((1+days_part)*(1+vol_part)*(1+tick_part)-1, 4))
""")
md("""
**Fact:** +11.0% = +10.7% (days) x +0.5% (payments per day) x -0.2% (average ticket). Essentially all of it is the calendar.
""")

md("### 4.2 Mix effects (shift-share on worked accounts, Feb -> Mar)")
code("""
mx = q("select * from analysis.mix_decomposition")
print(mx.round(3).to_string())
print(mx[["mix_effect","rate_effect","interaction"]].sum().round(3))
""")
md("""
The mix effect is about 0.06 Rs per account-day against a rate effect of about 17, so mix is not the driver. The rate effect
that exists is just noise: it is positive in three DPD buckets and negative in two (see Simpson check next).
""")

md("### 4.3 Simpson's paradox check")
code("""
s = q("select * from analysis.simpson_check")
s["change_%"] = (s.change*100).round(1)
s[["dimension","segment","rec_per_acct_day_feb","rec_per_acct_day_mar","change_%"]].round(1)
""")
md("""
Overall per-day recovery per account moved +0.3%. Inside segments the sign flips back and forth: DPD 1-30 +10.9%,
DPD 91+ -9.1%, MEDIUM risk -6.1%, HIGH risk +4.5%. Segment-level swings of +/-10% with no pattern, around a flat total, is the
signature of sampling noise (each segment has only a few hundred payments a month), not of a hidden reversal.
There is no Simpson reversal in the sense of the total moving one way and every segment the other; but it is an
important warning: a dashboard slicing by DPD would find a "+10.9% improvement" in DPD 1-30 and a "-9.1% deterioration"
in DPD 91+ in the same month.
""")
code("""
# how much segment-level movement would pure chance produce? permute month labels at account-month level
am = q("select account_id, month_start, dpd_bucket, recovered from golden.account_month where month_start in ('2026-02-01','2026-03-01')")
am["rpd"] = am.recovered / np.where(am.month_start == pd.Timestamp("2026-02-01"), 28, 31)
obs = am.pivot_table(index="dpd_bucket", columns="month_start", values="rpd", aggfunc="mean")
obs_chg = (obs.iloc[:,1]/obs.iloc[:,0]-1)
sims = []
for _ in range(500):
    a2 = am.copy(); a2["g"] = rng.permutation(a2.month_start.values)
    p = a2.pivot_table(index="dpd_bucket", columns="g", values="rpd", aggfunc="mean")
    sims.append((p.iloc[:,1]/p.iloc[:,0]-1).values)
sims = np.array(sims)
print("observed segment changes:", (obs_chg*100).round(1).to_dict())
print("95% range under 'no real change':", np.percentile(sims, [2.5, 97.5], axis=0).round(3).T*100)
""")
md("Every observed segment swing falls inside the range that random reshuffling of months produces, so none is evidence of a real change.")

md("### 4.4 Cohort, selection and survivorship")
code("""
print(q("select * from analysis.cohort_by_open_month").round(4).to_string())
sel = q('''select n_targeted>0 as targeted, count(*) n, avg((recovered>0)::int) pay_rate, avg(recovered) rec
           from golden.account_month where not is_partial_month group by 1''')
print(sel)
""")
md("""
**Cohort effects:** accounts opened between 2024 and Nov 2025 all pay at 7.4-7.9% per month. No vintage is better or worse, and all vintages were
open before the window, so no new cohort entered. **Fact.**

**Selection bias:** targeted account-months pay at 7.9% vs 7.7% for non-targeted. The gap is 0.2pp and not significant
(see DiD below). Accounts that were targeted before April look the same as the rest on DPD, outstanding, principal,
risk segment, loan type and time zone (all p above 0.3). Between the DiD treated and control groups, DPD, outstanding and
risk segment are balanced (p = 0.70 / 0.43) but loan-type mix differs (p = 0.008), so loan type is controlled for in the DiD
regression. Nothing suggests the targeting picks better accounts.

**Survivorship bias:** the risk is in PTP and complaint tables, where only closed items can be judged. Reported
"kept rate" of 24-25% is measured on all PTPs including open ones; on payment-validated matured PTPs it is 2-4%.
""")

md("""
## 5. Independent metric definitions

### 5.1 Table of definitions
| Metric | Common definition | My definition | Why |
|---|---|---|---|
| Contact rate | answered calls / calls (raw, duplicates included) | accounts with at least one effective touch (any channel) / accounts attempted, per month | Counts people, not dial attempts; works across channels; removes the 1,350 duplicate call rows |
| RPC | any disposition | dispositions other than NO_CONTACT / WRONG_NUMBER, on the disposition's own account | The call_id link to calls is broken (0% account match), so no call-level RPC |
| PTP rate | PTPs / calls | PTPs / RPC accounts | Denominator is people reached |
| PTP kept rate | status = KEPT / all PTPs | payment-validated: successful payments in [PTP date, promised date + 2d] >= 80% of promised, among matured PTPs only | Status field does not reconcile with money (5.4) |
| Recovery rate | recovered / outstanding, monthly | recovery per calendar day x 30 / total outstanding | Removes month length |
| Recovery per account | recovery / accounts paid | recovery / all accounts in book | Dividing by payers hides non-payers |
| Recovery per agent-hour | recovery / login hours | not reported | Sessions cover 1.4% of calls |
| Cost per Rs recovered | n/a | not computable: no cost data supplied | Needs agent cost, vendor cost, message cost |
| Channel conversion | payments credited to last touch | share of effective touches followed by a successful payment within 7 days, vs same-week no-touch baseline | Compares with a baseline, so credit is incremental |
""")

md("### 5.2 Can anything predict who pays?")
code("""
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import cross_val_score, GroupKFold
am = q("select * from golden.account_month where not is_partial_month order by account_id, month_start")
am["paid"] = (am.recovered > 0).astype(int)
am["prev_paid"] = am.groupby("account_id").paid.shift(1)
x = am.dropna(subset=["prev_paid"]).copy()
feat = ["dpd","outstanding_amount","principal_amount","n_calls","n_answered","n_wa_eff","n_sms_eff","n_field_eff","n_targeted","prev_paid"]
X = pd.concat([x[feat], pd.get_dummies(x[["loan_type","risk_segment","account_timezone"]], drop_first=True)], axis=1).astype(float)
auc = cross_val_score(GradientBoostingClassifier(n_estimators=100, max_depth=3, random_state=42), X, x.paid,
                      groups=x.account_id, cv=GroupKFold(4), scoring="roc_auc")
print("AUC predicting next month payment from every available feature (grouped CV):", auc.round(3), "mean", auc.mean().round(3))
print(x.groupby("prev_paid").paid.agg(["mean","size"]).round(4))
""")
md("""
**Strong evidence:** with every field available (DPD, risk segment, loan type, outstanding, contact history, prior payment) a
gradient boosting model reaches AUC about 0.50, i.e. coin-flip. Having paid last month does not predict paying this month (7.4% vs 7.7%).
The data contains no usable signal for borrower targeting, which matters for section 7.
""")

md("### 5.3 Do contacts cause payments? (touch lift, weekly)")
code("""
tl = q("select * from analysis.touch_lift_weekly")
tl["diff_pp"] = (tl.pay_rate_exposed - tl.pay_rate_unexposed)*100
se = np.sqrt(tl.pay_rate_exposed*(1-tl.pay_rate_exposed)/tl.exposed_account_weeks + tl.pay_rate_unexposed*(1-tl.pay_rate_unexposed)/tl.unexposed_account_weeks)*100
tl["ci_low_pp"] = tl.diff_pp - 1.96*se; tl["ci_high_pp"] = tl.diff_pp + 1.96*se
tl.round(4)
""")
md("""
Account-weeks following an effective touch pay at 1.80% vs 1.85% without (any channel): difference -0.05pp, 95% interval
-0.15pp to +0.05pp. No channel shows a positive effect; voice is exactly zero. **Strong evidence** (several channels, same answer) that
in this data touches are not associated with payments. Combined with B above (attribution share grows linearly with window)
this means "channel conversion" as normally reported (payments after contact / contacts) is just the base rate of paying: 1.6-1.9% in 7 days for every channel, equal to the
no-touch rate.

**Caveat (Hypothesis):** real-world effects are likely non-zero. This looks like data where interaction logs
and payments were generated without a link, or where the join keys (see D) are broken. Either way, the data cannot
be used to claim a channel works.
""")

md("### 5.4 PTP kept rate")
code("""
pv = q("select status_reported, is_matured, count(*) n, avg(kept_by_payment::int) kept_by_payment from metrics.ptp_validated group by 1,2 order by 1,2")
pv.round(4)
""")
md("""
Reported statuses are about 25% each of KEPT / BROKEN / CANCELLED / OPEN in every month. Among matured PTPs, those
marked KEPT are paid in 3.5% of cases, those marked BROKEN 2.7%: the status is statistically unrelated to payment.
Reported "kept rate" (24-25%) cannot be trusted; the payment-validated rate is 2-4%. **Fact.**
""")

md("""
## 6. Counterfactual: what if the targeting strategy had not changed?

Design details are in `docs/counterfactual_design.md`. The dataset has campaign `strategy_version` (legacy, v1, v2, v3) but no
explicit launch date for a new strategy. Following the brief ("changed targeting midway through the year") I take
**1 April 2026** as the change date, **treated = accounts targeted under v3 at least once from Apr-Jul**,
**control = accounts targeted in Apr-Jul but never under v3**. Pre period = Jan-Mar, post = Apr-Jul.
""")
code("""
p = q("select * from analysis.did_panel")
p["post"] = p.post.astype(int); p["t"] = p.treated
print(p.groupby(["treated","post"]).agg(accounts=("account_id","nunique"), rows=("paid","size"), pay_rate=("paid","mean"), rec=("recovered","mean")).round(4))
cl = p.account_id.astype("category").cat.codes
m1 = smf.ols("paid ~ t*post", data=p).fit(cov_type="cluster", cov_kwds={"groups": cl})
m2 = smf.ols("recovered ~ t*post + C(dpd_bucket)+C(risk_segment)+C(loan_type)", data=p).fit(cov_type="cluster", cov_kwds={"groups": cl})
for name, m, k in [("pay rate (pp)", m1, 100), ("recovery per account-month (Rs)", m2, 1)]:
    ci = m.conf_int().loc["t:post"]
    print(f"DiD effect on {name}: {m.params['t:post']*k:+.3f}   95% CI [{ci[0]*k:+.3f}, {ci[1]*k:+.3f}]   p = {m.pvalues['t:post']:.2f}")
""")
code("""
# parallel trends: event study. Interact treatment with each month relative to Mar (last pre month).
p["mo"] = p.month_start.dt.month
ev = smf.ols("paid ~ t*C(mo, Treatment(reference=3))", data=p).fit(cov_type="cluster", cov_kwds={"groups": cl})
rows = [(k, v, ev.pvalues[k]) for k, v in ev.params.items() if k.startswith("t:")]
pd.DataFrame(rows, columns=["term", "treated_minus_control_vs_March", "p"]).round(4)
""")
code("""
# counterfactual recovery for the treated group in Apr-Jul: what it would have been without the change
tr = p[(p.treated == 1) & (p.post == 1)]
actual = tr.recovered.sum()
eff, ci = m2.params["t:post"], m2.conf_int().loc["t:post"]
cf = actual - eff*len(tr)
print(f"Actual recovery, treated group, Apr-Jul:        Rs {actual/1e7:8.2f} Cr")
print(f"Counterfactual (no change), point estimate:     Rs {cf/1e7:8.2f} Cr   -> effect {(actual-cf)/1e7:+.2f} Cr")
print(f"Effect range (95% CI):                          Rs {ci[0]*len(tr)/1e7:+.2f} Cr to {ci[1]*len(tr)/1e7:+.2f} Cr  ({ci[0]/tr.recovered.mean()*100:+.1f}% to {ci[1]/tr.recovered.mean()*100:+.1f}% of treated recovery)")
""")
md("""
**Result:** the DiD effect of the targeting change on recovery is statistically zero. Pay rate effect about -0.16pp
(CI -0.8pp to +0.5pp); recovery per account-month +Rs 61 (CI -533 to +655 on a base of about Rs 6,000, i.e. roughly
-9% to +11%). The data **cannot rule out** a 10% gain or a 10% loss, which is exactly what I report: the answer to
"what would recovery have looked like?" is "the same, within +/- 10%".
Event-study: pre-period (Jan, Feb) treated-control gaps are noisy (Jan -1.2pp with p = 0.05, Feb about 0), so parallel trends is only
partly supported (**Limitation**). Full assumptions and threats are in the design document.
""")

md("""
## 7. Where should the Rs 10 Cr go?

### 7.1 What would each lever have to deliver?
""")
code("""
total_cr = q("select sum(amount) v from golden.fact_payment where is_recovery and pay_date < '2026-08-01'").v[0] / 1e7
base_cr = total_cr / 212 * 365
book_cr = q("select sum(outstanding_amount) v from clean.accounts").v[0] / 1e7
print(f"Annualised recovery run-rate (212 days Jan-Jul): Rs {base_cr:,.0f} Cr   (outstanding book Rs {book_cr:,.0f} Cr)")
spend = 10.0
print(f"Break-even in 12 months needs +Rs {spend:.0f} Cr = +{spend/base_cr:.1%} on annual recovery")
""")
code("""
# Best case for any CONTACT-based lever (telephony, more agents, AI voice, WhatsApp/digital, field):
# take the 95% UPPER limit of the touch lift and assume every account-week that is not touched today
# becomes touched, at zero cost. That is a ceiling, not a forecast.
r = tl[tl.channel == "ANY"].iloc[0]
avg_ticket = q("select avg(amount) v from golden.fact_payment where is_recovery").v[0]
weeks_in_panel = 28
extra_payers_per_week = (r.unexposed_account_weeks / weeks_in_panel) * (r.ci_high_pp / 100)
ceiling_cr = extra_payers_per_week * 52 * avg_ticket / 1e7
print(f"Touch lift, any channel: {r.diff_pp:+.3f}pp, 95% CI {r.ci_low_pp:+.3f}pp to {r.ci_high_pp:+.3f}pp "
      f"(relative upper bound {r.ci_high_pp/(r.pay_rate_unexposed*100):+.1%})")
print(f"Ceiling for contact-based levers: about Rs {ceiling_cr:.1f} Cr per year, against Rs {spend:.0f} Cr cost")
""")
code("""
# The one real strategy change in the data (section 6), scaled from the treated accounts to the whole book for 12 months
ci_lo, ci_hi = m2.conf_int().loc["t:post"]
book_months = 12 * 30000
point, lo, hi = (x * book_months / 1e7 for x in (m2.params["t:post"], ci_lo, ci_hi))
print(f"Targeting-change effect, full book, 12 months: {point:+.1f} Cr   (95% CI {lo:+.1f} to {hi:+.1f} Cr)")
print(f"ROI on Rs {spend:.0f} Cr (gain - cost) / cost: central {(point-spend)/spend:+.0%}, range {(lo-spend)/spend:+.0%} to {(hi-spend)/spend:+.0%}")
print(f"Payback: central {spend/point:.1f} years; at upper bound {12*spend/hi:.0f} months; lower bound never")
""")
code("""
# How big a test is needed? Outcome = account pays at least once in 8 weeks. Weekly base rate from the panel.
from statsmodels.stats.power import NormalIndPower
p1 = 1 - (1 - tl[tl.channel == "ANY"].pay_rate_unexposed.iloc[0]) ** 8
def cohen_h(a, b): return 2*np.arcsin(np.sqrt(b)) - 2*np.arcsin(np.sqrt(a))
pw = NormalIndPower()
h = pw.solve_power(nobs1=15000, alpha=0.05, power=0.8)
p2 = np.sin((h + 2*np.arcsin(np.sqrt(p1))) / 2) ** 2
need_h = cohen_h(p1, p1 * 1.046)
n_need = pw.solve_power(effect_size=need_h, alpha=0.05, power=0.8)
print(f"8-week paid rate in control about {p1:.1%}")
print(f"With 15,000 accounts per arm, smallest detectable lift = {p2-p1:+.2%}pp ({p2/p1-1:+.0%} relative)")
print(f"To detect the break-even lift (+4.6% relative) you need about {n_need:,.0f} accounts per arm, vs 15,000 available")
""")
md("""
### 7.2 Recommendation

**The data does not support committing Rs 10 Cr to any of the six options.** What it does show:

- **Contact-based levers (telephony, more agents, AI voice, WhatsApp/digital, field)**: an effective touch has no measurable
  effect on next-week payment. Even at the 95% upper limit and assuming every untouched account-week became touched at zero cost,
  the ceiling is about Rs 5 Cr a year (printed above), half of the spend. They cannot break even on this evidence.
- **Borrower targeting**: the only lever whose range includes a return above cost (upper bound +Rs 23.6 Cr a year), but the
  central estimate is +Rs 2.2 Cr, the range runs down to -Rs 19 Cr, and no available field predicts payment (AUC 0.50).
- **Costs are not in the data** (agent, vendor, message cost), so channel ROI cannot be computed, only break-even.

**If leadership must name one: better borrower targeting, released in tranches** (Rs 1 Cr now, balance only if a randomised
test clears break-even). Reasons: it is the only option with an upper range above cost, it has no variable cost per contact,
and it can be switched off. I rate confidence **low**.

| Item | Value |
|---|---|
| Expected incremental recovery (central) | +Rs 2.2 Cr per year |
| 95% range | -Rs 19.2 Cr to +Rs 23.6 Cr per year |
| Estimated cost | Rs 10 Cr (assumed all upfront; Rs 1 Cr in tranche 1) |
| Expected ROI, (gain - cost) / cost | central -78%, range -292% to +136% |
| Break-even | +Rs 10 Cr a year = +4.6% of recovery. Payback 4.6 years at the central estimate, about 5 months at the upper bound, never at the lower bound |
| Downside | effect of -Rs 19 Cr a year on top of the spend; staging caps the first exposure at Rs 1 Cr |
| Key assumptions | the 2026 targeting change is a fair proxy for what the investment buys; effect measured on treated accounts applies to the whole book; benefit counted as recovered rupees with no cost-to-collect; no change in complaints |
| Confidence | Low |

**Experiment needed before releasing the balance:** randomise accounts 50/50 between current strategy and the new targeting,
hold for at least 8 weeks, measure payment-validated outcomes, and record cost per touch by channel. The printed power
calculation shows the book (30,000 accounts) is too small to detect a break-even-sized lift in 8 weeks with one outcome per
account, so either run longer, use account-week outcomes, or accept that only a larger lift (about the printed minimum detectable
lift) can be proven.
""")

nb = nbf.v4.new_notebook()
nb["cells"] = cells
nb["metadata"]["kernelspec"] = {"display_name": "Python 3", "language": "python", "name": "python3"}
out = ROOT / "notebooks" / "collections_analysis.ipynb"
NotebookClient(nb, timeout=600, kernel_name="python3", resources={"metadata": {"path": str(ROOT / "notebooks")}}).execute()
nbf.write(nb, out)
print("wrote", out)
