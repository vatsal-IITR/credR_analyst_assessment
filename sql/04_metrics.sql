-- 04_metrics.sql
-- Independent metric definitions. Each metric has a "reported-style" version (what a naive dashboard would do)
-- and an "independent" version (what I defend). The reasons are in docs/metric_definitions.md.
--
-- metrics.monthly         one row per month, every headline metric
-- metrics.ptp_validated   each PTP with payment-based keep test
-- metrics.channel_touch   7-day conversion after an effective touch, per channel

create schema if not exists metrics;

-- ---------------------------------------------------------------------------
-- PTP validation: kept = successful payments on the account between PTP creation and promised_date + 2 days
-- that add up to at least 80% of the promised amount. Only PTPs whose window has closed are "matured".
-- ---------------------------------------------------------------------------
create or replace table metrics.ptp_validated as
select x.*,
       (x.promised_date + interval 2 day) <= timestamp '2026-08-09' as is_matured,
       x.paid_in_window >= 0.8 * x.promised_amount                  as kept_by_payment
from (
    select p.ptp_id, p.account_id, p.event_at, p.promised_amount, p.promised_date, p.status_reported, p.source,
           coalesce(sum(f.amount), 0) as paid_in_window
    from clean.promises_to_pay p
    left join golden.fact_payment f
      on f.account_id = p.account_id and f.is_recovery
     and f.event_ist >= p.event_at and f.event_ist <= p.promised_date + interval 2 day
    group by p.ptp_id, p.account_id, p.event_at, p.promised_amount, p.promised_date, p.status_reported, p.source
) x;

-- ---------------------------------------------------------------------------
-- Channel conversion: for every effective touch, did the same account pay (SUCCESS) within 7 days?
-- ---------------------------------------------------------------------------
create or replace table metrics.channel_touch as
select c.touch_id, c.channel, c.account_id, c.event_ist,
       date_trunc('month', c.event_ist)::date as month_start,
       exists (select 1 from golden.fact_payment p
               where p.account_id = c.account_id and p.is_recovery
                 and p.event_ist > c.event_ist and p.event_ist <= c.event_ist + interval 7 day) as paid_within_7d
from golden.fact_contact c
where c.is_effective
  and c.event_ist < timestamp '2026-08-02';   -- need a full 7 day follow-up window inside the data

-- ---------------------------------------------------------------------------
-- Monthly metrics
-- ---------------------------------------------------------------------------
create or replace table metrics.monthly as
with days as (
    select date_trunc('month', pay_date)::date as month_start, count(distinct pay_date) as days_with_data
    from golden.fact_payment group by 1
),
pay as (
    select pay_month as month_start,
           sum(amount) filter (where is_recovery)                      as recovery_clean,
           count(*)    filter (where is_recovery)                      as n_success,
           count(distinct account_id) filter (where is_recovery)       as accounts_paid
    from golden.fact_payment group by 1
),
raw_pay as (   -- what a report built straight on the raw payments file would show
    select date_trunc('month', event_at)::date as month_start,
           sum(amount) filter (where payment_status = 'SUCCESS')       as recovery_raw_success,
           sum(amount)                                                 as recovery_raw_all_statuses
    from stg.payments group by 1
),
calls as (
    select date_trunc('month', event_ist)::date as month_start,
           count(*) as calls, count(*) filter (where is_effective) as answered,
           count(distinct account_id) as accounts_called,
           count(distinct account_id) filter (where is_effective) as accounts_answered
    from golden.fact_contact where channel = 'VOICE' group by 1
),
raw_calls as (
    select date_trunc('month', event_at)::date as month_start,
           count(*) as raw_calls, count(*) filter (where call_status = 'ANSWERED') as raw_answered
    from stg.calls group by 1
),
reach as (   -- any effective touch on any channel
    select date_trunc('month', event_ist)::date as month_start,
           count(distinct account_id) as accounts_attempted,
           count(distinct account_id) filter (where is_effective) as accounts_reached
    from golden.fact_contact group by 1
),
disp as (
    select date_trunc('month', event_at)::date as month_start,
           count(*) as dispositions,
           count(*) filter (where disposition_code not in ('NO_CONTACT', 'WRONG_NUMBER')) as rpc_dispositions,
           count(distinct account_id) filter (where disposition_code not in ('NO_CONTACT', 'WRONG_NUMBER')) as rpc_accounts
    from clean.call_dispositions group by 1
),
ptp as (
    select date_trunc('month', event_at)::date as month_start,
           count(*) as ptps,
           count(*) filter (where status_reported = 'KEPT') as ptp_kept_reported,
           count(*) filter (where is_matured) as ptp_matured,
           count(*) filter (where is_matured and kept_by_payment) as ptp_kept_validated
    from metrics.ptp_validated group by 1
),
sess as (
    select date_trunc('month', login_at)::date as month_start, sum(session_hours) as agent_hours
    from clean.agent_sessions group by 1
)
select d.month_start,
       d.days_with_data,
       r.recovery_raw_all_statuses, r.recovery_raw_success, p.recovery_clean,
       p.recovery_clean / d.days_with_data                       as recovery_per_day,
       p.n_success, p.accounts_paid,
       -- Recovery rate: recovered as % of outstanding of the whole book, per day, x 30 so months are comparable
       100.0 * (p.recovery_clean / d.days_with_data) * 30 / (select sum(outstanding_amount) from clean.accounts) as recovery_rate_pct_30d,
       p.recovery_clean / (select count(*) from clean.accounts) as recovery_per_account,
       p.accounts_paid * 1.0 / (select count(*) from clean.accounts) as account_pay_rate,
       -- Contact rate: reported = answered calls / calls (raw, includes duplicate rows). independent = accounts reached / accounts attempted
       rc.raw_answered * 1.0 / rc.raw_calls                       as contact_rate_reported_style,
       c.answered * 1.0 / c.calls                                 as answer_rate_calls_clean,
       re.accounts_reached * 1.0 / re.accounts_attempted          as contact_rate_account_level,
       dp.rpc_dispositions * 1.0 / dp.dispositions                as rpc_rate,
       pt.ptps * 1.0 / nullif(dp.rpc_accounts, 0)                 as ptp_per_rpc_account,
       pt.ptp_kept_reported * 1.0 / pt.ptps                       as ptp_kept_rate_reported,
       pt.ptp_kept_validated * 1.0 / nullif(pt.ptp_matured, 0)    as ptp_kept_rate_validated,
       s.agent_hours,
       p.recovery_clean / s.agent_hours                           as recovery_per_agent_hour
from days d
left join pay p using (month_start)
left join raw_pay r using (month_start)
left join calls c using (month_start)
left join raw_calls rc using (month_start)
left join reach re using (month_start)
left join disp dp using (month_start)
left join ptp pt using (month_start)
left join sess s using (month_start)
order by d.month_start;
