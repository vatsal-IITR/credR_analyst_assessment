# Data quality report

Source: `collections_30k_dataset` (17 tables). Window used: 1 Jan to 8 Aug 2026 IST.
Every count below comes from `dq.cleaning_log`, `rejects.*` or `forensics.*` in the DuckDB build; none is hand-typed.

## 1. Raw -> Rejected / Corrected -> Golden

| Dataset | Raw rows | Rejected | Corrected / flagged | Clean rows | Reason |
|---|---:|---:|---:|---:|---|
| payments | 25,500 | 500 | 0 | 25,000 | duplicate `payment_id` (ingest retries) |
| calls | 91,350 | 1,350 | 38 | 90,000 | duplicate `call_id`; 38 agents filled from the twin row |
| calls (window) | 90,000 | 52 | 0 | 89,948 | outside 1 Jan - 8 Aug IST (one pre-2026, rest after the extract date) |
| whatsapp_events | 60,600 | 600 | 0 | 60,000 | duplicate event id |
| borrowers | 30,600 | 600 | 0 | 30,000 | exact duplicate rows |
| call_attempts | 120,000 | 0 | 2,400 | 120,000 | null `vendor_id` set to `UNKNOWN` |
| call_dispositions | 35,000 | 0 | 7,830 | 35,000 | `PTP` and `PROMISE_TO_PAY` merged |
| daily_targeting | 45,000 | 0 | 36,139 | 45,000 | flagged: dated outside the campaign start/end |
| accounts | 30,000 | 0 | 455 | 30,000 | null `borrower_id` (kept; not used as join key) |
| account_status_history | 60,000 | 0 | 30,191 | 60,000 | flagged: `recorded_at` earlier than `event_at` |
| agents | 30,000 | 29,000 | 0 | 1,000 | collapsed to one row per `agent_id` |
| sms_events, field_visits, ptp, complaints, sessions, campaigns, vendors | unchanged | 0 | 0 | same | no key problems found |

Result tables: `golden.fact_payment` 25,000 rows (17,534 SUCCESS), `golden.fact_contact`, `golden.dim_agent` 1,000, `golden.account_month` 240,000 (30,000 accounts x 8 months).

## 2. Major issues, detection, treatment, impact

| # | Issue | How detected | Treatment | Business impact |
|---|---|---|---|---|
| 1 | **Duplicate payment ids** (500; 2.0% of SUCCESS Rs) | `count(*)` vs `count(distinct payment_id)`; twin rows identical except sometimes a missing reference | keep one row per `payment_id` | Recovery overstated 2.0% (Rs 2.6 Cr over the window). Evenly spread, so does not explain the 11% |
| 2 | **Non-success payments in totals** | status mix: SUCCESS 70%, FAILED 15%, PENDING 10%, REVERSED 5% | recovery = SUCCESS only | Raw all-status total is 45.7% above SUCCESS. Pending Rs 19.0 Cr and reversed Rs 9.5 Cr shown separately |
| 3 | **`payment_reference` re-used across accounts** | 7,218 payment rows share a reference; none of the pairs is the same account | do NOT de-duplicate on reference | De-duping on reference would wrongly delete real money. 254 SUCCESS payments have no reference |
| 4 | **Month-length effect** | per-day normalisation of monthly totals | report recovery per calendar day | Explains the whole +11% (Feb 28 days vs Mar 31) |
| 5 | **Duplicate calls** (1,350; 1.5%) incl. replays 3 days later and twins with a missing agent | `call_id` repeated; compared twin rows | keep earliest, fill agent from twin | Raw contact rate uses 1.5% extra rows; effect on rate is small (0.0-0.1pp) |
| 6 | **Three time zones in calls** (UTC, Asia/Kolkata, Asia/Dubai) | `timezone` column | convert to UTC and IST; keep local | Day changes for 22.9% of UTC and 6.3% of Dubai calls; 0.8% / 0.2% change month. About half of calls are outside 08:00-20:00 on either clock, so call hour is not a reliable signal |
| 7 | **Payments and digital events have no time zone** | schema | treat as IST, state it | Unknown up to 5h30 shift on day boundaries; cannot be corrected |
| 8 | **`borrower_id` unusable** | 11,015 distinct ids over 30,000 borrower rows; events' borrower matches accounts' borrower in 0.009% of rows; 455 accounts null; 2,458 not in borrowers | join on `account_id` only | Any borrower-level view (segment, language, geography) would be wrong. See section 4 |
| 9 | **Agent identity** | 30,000 rows for 1,000 `agent_id`; each id has about 30 profiles with 13 vendors; 1,099 employee codes | key = `agent_id`, latest profile | Agent tenure, team, vendor-of-agent unreliable and not analysed. 1,757 calls (2.0%) have no agent |
| 10 | **Disposition to call link broken** | joined on `call_id`: account matches 0.0%, agent 0.09%, within one day 0.9% | use dispositions on their own `account_id` only | Cannot build contact -> outcome funnels from dispositions |
| 11 | **Two code sets for the same disposition** | `PTP` and `PROMISE_TO_PAY` both present, spread over `legacy/v1/v2` | merge to `PTP` | Counting only one under-counts PTPs by half |
| 12 | **PTP status does not reconcile with money** | KEPT PTPs have payment in window 3.5%, BROKEN 2.7% | validated PTP-kept rate from payments | Reported kept rate 25% vs validated 3%. Status field unusable |
| 13 | **Status history unusable** | last status equals snapshot 14% (= chance); 40% recorded before the event | not used for denominators | Cannot rebuild the account population over time |
| 14 | **Campaign dates** | 80% of targeting rows are dated outside the campaign's start/end | flagged, kept | Campaign attribution by date is unreliable; strategy flows by month are flat |
| 15 | **Sessions vs calls** | only 1.4% of calls fall inside a logged session | per-agent-hour metrics dropped | Recovery per agent-hour not reported |
| 16 | **Payments larger than outstanding** | 10.6% of SUCCESS payments exceed the account's outstanding | kept, flagged | Outstanding is a snapshot; may be post-payment. Not a recovery inflator on its own |
| 17 | **Partial month** | August has 8 days | excluded from month-on-month tests | A naive report shows -74.8% for August |
| 18 | **Duplicate borrowers** | 600 exact duplicate rows | removed | None on recovery |

## 3. Things I checked and found fine

- Accounts, campaigns, vendors, targeting, SMS, field visits, PTP, complaints: no duplicate primary keys.
- All payment `account_id`s exist in accounts. All calls' `agent_id` values exist in the agent table.
- Amounts are positive and within Rs 100 - 1.5 lakh; no negative or zero payments.
- Disposition versions are used side by side in every month, so there is no cut-over date to adjust for.
- Vendor answer rates range 19.3% - 21.1% with no vendor or status effect after multiple-comparison care.

## 4. What I could not do, and why

| Brief asks for | Status |
|---|---|
| Language, geography, borrower segment | Not analysed reliably. Borrowers has state/city but `borrower_id` does not link to accounts. No language field exists |
| Agent tenure | Not reliable (issue 9) |
| Cost per Rs recovered, ROI by channel | No cost data. Break-even only |
| Telephony vendor effect | Done at vendor level (flat), not controlled for agent or campaign |
| Calling time effect | Done on IST and local hour; answer rate is flat (p = 0.25) |
| Attempt frequency | Done at account-month level: no relationship with payment |

## 5. Pattern worth stating plainly

Across the tables, the outcome fields (answered, PTP status, disposition, channel) are statistically unrelated to payments, and several linking keys are broken. This is what you would see if the event logs were generated independently of the payment ledger. In a real business I would first ask the data owners whether the joins are wrong before concluding "nothing works". The conclusions in the memo are therefore labelled with confidence, and the first recommended action is to fix keys and run a randomised test.
