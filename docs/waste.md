# Waste and loss

One place to record, approve, recover and monitor everything that was lost, spoiled or written off. It lives in its own ledger
(`flow.waste_events`), not in stock, because DecoNetwork overwrites stock levels on every sync.

## Recording
- **Record waste** (Waste & loss page): where it happened, cause, whose fault, units, SKU, optional order and decorator, and a written reason.
  The cost comes from the stock cost table (`sku_costs`). A SKU with no cost is recorded at £0 and flagged with a warning so it is not silently hidden.
- **Check for waste** looks through records that already exist and *suggests* waste: units scrapped in rework, units a decorator reported damaged
  when they checked goods in, and courier claims for lost or damaged parcels. Suggestions never count until a person confirms them (or dismisses them with a reason).
  Running the check twice never creates duplicates.

## Control
- Anything over the limit (default more than 25 units or more than £100, setting `waste.approval`) waits for a manager or admin, who approves it or rejects it with a reason.
- A record linked to an order can ask for replacement stock; it is flagged and audited once.
- A manager can record money recovered from a decorator, supplier or courier, optionally against a courier claim. It can never exceed the cost.
- Every step writes to the audit trail with who and why.

## Monitoring
- Overview: cost and units for 30 days, recovered and net loss, waiting for approval, weekly trend, and breakdowns by cause, stage, whose fault, decorator, order, operator, machine and SKU. Approved waste only.
- Waste rate per decorator: approved waste as a share of units sent over 90 days. Over target (default 3%, setting `waste.targets`, at least 50 units sent) raises the exception **Waste rate over target**.
- Waste waiting for approval for more than two days raises **Waste waiting for approval**.
- The Records table exports to CSV.

## Not built yet
- Decorators reporting spoilage themselves from the portal (their damaged count at check-in already feeds suggestions).
- Photo evidence on a waste record (the field exists; there is no upload yet).
- Per-process and per-decorator targets (one default target applies to everyone).
- Settings screen for the thresholds (change the two settings rows for now).

n8n: actions `waste_record`, `waste_confirm`, `waste_decide`, `waste_recover`, `waste_replacement`, `waste_suggest` are in the Operations actions workflow (still unpublished).
