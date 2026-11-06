# Courier monitoring and claims (R9)

There is no courier connection. A person records what the courier says, and the system keeps the history and chases what is still open.

- **Events** (`flow.courier_events`): collected, delivered, failed attempt, delayed, wrong address, partly delivered, damaged, lost, note. Each belongs to a consignment and a leg (to producer, back from producer, to customer). Anything other than collected or delivered needs the courier's words (5+ characters). Events are written to the consignment timeline and audit log.
- **Exception** `courier_problem`: raised while the latest event on an open consignment is a problem (lost or damaged are critical). A later delivered or collected event clears it.
- **Claims** (`flow.courier_claims`): manager/admin opens a claim with a value and a note (`CLM-yymmdd-nnn`); one open claim per kind per consignment. Status moves submitted, then paid (with the amount recovered), rejected or closed (both need a reason). A claim open for 14 days raises `courier_claim_stale`.
- **Where:** the Courier section of the consignment drawer. Writes use the unpublished Operations actions workflow (`courier_event`, `claim_open`, `claim_update`).
- **Not built:** automatic tracking, sending the claim to the courier, customer notifications, and matching claim payments to accounts.
