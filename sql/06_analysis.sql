-- 06_analysis.sql
-- Statistical-investigation tables (Part 3) and the counterfactual panel (Part 4).
--
--   analysis.recovery_bridge      Feb -> Mar bridge: how much of the +11% is days-in-month vs volume vs ticket size
--   analysis.mix_decomposition    mix vs rate effect by DPD bucket (shift-share)
--   analysis.simpson_check        overall vs within-segment direction of change
--   analysis.cohort_by_open_month recovery by account vintage
--   analysis.touch_lift_weekly    next-week payment rate after an effective touch, by channel
--   analysis.did_panel            account x month panel for the targeting difference-in-differences

create schema if not exists analysis;

-- ---------------------------------------------------------------------------
-- Bridge: recovery = days x payments_per_day x average_ticket
-- ---------------------------------------------------------------------------
create or replace table analysis.recovery_bridge as
select month_start, days_with_data as days,
       n_success * 1.0 / days_with_data       as payments_per_day,
       recovery_clean / n_success             as avg_ticket,
       recovery_clean,
       recovery_clean / lag(recovery_clean) over (order by month_start) - 1                       as mom_total,
       recovery_per_day / lag(recovery_per_day) over (order by month_start) - 1                   as mom_per_day,
       days_with_data * 1.0 / lag(days_with_data) over (order by month_start) - 1                 as mom_days_effect
from metrics.monthly
where month_start < date '2026-08-01'   -- August has 8 days of data, so it is not comparable
order by month_start;

-- ---------------------------------------------------------------------------
-- Shift-share by DPD bucket for Feb -> Mar, on the accounts that were actually WORKED in the month
-- (targeted or called). The full book never changes mix (30,000 accounts, one DPD snapshot) so a mix
-- effect on the full book is zero by construction; the question only makes sense for the worked population.
-- Mix effect = change in share of worked accounts in the bucket.
-- Rate effect = change in recovery per worked account per day inside the bucket.
-- ---------------------------------------------------------------------------
create or replace table analysis.mix_decomposition as
with b as (
    select month_start, dpd_bucket, count(*) as accts, sum(recovered) / max(days_observed) as rec_per_day
    from golden.account_month
    where month_start in (date '2026-02-01', date '2026-03-01') and (n_targeted > 0 or n_calls > 0)
    group by all
),
w as (
    select b.*, accts * 1.0 / sum(accts) over (partition by month_start) as share,
           rec_per_day / accts as rpd_per_acct
    from b
),
pair as (
    select a.dpd_bucket,
           a.share as share_feb, c.share as share_mar,
           a.rpd_per_acct as rate_feb, c.rpd_per_acct as rate_mar
    from w a join w c on a.dpd_bucket = c.dpd_bucket and a.month_start = date '2026-02-01' and c.month_start = date '2026-03-01'
)
select dpd_bucket, share_feb, share_mar, rate_feb, rate_mar,
       (share_mar - share_feb) * rate_feb         as mix_effect,
       share_feb * (rate_mar - rate_feb)          as rate_effect,
       (share_mar - share_feb) * (rate_mar - rate_feb) as interaction
from pair order by 1;

-- ---------------------------------------------------------------------------
-- Simpson check: is the direction of change Feb -> Mar the same in every segment as in the total?
-- Per-day recovery per account is used so the 28 vs 31 day difference does not drive it.
-- ---------------------------------------------------------------------------
create or replace table analysis.simpson_check as
with seg as (
    select 'dpd_bucket' as dimension, dpd_bucket as segment, month_start, sum(recovered) / max(days_observed) / count(*) as rpd from golden.account_month where month_start in (date '2026-02-01', date '2026-03-01') group by all
    union all
    select 'risk_segment', risk_segment, month_start, sum(recovered) / max(days_observed) / count(*) from golden.account_month where month_start in (date '2026-02-01', date '2026-03-01') group by all
    union all
    select 'loan_type', loan_type, month_start, sum(recovered) / max(days_observed) / count(*) from golden.account_month where month_start in (date '2026-02-01', date '2026-03-01') group by all
    union all
    select 'account_timezone', account_timezone, month_start, sum(recovered) / max(days_observed) / count(*) from golden.account_month where month_start in (date '2026-02-01', date '2026-03-01') group by all
)
select dimension, segment,
       max(rpd) filter (where month_start = date '2026-02-01') as rec_per_acct_day_feb,
       max(rpd) filter (where month_start = date '2026-03-01') as rec_per_acct_day_mar,
       max(rpd) filter (where month_start = date '2026-03-01') / max(rpd) filter (where month_start = date '2026-02-01') - 1 as change
from seg group by 1, 2 order by 1, 2;

-- ---------------------------------------------------------------------------
-- Cohort : accounts by month of opening. Every account was opened before the window (2024-01..2025-11) so
-- all cohorts are fully observed and there is no new-vintage effect inside the 8 months.
-- ---------------------------------------------------------------------------
create or replace table analysis.cohort_by_open_month as
select date_trunc('quarter', a.opened_at)::date as open_quarter, count(distinct a.account_id) as accounts,
       sum(m.recovered) / count(distinct a.account_id) as recovered_per_account_8m,
       avg((m.recovered > 0)::int) as monthly_pay_rate
from clean.accounts a join golden.account_month m using (account_id)
where not m.is_partial_month
group by 1 order by 1;

-- ---------------------------------------------------------------------------
-- Touch lift: weekly panel. exposed = account had an effective touch (any channel) in week t-1
-- outcome = account had a successful payment in week t.
-- ---------------------------------------------------------------------------
create or replace table analysis.touch_lift_weekly as
with weeks as (select unnest(range(0, 29)) as w),
pay as (
    select account_id, cast(date_diff('day', date '2026-01-01', pay_date) / 7 as int) as w
    from golden.fact_payment where is_recovery group by 1, 2
),
touch as (
    select account_id, cast(date_diff('day', date '2026-01-01', cast(event_ist as date)) / 7 as int) as w, channel
    from golden.fact_contact where is_effective group by 1, 2, 3
),
grid as (select a.account_id, k.w from clean.accounts a cross join weeks k),
chan as (select unnest(['VOICE', 'WHATSAPP', 'SMS', 'FIELD', 'ANY']) as channel)
select ch.channel,
       count(*) filter (where e.account_id is not null) as exposed_account_weeks,
       count(*) filter (where e.account_id is null)     as unexposed_account_weeks,
       avg((p.account_id is not null)::int) filter (where e.account_id is not null) as pay_rate_exposed,
       avg((p.account_id is not null)::int) filter (where e.account_id is null)     as pay_rate_unexposed
from grid g
cross join chan ch
left join (select distinct account_id, w + 1 as w, 'ANY' as channel from touch
           union select account_id, w + 1, channel from touch) e
       on e.account_id = g.account_id and e.w = g.w and e.channel = ch.channel
left join pay p on p.account_id = g.account_id and p.w = g.w
where g.w >= 1
group by 1 order by 1;

-- ---------------------------------------------------------------------------
-- DiD panel. The business is assumed to have changed targeting on 2026-04-01 (see docs/counterfactual_design.md).
-- treated = account was targeted under strategy v3 at least once in Apr-Jul
-- control = account was targeted in Apr-Jul but never under v3
-- Pre period = Jan-Mar, post period = Apr-Jul.
-- ---------------------------------------------------------------------------
create or replace table analysis.did_panel as
with grp as (
    select account_id,
           max((strategy_version = 'v3')::int) as treated
    from clean.daily_targeting
    where target_date >= date '2026-04-01' and target_date < date '2026-08-01'
    group by 1
)
select m.account_id, m.month_start, g.treated, (m.month_start >= date '2026-04-01') as post,
       m.recovered, (m.recovered > 0)::int as paid, m.dpd, m.dpd_bucket, m.risk_segment, m.loan_type,
       m.outstanding_amount, m.account_timezone, m.days_observed
from golden.account_month m join grp g using (account_id)
where not m.is_partial_month;
