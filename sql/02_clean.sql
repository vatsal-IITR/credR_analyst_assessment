-- 02_clean.sql
-- Raw -> Rejected / Corrected -> Clean.
-- Every step writes one line to dq.cleaning_log so the impact of each decision can be quantified.
--
-- Decisions (also in reports/data_quality_report.md):
--   * Analysis window = 2026-01-01 to 2026-08-08 (IST). 8 Aug is the last day on which every table has data.
--   * event_at in calls is treated as local wall-clock time of the row's `timezone` column (UTC / IST / GST).
--     Payments and the digital/field tables have no timezone column, so they are taken as given.
--   * borrower_id on event tables is NOT trusted (see forensics). account_id is the join key.

create schema if not exists clean;
create schema if not exists rejects;
create schema if not exists dq;

create or replace table dq.cleaning_log (
    dataset        varchar,
    step           varchar,
    rows_in        bigint,
    rows_out       bigint,
    rows_rejected  bigint,
    rows_corrected bigint,
    note           varchar
);

-- ---------------------------------------------------------------------------
-- PAYMENTS : duplicate payment_id (ingestion retries). Keep the copy that has a payment_reference.
-- ---------------------------------------------------------------------------
create or replace temp table _pay_ranked as
select *,
       max(payment_reference) over (partition by payment_id)                     as ref_filled,
       count(*)               over (partition by payment_id)                     as n_copies,
       row_number()           over (partition by payment_id
                                    order by (payment_reference is null), _src_row) as rn
from stg.payments;

create or replace table clean.payments as
select payment_id,
       account_id,
       event_at,
       coalesce(payment_reference, ref_filled) as payment_reference,
       amount,
       payment_status,
       payment_method,
       provider_id,
       (payment_reference is null and ref_filled is not null) as ref_recovered,
       n_copies
from _pay_ranked
where rn = 1;

create or replace table rejects.payments as
select _src_row, payment_id, account_id, event_at, payment_reference, amount, payment_status,
       'DUPLICATE_PAYMENT_ID' as reject_reason
from _pay_ranked
where rn > 1;

insert into dq.cleaning_log
select 'payments', 'dedupe on payment_id (keep copy with reference)',
       (select count(*) from stg.payments), (select count(*) from clean.payments),
       (select count(*) from rejects.payments), (select count(*) from clean.payments where ref_recovered),
       'payment_reference collisions across different accounts are NOT treated as duplicates';

-- ---------------------------------------------------------------------------
-- CALLS : duplicate call_id (exact copies, copies with null agent, copies replayed 3 days later)
--         keep earliest event_at, fill missing agent from the twin row
-- ---------------------------------------------------------------------------
create or replace temp table _call_ranked as
select *,
       max(agent_id) over (partition by call_id)                         as agent_filled,
       count(*)      over (partition by call_id)                         as n_copies,
       row_number()  over (partition by call_id order by event_at, _src_row) as rn
from stg.calls;

create or replace temp table _call_dedup as
select c.*,
       case timezone when 'Asia/Kolkata' then 330 when 'Asia/Dubai' then 240 else 0 end as tz_off_min
from _call_ranked c
where rn = 1;

create or replace table rejects.calls as
select _src_row, call_id, account_id, event_at, agent_id, call_status, 'DUPLICATE_CALL_ID' as reject_reason
from _call_ranked where rn > 1
union all
select _src_row, call_id, account_id, event_at, agent_id, call_status, 'OUT_OF_WINDOW' as reject_reason
from _call_dedup
where (event_at - to_minutes(tz_off_min) + to_minutes(330)) <  timestamp '2026-01-01'
   or (event_at - to_minutes(tz_off_min) + to_minutes(330)) >= timestamp '2026-08-09';

create or replace table clean.calls as
select call_id,
       account_id,
       event_at                                                         as event_local,
       event_at - to_minutes(tz_off_min)                                as event_utc,
       event_at - to_minutes(tz_off_min) + to_minutes(330)              as event_ist,
       coalesce(agent_id, agent_filled)                                 as agent_id,
       (agent_id is null and agent_filled is not null)                  as agent_recovered,
       campaign_id,
       direction,
       vendor_id,
       call_status,
       duration_sec,
       timezone,
       n_copies
from _call_dedup
where (event_at - to_minutes(tz_off_min) + to_minutes(330)) >= timestamp '2026-01-01'
  and (event_at - to_minutes(tz_off_min) + to_minutes(330)) <  timestamp '2026-08-09';

insert into dq.cleaning_log
select 'calls', 'dedupe on call_id (keep earliest, fill agent from twin)',
       (select count(*) from stg.calls), (select count(*) from _call_dedup),
       (select count(*) from rejects.calls where reject_reason = 'DUPLICATE_CALL_ID'),
       (select count(*) from clean.calls where agent_recovered),
       'copies replayed 3 days later are treated as late-arriving duplicates';
insert into dq.cleaning_log
select 'calls', 'drop outside 2026-01-01..2026-08-08 (IST)',
       (select count(*) from _call_dedup), (select count(*) from clean.calls),
       (select count(*) from rejects.calls where reject_reason = 'OUT_OF_WINDOW'), 0,
       'future-dated (after extract date) and pre-2026 calls';

-- ---------------------------------------------------------------------------
-- CALL ATTEMPTS / DISPOSITIONS : no duplicate ids, but missing vendor and legacy codes
-- ---------------------------------------------------------------------------
create or replace table clean.call_attempts as
select attempt_id, account_id, event_at, call_id, agent_id, attempt_no,
       coalesce(vendor_id, 'UNKNOWN') as vendor_id, attempt_status
from stg.call_attempts
where event_at >= timestamp '2026-01-01' and event_at < timestamp '2026-08-09';

insert into dq.cleaning_log
select 'call_attempts', 'null vendor_id -> UNKNOWN', (select count(*) from stg.call_attempts),
       (select count(*) from clean.call_attempts), 0,
       (select count(*) from stg.call_attempts where vendor_id is null), 'no duplicate attempt_id found';

-- PTP and PROMISE_TO_PAY are the same business outcome written with two different code sets
create or replace table clean.call_dispositions as
select disposition_id, account_id, event_at, call_id, agent_id,
       disposition_code as disposition_code_raw,
       case when disposition_code in ('PTP', 'PROMISE_TO_PAY') then 'PTP' else disposition_code end as disposition_code,
       disposition_version
from stg.call_dispositions
where event_at >= timestamp '2026-01-01' and event_at < timestamp '2026-08-09';

insert into dq.cleaning_log
select 'call_dispositions', 'merge PTP + PROMISE_TO_PAY', (select count(*) from stg.call_dispositions),
       (select count(*) from clean.call_dispositions), 0,
       (select count(*) from stg.call_dispositions where disposition_code in ('PTP','PROMISE_TO_PAY')),
       'two code sets for the same outcome, spread across legacy/v1/v2';

-- ---------------------------------------------------------------------------
-- WHATSAPP / SMS : exact duplicate event ids
-- ---------------------------------------------------------------------------
create or replace table clean.whatsapp_events as
select * exclude (rn, _src_row) from (
    select *, row_number() over (partition by whatsapp_event_id order by _src_row) as rn from stg.whatsapp_events)
where rn = 1;

create or replace table rejects.whatsapp_events as
select _src_row, whatsapp_event_id, account_id, event_at, event_type, 'DUPLICATE_EVENT_ID' as reject_reason from (
    select *, row_number() over (partition by whatsapp_event_id order by _src_row) as rn from stg.whatsapp_events)
where rn > 1;

insert into dq.cleaning_log
select 'whatsapp_events', 'dedupe on whatsapp_event_id', (select count(*) from stg.whatsapp_events),
       (select count(*) from clean.whatsapp_events), (select count(*) from rejects.whatsapp_events), 0,
       'message_id repeats are normal (one message, many status events), so message_id is not used for dedupe';

create or replace table clean.sms_events as
select * exclude (rn, _src_row) from (
    select *, row_number() over (partition by sms_event_id order by _src_row) as rn from stg.sms_events)
where rn = 1;

insert into dq.cleaning_log
select 'sms_events', 'dedupe on sms_event_id', (select count(*) from stg.sms_events),
       (select count(*) from clean.sms_events), (select count(*) from stg.sms_events) - (select count(*) from clean.sms_events), 0,
       'no duplicates found';

-- ---------------------------------------------------------------------------
-- FIELD VISITS, PTP, COMPLAINTS, SESSIONS, TARGETING : keys are clean, only flags added
-- ---------------------------------------------------------------------------
create or replace table clean.field_visits as
select visit_id, account_id, event_at, agent_id, visit_type, outcome, latitude, longitude, scheduled_at
from stg.field_visits;

insert into dq.cleaning_log
select 'field_visits', 'none (scheduled_at null kept as null)', count(*), count(*), 0, 0,
       '250 rows with null scheduled_at; visits happen 0-24h after schedule, so no timestamp conflict'
from stg.field_visits;

create or replace table clean.promises_to_pay as
select ptp_id, account_id, event_at, agent_id, promised_amount, promised_date,
       status as status_reported, source
from stg.promises_to_pay;

create or replace table clean.complaints as select * exclude (_src_row) from stg.complaints;

create or replace table clean.agent_sessions as
select session_id, agent_id, login_at, logout_at, channel, device_id, timezone,
       date_diff('second', login_at, logout_at) / 3600.0 as session_hours
from stg.agent_sessions
where logout_at > login_at;

create or replace table clean.daily_targeting as
select t.target_id, t.account_id, t.campaign_id, t.target_date, t.priority, t.recommended_channel, t.status,
       c.campaign_name, c.channel as campaign_channel, c.strategy_version, c.target_definition,
       c.start_at as campaign_start, c.end_at as campaign_end,
       (t.target_date >= cast(c.start_at as date) and t.target_date <= cast(c.end_at as date)) as in_campaign_window
from stg.daily_targeting t
left join stg.campaigns c using (campaign_id);

insert into dq.cleaning_log
select 'daily_targeting', 'flag targets outside campaign start/end', count(*), count(*), 0,
       count(*) filter (where not in_campaign_window),
       'targeting rows dated outside the campaign window are kept but flagged'
from clean.daily_targeting;

-- ---------------------------------------------------------------------------
-- BORROWERS / ACCOUNTS
-- ---------------------------------------------------------------------------
create or replace table clean.borrowers as
select distinct * exclude (_src_row) replace (cast(phone as bigint) as phone) from stg.borrowers;

insert into dq.cleaning_log
select 'borrowers', 'drop exact duplicate rows', (select count(*) from stg.borrowers), (select count(*) from clean.borrowers),
       (select count(*) from stg.borrowers) - (select count(*) from clean.borrowers), 0,
       'borrower_id is still not unique after this (' ||
       (select count(distinct borrower_id) from clean.borrowers) || ' ids over ' ||
       (select count(*) from clean.borrowers) || ' rows) so borrower_id cannot be an entity key';

create or replace table clean.accounts as
select account_id, borrower_id, loan_type, principal_amount, outstanding_amount, dpd, risk_segment,
       status as status_snapshot, opened_at, timezone,
       case when dpd = 0 then '0'
            when dpd <= 30 then '1-30'
            when dpd <= 60 then '31-60'
            when dpd <= 90 then '61-90'
            else '91+' end as dpd_bucket
from stg.accounts;

insert into dq.cleaning_log
select 'accounts', 'add dpd_bucket', count(*), count(*), 0, count(*) filter (where borrower_id is null),
       'rows_corrected = accounts with null borrower_id (kept, borrower_id is not used for joins)'
from stg.accounts;

create or replace table clean.account_status_history as
select history_id, account_id, event_at, status, changed_by, source, recorded_at,
       (recorded_at < event_at) as recorded_before_event
from stg.account_status_history;

insert into dq.cleaning_log
select 'account_status_history', 'flag recorded_at < event_at', count(*), count(*), 0,
       count(*) filter (where recorded_before_event),
       'record cannot be written before the event; event_at is kept as business time'
from clean.account_status_history;

create or replace table clean.vendors as select * exclude (_src_row) from stg.vendor_telephony;
create or replace table clean.campaigns as select * exclude (_src_row) from stg.campaigns;
create or replace table clean.agents_raw as select * exclude (_src_row) from stg.agents;
