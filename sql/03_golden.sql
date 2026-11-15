-- 03_golden.sql
-- Clean -> Golden. These are the tables that the metrics, notebook and dashboard read.
--
--   golden.dim_agent            one row per agent_id (entity resolution)
--   golden.fact_payment         one row per unique payment_id, IST timestamp, recovery flag
--   golden.fact_contact         every outbound/inbound touch in one table (voice, whatsapp, sms, field)
--   golden.payment_attribution  last-touch and first-touch attribution inside a 7 day window
--   golden.account_month        account x month panel (main modelling table)

create schema if not exists golden;

-- ---------------------------------------------------------------------------
-- AGENT ENTITY RESOLUTION
-- agents.csv has ~30 rows for every agent_id with different employee_code / name / vendor / team.
-- agent_id is the only id that links to calls (100% of non-null call agent_ids match), so it is the key.
-- Profile = most recently updated row. Tenure is therefore LOW confidence and is reported as such.
-- ---------------------------------------------------------------------------
create or replace table golden.dim_agent as
with ranked as (
    select *,
           row_number()            over (partition by agent_id order by updated_at desc, _src_row) as rn,
           count(*)                over (partition by agent_id)                                    as n_profile_rows,
           count(distinct employee_code) over (partition by agent_id)                              as n_employee_codes,
           count(distinct vendor_id)     over (partition by agent_id)                              as n_vendors,
           min(joined_at)          over (partition by agent_id)                                    as earliest_joined_at
    from stg.agents
)
select agent_id, employee_code, agent_name, vendor_id, team, status, joined_at, updated_at,
       n_profile_rows, n_employee_codes, n_vendors, earliest_joined_at,
       date_diff('month', joined_at, timestamp '2026-01-01') as tenure_months_at_jan26,
       case when date_diff('month', joined_at, timestamp '2026-01-01') < 6   then '0-6m'
            when date_diff('month', joined_at, timestamp '2026-01-01') < 12  then '6-12m'
            when date_diff('month', joined_at, timestamp '2026-01-01') < 18  then '12-18m'
            else '18m+' end as tenure_bucket
from ranked
where rn = 1;

insert into dq.cleaning_log
select 'agents', 'collapse to one row per agent_id (latest updated_at)', (select count(*) from stg.agents),
       (select count(*) from golden.dim_agent), (select count(*) from stg.agents) - (select count(*) from golden.dim_agent), 0,
       'each agent_id has ~30 conflicting profiles; employee_code maps to ~27 different agent_ids so it cannot be used to merge';

-- ---------------------------------------------------------------------------
-- PAYMENTS
-- Payment timestamps carry no timezone column, so they are taken as IST (the only choice that does not
-- invent information). Recovery = payment_status SUCCESS only. PENDING / FAILED / REVERSED are excluded.
-- ---------------------------------------------------------------------------
create or replace table golden.fact_payment as
select p.payment_id,
       p.account_id,
       p.event_at                                  as event_ist,
       cast(p.event_at as date)                    as pay_date,
       date_trunc('month', p.event_at)::date       as pay_month,
       p.payment_reference,
       p.amount,
       p.payment_status,
       p.payment_method,
       p.provider_id,
       (p.payment_status = 'SUCCESS')              as is_recovery,
       (p.payment_reference is null)               as ref_missing,
       (r.n_accounts_on_ref > 1)                   as ref_shared_across_accounts,
       p.n_copies                                  as n_ingest_copies
from clean.payments p
left join (
    select payment_reference, count(distinct account_id) as n_accounts_on_ref
    from clean.payments where payment_reference is not null group by 1
) r using (payment_reference)
where p.event_at >= timestamp '2026-01-01' and p.event_at < timestamp '2026-08-09';

-- ---------------------------------------------------------------------------
-- CONTACT FACT (all channels, one grain: one touch event)
-- is_effective = the touch actually reached the borrower
--   voice: ANSWERED | whatsapp: DELIVERED/READ/REPLIED/PAYMENT_CLICK | sms: DELIVERED/CLICKED |
--   field: CONTACTED/PTP/PAID/REFUSED (somebody was met)
-- ---------------------------------------------------------------------------
create or replace table golden.fact_contact as
select 'CALL:' || call_id as touch_id, account_id, event_ist, 'VOICE' as channel, agent_id, vendor_id,
       campaign_id, call_status as outcome, (call_status = 'ANSWERED') as is_effective, duration_sec
from clean.calls
union all
select 'WA:' || whatsapp_event_id, account_id, event_at, 'WHATSAPP', null, provider_id, null, event_type,
       event_type in ('DELIVERED', 'READ', 'REPLIED', 'PAYMENT_CLICK'), null
from clean.whatsapp_events
where event_at >= timestamp '2026-01-01' and event_at < timestamp '2026-08-09'
union all
select 'SMS:' || sms_event_id, account_id, event_at, 'SMS', null, provider_id, null, event_type,
       event_type in ('DELIVERED', 'CLICKED'), null
from clean.sms_events
where event_at >= timestamp '2026-01-01' and event_at < timestamp '2026-08-09'
union all
select 'FIELD:' || visit_id, account_id, event_at, 'FIELD', agent_id, null, null, outcome,
       outcome in ('CONTACTED', 'PTP', 'PAID', 'REFUSED'), null
from clean.field_visits
where event_at >= timestamp '2026-01-01' and event_at < timestamp '2026-08-09';

-- ---------------------------------------------------------------------------
-- PAYMENT ATTRIBUTION  (7 day look-back window, effective touches only)
-- last_touch  : the most recent effective touch before the payment  (what a "latest interaction" report does)
-- first_touch : the earliest effective touch inside the window
-- latest_campaign : the most recent targeting row for the account on or before the payment date
-- ---------------------------------------------------------------------------
create or replace table golden.payment_attribution as
with pay as (select * from golden.fact_payment where is_recovery),
eff as (select * from golden.fact_contact where is_effective),
last_t as (
    select p.payment_id, c.channel as last_channel, c.event_ist as last_touch_at, c.campaign_id as last_call_campaign
    from pay p asof left join eff c on p.account_id = c.account_id and p.event_ist >= c.event_ist
),
first_t as (
    select p.payment_id, arg_min(c.channel, c.event_ist) as first_channel, count(*) as n_touch_7d
    from pay p join eff c
      on c.account_id = p.account_id and c.event_ist <= p.event_ist and c.event_ist >= p.event_ist - interval 7 day
    group by 1
),
tgt as (
    select p.payment_id, t.campaign_id as latest_target_campaign, t.strategy_version as latest_strategy
    from pay p asof left join (select * from clean.daily_targeting) t
      on p.account_id = t.account_id and p.pay_date >= t.target_date
)
select p.payment_id, p.account_id, p.event_ist, p.pay_month, p.amount,
       case when date_diff('second', l.last_touch_at, p.event_ist) <= 7 * 86400 then l.last_channel end as last_touch_channel_7d,
       case when date_diff('second', l.last_touch_at, p.event_ist) <= 7 * 86400 then l.last_call_campaign end as last_call_campaign_7d,
       f.first_channel as first_touch_channel_7d,
       coalesce(f.n_touch_7d, 0) as n_effective_touches_7d,
       (f.n_touch_7d is null) as uncontacted_7d,
       t.latest_target_campaign, t.latest_strategy
from pay p
left join last_t  l using (payment_id)
left join first_t f using (payment_id)
left join tgt     t using (payment_id);

-- ---------------------------------------------------------------------------
-- ACCOUNT x MONTH PANEL
-- ---------------------------------------------------------------------------
create or replace table golden.account_month as
with months as (
    select unnest(generate_series(date '2026-01-01', date '2026-08-01', interval 1 month))::date as month_start
),
pay as (
    select account_id, pay_month as month_start,
           sum(amount) filter (where is_recovery) as recovered,
           count(*)    filter (where is_recovery) as n_success_pay,
           sum(amount) filter (where payment_status = 'REVERSED') as reversed_amt
    from golden.fact_payment group by 1, 2
),
con as (
    select account_id, date_trunc('month', event_ist)::date as month_start,
           count(*) filter (where channel = 'VOICE')                          as n_calls,
           count(*) filter (where channel = 'VOICE' and is_effective)         as n_answered,
           count(*) filter (where channel = 'WHATSAPP' and is_effective)      as n_wa_eff,
           count(*) filter (where channel = 'SMS' and is_effective)           as n_sms_eff,
           count(*) filter (where channel = 'FIELD')                          as n_field,
           count(*) filter (where channel = 'FIELD' and is_effective)         as n_field_eff
    from golden.fact_contact group by 1, 2
),
tg as (
    select account_id, date_trunc('month', target_date)::date as month_start,
           count(*) as n_targeted,
           count(*) filter (where status = 'CONTACTED') as n_target_contacted,
           min(priority) as best_priority,
           arg_max(strategy_version, target_date) as strategy_version,
           arg_max(target_definition, target_date) as target_definition
    from clean.daily_targeting group by 1, 2
)
select a.account_id, m.month_start, a.loan_type, a.risk_segment, a.dpd, a.dpd_bucket, a.outstanding_amount,
       a.principal_amount, a.timezone as account_timezone,
       coalesce(p.recovered, 0)     as recovered,
       coalesce(p.n_success_pay, 0) as n_success_pay,
       coalesce(p.reversed_amt, 0)  as reversed_amt,
       coalesce(c.n_calls, 0) as n_calls, coalesce(c.n_answered, 0) as n_answered,
       coalesce(c.n_wa_eff, 0) as n_wa_eff, coalesce(c.n_sms_eff, 0) as n_sms_eff,
       coalesce(c.n_field, 0) as n_field, coalesce(c.n_field_eff, 0) as n_field_eff,
       coalesce(t.n_targeted, 0) as n_targeted, coalesce(t.n_target_contacted, 0) as n_target_contacted,
       t.best_priority, t.strategy_version, t.target_definition,
       case when m.month_start = date '2026-08-01' then 8 else date_diff('day', m.month_start, m.month_start + interval 1 month) end as days_observed,
       (m.month_start = date '2026-08-01') as is_partial_month
from clean.accounts a
cross join months m
left join pay p on p.account_id = a.account_id and p.month_start = m.month_start
left join con c on c.account_id = a.account_id and c.month_start = m.month_start
left join tg  t on t.account_id = a.account_id and t.month_start = m.month_start;

insert into dq.cleaning_log
select 'golden.account_month', 'build panel (30,000 accounts x 8 months)', (select count(*) from clean.accounts) * 8,
       count(*), 0, 0, 'August is partial (8 days); every monthly metric also carries days_observed'
from golden.account_month;
