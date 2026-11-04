-- Hardening: pin search_path on flow helper/trigger functions (Supabase linter 0011).
alter function flow.est_minutes(int, text[], int)           set search_path = flow, public;
alter function flow.touch_updated_at()                      set search_path = flow, public;
alter function flow.block_ledger_mutation()                 set search_path = flow, public;
alter function flow.log_on_hand_change()                    set search_path = flow, public;
alter function flow.map_processes(text[])                   set search_path = flow, public;
alter function flow.garment_type(text)                      set search_path = flow, public;
alter function flow.po_delivery_status(int)                 set search_path = flow, public;
alter function flow.guard_allocation()                      set search_path = flow, public;
alter function flow.generate_bins(text, text, int, flow.location_type, int, int) set search_path = flow, public;
