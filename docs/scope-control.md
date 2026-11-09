# Scope control: what ATAM_FLOW looks after

Built so ATAM_FLOW can launch for third-party decorator work only, with in-house production switchable on later. Nothing is ever deleted by these controls.

## Switches (admin only)
`flow.scope_switches`: one master switch (`inhouse.master`) and one per process (`inhouse.method.<code>`). A process is planned in-house only when the master and its own switch are both on.
- **Off means:** the scheduler gets no steps for that work (existing pending plan steps drop out at the next re-plan), and while the master is off the machine-downtime detector raises nothing. Third-party work, purchasing, warehouse, QC, couriers and dispatch are untouched.
- **Safety:** switching off is refused while jobs for that work are running on the floor.
- **Every change** needs a reason, previews what it touches first (`ui_sc_preview`: planned steps, orders, running jobs, exceptions cleared), and is written to `flow.scope_log` and the audit log. Reverse it from the same page.
- Seeded all **on** (nothing changes by itself). Switching the master off for launch is a one-click audited action on the Control page.

## Order scope
Every order has a scope: **third_party**, **in_house**, **out_of_scope**, or **unclassified** (nothing decided).
1. A manual setting (`scope_override`, manager/admin, reason required, audited) always wins.
2. Otherwise `third_party_flag` makes it third_party. This is DecoNetwork's **Priority Order** flag: the order's API field is `is_priority` (the shield in DecoNetwork's screen is only how it is displayed). The unpublished workflow **ATAM_FLOW · Sync priority flags** (`TjgPA4edC6iBfIRX`) reads recent orders (due 60 days back to 30 days ahead) every hour at :25 and saves the flag through `flow_sync_priority_flags`. It changes nothing in DecoNetwork and does not touch the existing WF3 capture workflow. An order whose flag changes after work started shows up under Changes & control for review.
3. Otherwise unclassified, which is treated as in-house work when in-house production is on.
- Third-party and out-of-scope orders are not planned by the scheduler. Out-of-scope orders also have their exceptions dropped before they are raised.
- An order cannot be moved to in-house or out of scope while it has an open producer consignment.

## Where
Control page (`#/control`): switches, order counts by scope, hand-set overrides, recent changes. Order drawer, Changes & control tab: change one order's scope. Orders list: Third-party / In-house / Unclassified / Out of scope filters. Production and Machines show a banner when in-house is off.

Writes use the unpublished Operations actions workflow (`set_switch` admin only, `set_scope` manager/admin).

## Third-party focus (Orders, Exceptions, Home)
A view setting, not a data change. With focus on, these screens hide anything that belongs to an order that is not third-party (in-house, unclassified or out of scope). A bar at the top says exactly how many orders and exceptions are hidden and has a button to **Show everything** (and **Third-party only** to come back).
- **Orders:** hides non-third-party orders. **Exceptions:** hides an exception only when it is tied to orders and *every* one of them is known to be non-third-party. Exceptions about suppliers, stock, integrations and other things that are not about an order always stay visible. An order the system cannot classify is never hidden. **Home:** the key numbers and "What needs attention now" follow the focus (the Production, Stock and Third-party pulse panels are not filtered).
- **Default:** on while in-house production is switched off, off when it is on. Once someone clicks the button their choice is remembered in that browser and wins. Each person has their own setting.
- A direct link to a hidden order or exception still opens it. On 8 Nov 2026 live data this hid 152 of 208 open exceptions.
- Code: `lib/focus.ts` (rules, with unit tests), `data/focus.ts`, `components/FocusBar.tsx`.

## Not built yet
Orders outside the 60 days back / 30 days ahead window keep whatever flag they had, a rule for mixed orders (some lines each way), muting more in-house exceptions than machine downtime, and hiding the in-house pages entirely (they show an explanation instead).
