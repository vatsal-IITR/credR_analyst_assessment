# Part 5: Production analytics design

Flow: **Raw -> Staging -> Clean -> Golden -> Feature -> Metrics -> Dashboard**

The repository already implements the first half of this on DuckDB (`sql/01..06`). The table below maps each layer to what exists and what an engineering team would add.

| Layer | Purpose | In this repo | Production |
|---|---|---|---|
| Raw | Immutable copy of every file/event as received | `collections_30k_dataset/*.csv` | Object storage (S3/ADLS) partitioned by `source/ingest_date`, never overwritten |
| Staging | Typed, no business logic, adds `_src_row`, `_ingested_at`, `_source_file` | `sql/01_staging.sql` (`stg.*`) | Same, loaded by the orchestrator, one table per source |
| Clean | Dedupe, standardise, reject with reason | `sql/02_clean.sql` (`clean.*`, `rejects.*`, `dq.cleaning_log`) | Same SQL, incremental |
| Golden | Conformed entities and facts used by everyone | `sql/03_golden.sql` (`golden.*`) | Same, plus SCD2 on agents |
| Feature | Account-period features for models/tests | `golden.account_month`, `analysis.did_panel` | Feature table with `as_of_date` so features are point-in-time |
| Metrics | One definition per KPI | `sql/04_metrics.sql` (`metrics.*`) | Metric layer (dbt metrics / semantic layer) |
| Dashboard | One screen | `dashboard/index.html` | BI tool reading `metrics.*` only |

See `architecture/architecture.md` for the diagram.

## Data contracts

Each source has a contract file (YAML) checked at ingest. Example for payments:

```yaml
source: payments
owner: payments-platform@company
freshness: arrives within 6 hours of event
schema:
  payment_id:        {type: string, nullable: false, unique_per_load: true}
  account_id:        {type: string, nullable: false, pattern: '^ACC\d{7}$', references: accounts.account_id}
  event_at:          {type: timestamp, nullable: false, timezone: "must be declared; currently missing"}
  amount:            {type: decimal(14,2), min: 1}
  payment_status:    {allowed: [SUCCESS, FAILED, PENDING, REVERSED]}
  payment_reference: {nullable: true, unique: false}   # known: reused across accounts
breaking_change_policy: 30 days notice, version in `schema_version`
```

Breaking changes (a new status code, a changed disposition set, a new timezone) fail the load for that source and alert the owner; they do not silently flow into metrics.

Contract gaps found in this data that should be fixed at source: payments and digital events have **no timezone**; `borrower_id` on event tables does not match the account's borrower; dispositions carry a `call_id` that does not belong to the same account; `agents` is not unique on `agent_id`.

## Primary keys and grain

| Table | Key | Grain | Notes |
|---|---|---|---|
| `golden.fact_payment` | `payment_id` | one successful/failed/pending/reversed attempt | `payment_reference` is NOT a key (7,218 rows share one) |
| `clean.calls` | `call_id` | one call | duplicates removed, earliest kept |
| `golden.dim_agent` | `agent_id` | one agent (latest profile) | needs SCD2 once source is fixed |
| `golden.fact_contact` | `touch_id` (`CALL:..`, `WA:..`, `SMS:..`, `FIELD:..`) | one touch event | prefix avoids id collisions |
| `golden.account_month` | `(account_id, month_start)` | one row | |
| `clean.accounts` | `account_id` | one account | |

Uniqueness is asserted as a test, not assumed (see checks below).

## Metric definitions

Single source in `sql/04_metrics.sql`, written up in `docs/metric_definitions.md`. Every dashboard tile must name the `metrics.*` column it reads. A metric change is a pull request that updates SQL, definition doc and a regression test together.

## Lineage

- Every golden row can be traced back: `_src_row` (row in raw file) is carried in `clean`/`rejects`, and `dq.cleaning_log` states rows in/out/rejected per step.
- In production: dbt (or equivalent) generates the model DAG; the dashboard shows "data as of" and the lineage of each tile.

## Incremental processing

- Facts (`payments`, `calls`, digital events) load by `event_at` date partition. Each daily run reprocesses a **rolling window of the last 7 days** (not only yesterday), using `merge` on the primary key so reruns are idempotent.
- `account_month` is rebuilt for the current and previous month only; older months are frozen unless a backfill is requested.
- Dimensions (accounts, agents, campaigns) are full refresh each day; they are small (30k and 1k rows).
- Nothing in this dataset needs more than minutes at 30k accounts. At 100x scale, partition by month and run per partition.

## Late-arriving data

- The data shows it: 3-day replays of the same `call_id`, and `recorded_at` earlier than `event_at` in 40% of status-history rows.
- Rule: the business date is `event_at` (in IST), the load date is `_ingested_at`. Metrics use `event_at`.
- The 7-day rolling window above absorbs late events. Anything later than 7 days triggers a **restatement**: the affected months are recomputed, and the dashboard marks them "restated" with the delta against what was shown before. Prior values are kept in `metrics.monthly_history` (snapshot per run date), so a number leadership has seen is never silently changed.
- Current month is always labelled **partial** with `days_with_data`; rates are per day, never raw monthly totals (this is the failure behind the 11% claim).

## Backfills

1. Pick source and date range, write to a new `_backfill_<id>` partition.
2. Run clean + golden into a shadow schema; compare row counts and metric totals with production (tolerance rule below).
3. If within tolerance or explained, swap partitions; record in a backfill log with who/why.
4. Re-snapshot `metrics.monthly_history`.

## Data-quality checks

Run after each layer. Failures are `error` (stop the run) or `warn` (publish, flag).

| Check | Layer | Level | Threshold |
|---|---|---|---|
| Primary key unique and not null | clean, golden | error | 0 violations |
| Foreign keys (`payments.account_id` in `accounts`) | clean | error | 100% |
| Row-count change vs same weekday last 4 weeks | staging | warn | outside +/-30% |
| Duplicate rate (rejected / raw) | clean | warn | above 3% (today: payments 2.0%, calls 1.5%) |
| Status code set equals contract | staging | error | any new value |
| Payment amount > outstanding | golden | warn | track share (today 10.6%) |
| Null rate of key columns | staging | warn | above 2x baseline |
| Reconcile golden recovery to payments provider settlement file | metrics | error | difference above 0.5% |
| Disposition account equals call account | clean | warn | below 95% (today 0%) |
| Event timestamp in future | clean | error | any |
| Window coverage: every table has data to the same last day | golden | error | otherwise metrics use the common last day |

## Monitoring and anomaly detection

- **Pipeline**: run duration, rows per layer, failed checks, freshness lag per source. Alert via on-call channel for `error`, daily digest for `warn`.
- **Metrics**: for each KPI, forecast per-day value from the last 8 weeks with weekday effects (median and MAD); alert when today is outside 3.5 robust z-scores, or when a **month-on-month change is quoted without day normalisation** (the dashboard simply does not display month-on-month on raw totals).
- **Contract drift**: new categorical values, new nulls, timezone changes, ID-format changes are detected by comparing profile to the contract every load.
- **Reconciliation drift**: ratio of golden recovery to settled bank amount, tracked daily; a step change means ingestion or status-mapping problems (duplicates, reversals).
- Anomalies are shown on the dashboard as flags, not as automatic corrections.

## Dashboard rules

1. One screen; headline answer first; the same metric names as `metrics.*`.
2. Rates use stated denominators; totals are shown per day.
3. Last-updated time, window coverage, and restated-month markers are always visible.
4. Every claim that is not a Fact is labelled (Strong evidence / Correlation / Hypothesis).

## Rollout order

1. Contracts + the five error-level checks (uniqueness, FK, window, status set, reconciliation).
2. Daily incremental load with the 7-day window and `metrics.monthly_history`.
3. Dashboard on `metrics.*` only.
4. Anomaly detection and drift monitoring.
5. Fix source issues (timezones, agent master, call-disposition key) and retire the workaround rules in `sql/02_clean.sql`.
