-- 01_staging.sql
-- Raw CSVs are loaded as-is. The only thing added is _src_row (row number in the file)
-- so every clean/rejected row can be traced back to the source file.
-- {{DATA_DIR}} is replaced by pipeline/run_pipeline.py

create schema if not exists stg;

create or replace table stg.borrowers         as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/borrowers.csv',              header=true, sample_size=-1);
create or replace table stg.accounts          as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/accounts.csv',               header=true, sample_size=-1);
create or replace table stg.agents            as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/agents.csv',                 header=true, sample_size=-1);
create or replace table stg.agent_sessions    as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/agent_sessions.csv',         header=true, sample_size=-1);
create or replace table stg.campaigns         as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/campaigns.csv',              header=true, sample_size=-1);
create or replace table stg.daily_targeting   as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/daily_targeting.csv',        header=true, sample_size=-1);
create or replace table stg.calls             as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/calls.csv',                  header=true, sample_size=-1);
create or replace table stg.call_attempts     as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/call_attempts.csv',          header=true, sample_size=-1);
create or replace table stg.call_dispositions as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/call_dispositions.csv',      header=true, sample_size=-1);
create or replace table stg.whatsapp_events   as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/whatsapp_events.csv',        header=true, sample_size=-1);
create or replace table stg.sms_events        as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/sms_events.csv',             header=true, sample_size=-1);
create or replace table stg.field_visits      as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/field_visits.csv',           header=true, sample_size=-1);
create or replace table stg.promises_to_pay   as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/promises_to_pay.csv',        header=true, sample_size=-1);
create or replace table stg.payments          as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/payments.csv',               header=true, sample_size=-1);
create or replace table stg.vendor_telephony  as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/vendor_telephony.csv',       header=true, sample_size=-1);
create or replace table stg.complaints        as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/complaints.csv',             header=true, sample_size=-1);
create or replace table stg.account_status_history as select row_number() over () as _src_row, * from read_csv('{{DATA_DIR}}/account_status_history.csv', header=true, sample_size=-1);
