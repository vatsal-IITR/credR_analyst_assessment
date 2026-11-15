# Collections analytics: is "recovery up 11% month-on-month" true?

**Answer: no.** The +11% (Feb to Mar) is the 28-day vs 31-day month. Per calendar day the change is +0.3% (95% range about -6% to +7%). Read `reports/executive_memo.md` first.
**Recommendation:** do not release the ₹10 Cr on current evidence. If one option must be named, choose better borrower targeting, released in tranches: ₹1 Cr now for a randomised test, and the balance only if it beats break-even. Confidence is low, because several linking keys in the data are broken (see the data quality report).

**Start here:** reports/Executive_Memo.pdf (2 pages). The editable source is reports/executive_memo.md.

Executive dashboard

One-screen dashboard. The interactive version is dashboard/index.html (open in a browser).

## Deliverables

| # | Deliverable | Where |
|---|---|---|
| 1 | SQL repository | `sql/01_staging.sql` ... `06_analysis.sql` (run in order) |
| 2 | Analysis notebook (executed, 0 errors) | `notebooks/collections_analysis.ipynb` |
| 3 | Golden dataset / reproducible pipeline | `pipeline/run_pipeline.py` builds `data/collections.duckdb`; `--export` writes `data/golden/*.parquet` |
| 4 | Data quality report | `reports/data_quality_report.md` |
| 5 | Executive dashboard (one screen) | `dashboard/index.html` (open in a browser) |
| 6 | Executive memo (2 pages) | `reports/executive_memo.md` |
| 7 | Architecture diagram | `architecture/architecture.md` (mermaid) |
| Part 4 | Counterfactual design | `docs/counterfactual_design.md` |
| Part 5 | Production design | `docs/production_design.md` |
| - | Metric definitions | `docs/metric_definitions.md` |

## Architecture

**Architecture**
Raw, Staging, Clean, Golden, Feature, Metrics, Dashboard. Full description in architecture/architecture.md and docs/production_design.md.

## Run it

```
pip install duckdb pandas numpy scipy statsmodels scikit-learn matplotlib nbformat nbclient ipykernel
python pipeline/run_pipeline.py --data-dir ../collections_30k_dataset --export
python pipeline/build_notebook.py        # re-executes the notebook
python pipeline/build_dashboard.py       # regenerates dashboard/index.html
```

The pipeline deletes and rebuilds the DuckDB file on every run, so results are reproducible from the raw CSVs. Random steps use seed 42.

## SQL layers

| File | Schema | Content |
|---|---|---|
| `01_staging.sql` | `stg` | raw CSVs with `_src_row` |
| `02_clean.sql` | `clean`, `rejects`, `dq` | de-duplication, window, code merge, rejected rows, `cleaning_log` |
| `03_golden.sql` | `golden` | `dim_agent`, `fact_payment`, `fact_contact`, `payment_attribution`, `account_month` |
| `04_metrics.sql` | `metrics` | `monthly`, `ptp_validated`, `channel_touch` |
| `05_forensics.sql` | `forensics` | checks A-G from the brief |
| `06_analysis.sql` | `analysis` | bridge, mix, Simpson, cohort, touch lift, DiD panel |

## Key assumptions

1. Window is 1 Jan - 8 Aug 2026 IST (last day every table has data). August is partial and excluded from month-on-month tests.
2. Call times are converted from their `timezone` column to IST. Payments and digital events have no time zone and are treated as IST.
3. Recovery = `SUCCESS` payments only, de-duplicated on `payment_id`. `payment_reference` is not unique by design in this data and is not used to de-duplicate.
4. `account_id` is the only join key. `borrower_id` on events does not match the account's borrower.
5. The targeting change date is assumed to be 1 April 2026 and `v3` the new strategy (the data does not state it).

## What the data could not answer

Agent tenure, language, geography, borrower segment, cost per Rs recovered and recovery per agent-hour. The reasons are in section 4 of the data quality report. Several linking keys are broken, and outcome fields (answered, PTP status) are unrelated to payments, so channel effects could not be established. This should be confirmed with the data owners before it is treated as a business fact.
<img width="1901" height="952" alt="Screenshot 2026-11-15 155225" src="https://github.com/user-attachments/assets/97b136cd-fd9d-44c3-9e98-29fe7511080c" />
