-- 05_forensics.sql
-- One table per forensic hypothesis (A-G in the brief). Each table answers "does this problem exist and how big is it?"
-- The notebook reads these tables, so the notebook and the SQL can never disagree.

create schema if not exists forensics;

-- ---------------------------------------------------------------------------
-- A. DUPLICATE PAYMENTS
-- ---------------------------------------------------------------------------
create or replace table forensics.a_duplicate_payments as
select date_trunc('month', event_at)::date as month_start,
       count(*)                                                       as raw_rows,
       count(distinct payment_id)                                     as unique_payment_ids,
       count(*) - count(distinct payment_id)                          as duplicate_rows,
       sum(amount) filter (where payment_status = 'SUCCESS')          as raw_success_amt,
       sum(amount) filter (where payment_status = 'SUCCESS' and rn = 1) as dedup_success_amt
from (select *, row_number() over (partition by payment_id order by _src_row) as rn from stg.payments)
group by 1 order by 1;

-- payment_reference is re-used across different accounts: it is NOT a unique transaction id,
-- so de-duplicating on it would delete real money. This table shows the evidence.
create or replace table forensics.a_reference_reuse as
select count(*)                                                  as payment_rows_with_ref,
       count(distinct payment_reference)                         as distinct_refs,
       count(*) filter (where ref_shared)                        as rows_on_shared_ref,
       count(*) filter (where ref_shared and same_account_peer)  as rows_where_peer_has_same_account
from (
    select payment_reference,
           count(*) over (partition by payment_reference) > 1                       as ref_shared,
           count(*) over (partition by payment_reference, account_id) > 1           as same_account_peer
    from clean.payments where payment_reference is not null
);

-- ---------------------------------------------------------------------------
-- B. ATTRIBUTION : how many recovered payments can be linked to any effective touch, by look-back window
-- ---------------------------------------------------------------------------
create or replace table forensics.b_attribution_window as
with w as (select unnest([1, 3, 7, 14, 30]) as days_back),
pay as (select * from golden.fact_payment where is_recovery),
eff as (select * from golden.fact_contact where is_effective)
select w.days_back,
       count(distinct p.payment_id) as payments_with_touch,
       (select count(*) from pay) as payments_total,
       count(distinct p.payment_id) * 1.0 / (select count(*) from pay) as share_attributed
from w
cross join pay p
join eff e on e.account_id = p.account_id and e.event_ist <= p.event_ist
          and e.event_ist >= p.event_ist - to_days(w.days_back)
group by w.days_back order by 1;

create or replace table forensics.b_attribution_channel as
select 'last_touch_7d' as method, coalesce(last_touch_channel_7d, 'NO_TOUCH') as channel, count(*) as payments, sum(amount) as amount
from golden.payment_attribution group by 1, 2
union all
select 'first_touch_7d', coalesce(first_touch_channel_7d, 'NO_TOUCH'), count(*), sum(amount)
from golden.payment_attribution group by 1, 2;

-- ---------------------------------------------------------------------------
-- C. TIMEZONE : what happens to day / hour / month when calls are normalised to IST
-- ---------------------------------------------------------------------------
create or replace table forensics.c_timezone as
select timezone,
       count(*) as calls,
       avg((cast(event_local as date) <> cast(event_ist as date))::int)                 as share_day_changes,
       avg((hour(event_local) <> hour(event_ist))::int)                                 as share_hour_changes,
       avg((date_trunc('month', event_local) <> date_trunc('month', event_ist))::int)   as share_month_changes,
       avg((hour(event_local) < 8 or hour(event_local) >= 20)::int)                     as share_outside_8_20_local,
       avg((hour(event_ist)   < 8 or hour(event_ist)   >= 20)::int)                     as share_outside_8_20_ist
from clean.calls group by 1 order by 1;

-- ---------------------------------------------------------------------------
-- D. VENDOR / DISPOSITION CODE CHANGES
-- ---------------------------------------------------------------------------
create or replace table forensics.d_disposition_versions as
select date_trunc('month', event_at)::date as month_start, disposition_version, disposition_code_raw, count(*) as n
from clean.call_dispositions group by all order by 1, 2, 3;

create or replace table forensics.d_disposition_vs_call as
select d.disposition_code, c.call_status, count(*) as n
from clean.call_dispositions d join clean.calls c using (call_id) group by 1, 2;

create or replace table forensics.d_disposition_linkage as
select count(*)                                              as dispositions_matched_to_call,
       avg((d.account_id = c.account_id)::int)               as account_matches_call,
       avg((d.agent_id   = c.agent_id)::int)                 as agent_matches_call,
       avg((d.event_at between c.event_ist - interval 1 day and c.event_ist + interval 1 day)::int) as within_1_day_of_call
from clean.call_dispositions d join clean.calls c using (call_id);

create or replace table forensics.d_vendor_answer_rate as
select v.vendor_name, v.status as vendor_status, c.vendor_id,
       count(*) as calls, avg(is_effective::int) as answer_rate
from golden.fact_contact c join clean.vendors v on v.vendor_id = c.vendor_id
where c.channel = 'VOICE' group by all order by 1, 3;

-- ---------------------------------------------------------------------------
-- E. AGENT IDENTITY
-- ---------------------------------------------------------------------------
create or replace table forensics.e_agent_identity as
select (select count(*) from stg.agents)                                   as agent_rows,
       (select count(distinct agent_id) from stg.agents)                   as distinct_agent_ids,
       (select count(distinct employee_code) from stg.agents)              as distinct_employee_codes,
       (select avg(n_profile_rows) from golden.dim_agent)                  as avg_profiles_per_agent_id,
       (select avg(n_vendors) from golden.dim_agent)                       as avg_vendors_per_agent_id,
       (select count(*) from clean.calls where agent_id is null)           as calls_without_agent,
       (select count(*) from clean.calls c where agent_id is not null
          and not exists (select 1 from clean.agent_sessions s
                          where s.agent_id = c.agent_id and c.event_ist between s.login_at and s.logout_at)) as calls_outside_any_session,
       (select count(*) from clean.calls where agent_id is not null)       as calls_with_agent;

-- ---------------------------------------------------------------------------
-- F. PORTFOLIO MIX : did the targeted / called book change over time?
-- ---------------------------------------------------------------------------
create or replace table forensics.f_mix_targeted as
select date_trunc('month', t.target_date)::date as month_start, a.dpd_bucket, a.risk_segment, a.loan_type, count(*) as n_targets,
       sum(a.outstanding_amount) as outstanding
from clean.daily_targeting t join clean.accounts a using (account_id)
group by all;

create or replace table forensics.f_mix_summary as
select month_start,
       sum(n_targets)                                                                   as targets,
       sum(n_targets) filter (where dpd_bucket in ('61-90', '91+')) * 1.0 / sum(n_targets) as share_dpd_61_plus,
       sum(n_targets) filter (where risk_segment in ('HIGH', 'NPA')) * 1.0 / sum(n_targets) as share_high_npa,
       sum(outstanding) / sum(n_targets)                                                as avg_outstanding
from forensics.f_mix_targeted group by 1 order by 1;

-- ---------------------------------------------------------------------------
-- G. DENOMINATOR : does the population behind a rate change quietly?
-- ---------------------------------------------------------------------------
create or replace table forensics.g_denominator as
select m.month_start,
       count(*)                                                       as accounts_in_book,
       count(*) filter (where n_calls > 0)                            as accounts_called,
       count(*) filter (where n_targeted > 0)                         as accounts_targeted,
       count(*) filter (where recovered > 0)                          as accounts_paid,
       count(*) filter (where recovered > 0) * 1.0 / count(*)                                       as pay_rate_full_book,
       count(*) filter (where recovered > 0 and n_calls > 0) * 1.0 / nullif(count(*) filter (where n_calls > 0), 0) as pay_rate_called_only,
       count(*) filter (where recovered > 0 and n_targeted > 0) * 1.0 / nullif(count(*) filter (where n_targeted > 0), 0) as pay_rate_targeted_only
from golden.account_month m group by 1 order by 1;

-- Accounts the book still carries after they are PAID / CLOSED / WRITEOFF in the snapshot.
-- If these were being removed from the denominator the closed share would fall over time; it is flat.
create or replace table forensics.g_closed_still_worked as
select a.status_snapshot, count(*) as targets, count(distinct t.account_id) as accounts
from clean.daily_targeting t join clean.accounts a using (account_id) group by 1;

-- Status history cannot be used to rebuild the denominator: the last logged status agrees with the snapshot rarely
create or replace table forensics.g_status_history_check as
select count(*) as accounts_with_history,
       avg((h.last_status = a.status_snapshot)::int) as last_status_matches_snapshot,
       avg(recorded_before_event::int) as share_recorded_before_event
from (select account_id, arg_max(status, event_at) as last_status, avg(recorded_before_event::int) as recorded_before_event
      from clean.account_status_history group by 1) h
join clean.accounts a using (account_id);
