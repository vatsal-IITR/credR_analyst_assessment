# Metric definitions

Where a "common" definition and mine differ, I say why. All of these are in `sql/04_metrics.sql` (`metrics.monthly`) unless stated.

| Metric | Common / reported-style | Independent definition used | Why the change |
|---|---|---|---|
| Recovery (Rs) | sum of `amount` in payments file for the month | sum of `amount` where `payment_status = 'SUCCESS'`, after de-duplicating `payment_id`, by IST payment date | Raw all-status is 45.7% too high; raw SUCCESS is 2.0% too high because of duplicate ids |
| Recovery comparison across months | total per month | **recovery per calendar day** (and total shown beside it) | Month length changes totals by up to 10.7% on its own. This is the cause of the "+11%" |
| Recovery rate | recovered / outstanding for the month | (recovery per day x 30) / total outstanding of the book | Comparable across months; 1.67%-1.74% every month |
| Recovery per account | recovered / accounts that paid | recovered / all accounts in the book | Dividing by payers hides accounts that did not pay and makes the number look better when fewer pay |
| Account pay rate | not usually reported | accounts with at least one SUCCESS payment in the month / all accounts | Denominator is fixed (30,000), so it cannot be changed by who is included |
| Contact rate | answered calls / calls | accounts with at least one effective touch / accounts attempted, any channel, by month | Counts people, not dial attempts; includes WhatsApp, SMS, field; excludes duplicate call rows |
| Answer rate (voice) | n/a | answered calls / unique calls | Kept as a separate voice metric |
| RPC (right-party contact) | any disposition | disposition not in (`NO_CONTACT`, `WRONG_NUMBER`), measured on the disposition's own `account_id` | `call_dispositions.call_id` does not belong to the same account as the call (0% match), so call-level RPC would be wrong |
| PTP rate | PTPs / calls | PTPs / RPC accounts | Denominator is people actually reached |
| PTP kept rate | `status = 'KEPT'` / all PTPs | among **matured** PTPs: successful payments on the account between PTP date and promised date + 2 days sum to at least 80% of promised amount | Reported status does not reconcile with payments (KEPT paid 3.5% of the time vs BROKEN 2.7%); open PTPs distort the denominator |
| Recovery per agent-hour | recovery / login hours | **not reported** | Only 1.4% of calls fall inside a logged session and agent identity is unreliable |
| Cost per Rs recovered | n/a | **not computable** | No cost data supplied (agents, vendors, messages) |
| Channel conversion | payments credited to the last interaction / interactions | share of effective touches followed by a SUCCESS payment within 7 days, **compared with the no-touch weekly base rate** | Credit is incremental; shows that touch and no-touch rates are equal (1.80% vs 1.85%) |
| Attribution | latest campaign / interaction, no window | first-touch and last-touch inside a 7-day window, effective touches only; the rest is `NO_TOUCH` | 90.6% of payments have no touch in 7 days |

## Conventions

- **Time**: calls are converted to IST from their `timezone` column. Payments and digital/field events have no timezone and are treated as IST (stated assumption).
- **Window**: 1 Jan to 8 Aug 2026 (IST). 8 August is the last day all tables have data. August is partial (8 days) and excluded from month-on-month tests.
- **Status**: only `SUCCESS` payments count as recovery. `PENDING` (Rs 19.0 Cr) is shown separately; `REVERSED` (Rs 9.5 Cr) is not netted off because a reversal row has no link to the payment it reverses (0 amount matches, 24% have any earlier success on the account).
- **Keys**: `account_id` is the join key. `borrower_id` on event tables does not match `accounts.borrower_id` and is not used.
