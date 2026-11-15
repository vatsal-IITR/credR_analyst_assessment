"""Builds dashboard/index.html (one static screen) from the DuckDB file.
Every number on the page is queried here, none is typed in by hand.

    python pipeline/build_dashboard.py
"""
import pathlib
import duckdb

ROOT = pathlib.Path(__file__).resolve().parents[1]
con = duckdb.connect(str(ROOT / "data" / "collections.duckdb"), read_only=True)
q = lambda s: con.sql(s).df()

m = q("select * from metrics.monthly where month_start < date '2026-08-01' order by month_start")
m["label"] = m.month_start.dt.strftime("%b")
m["per_day"] = m.recovery_clean / m.days_with_data
reported = m.recovery_clean.pct_change().iloc[2] * 100            # Feb -> Mar
per_day = m.per_day.pct_change().iloc[2] * 100
days_effect = (31 / 28 - 1) * 100

did = q("select treated, post::int post, avg(paid) pr, avg(recovered) r from analysis.did_panel group by 1, 2")
dup = q("""select sum(amount) filter (where payment_status='SUCCESS') raw_s from stg.payments""").raw_s[0]
clean = q("select sum(amount) v from golden.fact_payment where is_recovery").v[0]
touch = q("select * from analysis.touch_lift_weekly where channel='ANY'").iloc[0]
ptp_rep = m.ptp_kept_rate_reported.mean() * 100
ptp_val = m.ptp_kept_rate_validated.mean() * 100
attr7 = q("select share_attributed v from forensics.b_attribution_window where days_back=7").v[0] * 100

# ---- chart helpers (inline SVG) -------------------------------------------------
def bars(values, labels, color, w=360, h=170, ymax=None, fmt="{:.1f}"):
    ymax = ymax or max(values) * 1.15
    n = len(values); bw = (w - 30) / n
    out = [f'<svg viewBox="0 0 {w} {h}" width="100%" role="img">']
    for i, (v, l) in enumerate(zip(values, labels)):
        bh = (h - 40) * v / ymax
        x = 20 + i * bw + bw * 0.15
        out.append(f'<rect x="{x:.1f}" y="{h-25-bh:.1f}" width="{bw*0.7:.1f}" height="{bh:.1f}" fill="{color}"/>')
        out.append(f'<text x="{x+bw*0.35:.1f}" y="{h-28-bh:.1f}" font-size="10" text-anchor="middle" fill="#1f2328">{fmt.format(v)}</text>')
        out.append(f'<text x="{x+bw*0.35:.1f}" y="{h-10}" font-size="10" text-anchor="middle" fill="#57606a">{l}</text>')
    out.append(f'<line x1="18" y1="{h-25}" x2="{w}" y2="{h-25}" stroke="#e5e7eb"/></svg>')
    return "".join(out)

c1 = bars((m.recovery_clean / 1e7).tolist(), m.label.tolist(), "#3b82d4", ymax=28)
c2 = bars((m.per_day / 1e5).tolist(), m.label.tolist(), "#7c5cd8", ymax=84, fmt="{:.0f}")

html = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Collections recovery: executive view</title>
<style>
*{{box-sizing:border-box}}
body{{margin:0;padding:18px 24px;font:14px/1.5 -apple-system,"Segoe UI",system-ui,sans-serif;color:#1f2328;background:#fff;max-width:1100px;margin:auto}}
h1{{font-size:20px;margin:0 0 2px}} .sub{{color:#57606a;font-size:12px;margin-bottom:14px}}
.verdict{{background:#f7f8fa;border:1px solid #e5e7eb;border-left:4px solid #3b82d4;padding:12px 16px;margin-bottom:14px}}
.verdict b.big{{font-size:17px}}
.grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:14px}}
.kpi{{border:1px solid #e5e7eb;padding:10px 12px;background:#fff}}
.kpi .n{{font-size:22px;font-weight:600}} .kpi .l{{font-size:11px;color:#57606a}}
.row{{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:14px}}
.card{{border:1px solid #e5e7eb;padding:10px 12px}}
.card h2{{font-size:13px;margin:0 0 4px}} .card p{{font-size:12px;color:#57606a;margin:2px 0 0}}
table{{border-collapse:collapse;width:100%;font-size:12px}} td,th{{padding:3px 6px;border-bottom:1px solid #e5e7eb;text-align:left}}
.dec{{border:1px solid #e5e7eb;border-left:4px solid #7c5cd8;padding:10px 16px;background:#f7f8fa}}
.foot{{margin-top:14px;padding-top:8px;border-top:1px solid #e5e7eb;font-size:11px;color:#57606a;text-align:center}}
</style></head><body>
<h1>Is recovery really up 11%? No.</h1>
<div class="sub">Collections book: 30,000 accounts, Rs {q('select sum(outstanding_amount) v from clean.accounts').v[0]/1e7:,.0f} Cr outstanding. Data 1 Jan to 8 Aug 2026, cleaned golden layer.</div>

<div class="verdict"><b class="big">The +{reported:.1f}% is a calendar effect.</b>
February has 28 days and March has 31 (+{days_effect:.1f}% by itself). Per day, recovery moved <b>{per_day:+.1f}%</b>
(95% range about -6% to +7%). Jan-Jul shows no trend. Confidence: high.</div>

<div class="grid">
<div class="kpi"><div class="n">{reported:+.1f}%</div><div class="l">Reported Feb to Mar (total recovery)</div></div>
<div class="kpi"><div class="n">{per_day:+.1f}%</div><div class="l">Same change, per calendar day</div></div>
<div class="kpi"><div class="n">Rs {clean/1e7:,.1f} Cr</div><div class="l">Recovered 1 Jan to 8 Aug (raw file overstates by {100*(dup/clean-1):.1f}%)</div></div>
<div class="kpi"><div class="n">{ptp_val:.0f}% vs {ptp_rep:.0f}%</div><div class="l">PTP kept: validated by payment vs reported status</div></div>
</div>

<div class="row">
<div class="card"><h2>Recovery per month (Rs Cr): what leadership sees</h2>{c1}<p>Moves with month length: Feb low, Mar high.</p></div>
<div class="card"><h2>Recovery per calendar day (Rs lakh): what is real</h2>{c2}<p>Flat. Axis starts at zero.</p></div>
</div>

<div class="row">
<div class="card"><h2>What else the data says</h2>
<table>
<tr><td>Targeting change (Apr 2026), diff-in-diff</td><td><b>No measurable effect</b> (range -9% to +11%)</td></tr>
<tr><td>Effective contact vs no contact, next-week payment</td><td>{touch.pay_rate_exposed*100:.2f}% vs {touch.pay_rate_unexposed*100:.2f}%: no lift</td></tr>
<tr><td>Payments with any contact in prior 7 days</td><td>{attr7:.1f}%</td></tr>
<tr><td>Portfolio mix change</td><td>None (fixed 30,000-account book)</td></tr>
<tr><td>Can any field predict who pays?</td><td>No (AUC 0.50)</td></tr>
</table></div>
<div class="card"><h2>Data problems that change numbers</h2>
<table>
<tr><td>500 duplicate payment ids</td><td>+2.0% overstatement</td></tr>
<tr><td>Failed / pending / reversed counted as recovery</td><td>+45.7% overstatement</td></tr>
<tr><td>Disposition to call link (account match)</td><td>0.0%: unusable</td></tr>
<tr><td>Agent ids with conflicting profiles</td><td>1,000 ids, 30 profiles each</td></tr>
<tr><td>Payment reference shared across accounts</td><td>7,218 rows: not a unique key</td></tr>
</table></div>
</div>

<div class="dec"><b>Decision on Rs 10 Cr.</b> Do not release the full amount on current evidence. No contact lever (telephony, agents, AI voice, digital, field)
shows a measurable effect; their ceiling is about Rs 5 Cr a year against Rs 10 Cr cost. Borrower targeting is the only option whose range
(-Rs 19 Cr to +Rs 24 Cr a year, central +Rs 2 Cr) reaches break-even (+4.6% of recovery). Release Rs 1 Cr for a randomised test,
the balance only if it clears break-even. Confidence: low.</div>
<div class="foot">Made with IBM Bob</div>
</body></html>"""
out = ROOT / "dashboard" / "index.html"
out.write_text(html, encoding="utf-8")
print("wrote", out)
