# Producer risk, job sheets and metrics (resilience steps R4 and R13, built 5 Nov 2026)

## Producer risk (Producers → a producer → "Risk and recovery")
- **Score 0–100** (higher = riskier) made of visible parts: on-time rate (up to 30), discrepancy rate (20), overdue returns (20), consignments dispatched over a day ago with no receipt confirmed (15), quality pass rate (15), holding our goods with no contact or update for 14+ days (5). Rating: low / medium (20) / high (40) / critical (60). Thresholds are placeholders in the `producer.risk` setting. The reasons are listed under the score, and the Producers table has a Risk column.
- **Suspend / allow work again** (manager, admin; reason of a few words required, audited). A suspended producer **cannot be given new consignments**: this is enforced in the database where movements are created, so it cannot be bypassed from any screen. Goods they already hold are not touched.
- **Limits and contacts** (manager, admin): emergency contact and phone, backup producers, and a **maximum number of open consignments** (also enforced in the database).
- **Record contact** (anyone who can act): resets the "gone quiet" clock.
- **If they fail:** exposure (units and value held, open consignments), who to call, whether to arrange collection, which active, non-suspended producers could take the work (backups first, with turnaround and whether they have a rate card), and a suggestion to suspend when risk is high.
- **Exceptions:** *Producer has gone quiet* (goods received or in production with no update for 3 days) and *Producer at high risk* (high or critical while holding our goods or open jobs). They clear themselves.

## Job sheet email
Movement drawer → **Draft job sheet email**: builds the email (lines, methods, stitches, due-back date, special instructions, quality notes) and puts it in the Emails queue for review. Nothing is sent automatically. No artwork files are attached yet.

## Metrics (Analytics page)
Real headline figures: on-time dispatch and average days late (30 days), shipped this week vs last, open and overdue, first-pass quality, machine downtime hours, supplier and producer on-time averages, median open-issue age; orders shipped per day; downtime per machine; first-pass quality by week and rework by problem; how fast each exception area is dealt with. "On time" means shipped on or before the promised dispatch date. Only history ATAM_FLOW has seen is counted, so the figures sharpen over time.

## n8n
- **ATAM_FLOW · Producer risk actions** (`Lkj4z3RxQSzIw6Ek`, webhook `/webhook/atam-flow/producer-risk`): unpublished.
- **ATAM_FLOW · Daily housekeeping** (`z6WoU0BRGp7Nxa2I`, 06:15 every day): refreshes supplier reliability and producer scorecards, checks overdue producer returns, drafts (never sends) chases for late POs, runs every exception detector. Unpublished.
Migrations 33 and 34; tests `metrics_test.sql` and `producer_risk_test.sql`.

## Honest gaps
- No producer portal, so receipt and progress still depend on staff recording them.
- Risk weights and thresholds are placeholders; margin by producer/method and the cost of exceptions are not yet in the metrics.
- Job sheets carry no attachments.
