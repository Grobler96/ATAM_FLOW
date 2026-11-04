-- Exceptions engine. One list for everything that is wrong, late, missing or unknown, each with an owner, a deadline, an escalation level,
-- money and customer impact, and a full audit trail. Detectors raise and auto-resolve exceptions from the records we already keep;
-- people work them through the action functions. Unresolved blocking exceptions stop an order being completed (order_completion_check).
-- Deadlines, ladders and thresholds are PLACEHOLDERS in flow_settings 'exceptions.config' until the business supplies real ones.

create sequence flow.exception_seq start 1;

create table flow.exception_types (
  code            text primary key,
  label           text not null,
  category        text not null check (category in ('stock','purchasing','producer','artwork','production','quality','logistics','integration','order','data','other')),
  default_severity text not null check (default_severity in ('low','medium','high','critical')),
  blocks          text[] not null default '{}',              -- what an unresolved exception of this type stops: completion, dispatch, production, assignment
  deadline_hours  int,                                       -- null = use the severity default
  owner_role      flow.app_role not null default 'manager',
  recommended_action text,
  is_active       boolean not null default true
);

create table flow.exceptions (
  id              uuid primary key default gen_random_uuid(),
  exc_ref         text not null unique,
  type_code       text not null references flow.exception_types(code),
  dedupe_key      text not null,
  detector        text,                                      -- null = raised by a person
  severity        text not null check (severity in ('low','medium','high','critical')),
  status          text not null default 'open' check (status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer','resolved','cancelled','written_off')),
  blocks          text[] not null default '{}',
  root_cause      text check (root_cause in ('supplier','producer','courier','customer','internal_process','artwork','machine','data_integration','quality','unknown')),
  description     text not null,
  detected_by     text not null default 'automation' check (detected_by in ('automation','warehouse_user','producer_portal','customer','supplier','manual_review')),
  detected_at     timestamptz not null default now(),
  owner           text,                                      -- named person (email / user id); null until assigned
  owner_role      flow.app_role,                             -- who is responsible until someone is named
  response_deadline timestamptz not null,
  escalation_level int not null default 0,
  escalated_at    timestamptz,
  customer_impact text,
  financial_impact numeric(12,2),
  financial_breakdown jsonb not null default '{}'::jsonb,
  recommended_action text,
  resolution_method text,
  resolution_note text,
  resolved_at     timestamptz,
  resolved_by     text,
  auto_resolved   boolean not null default false,
  source_type     text,                                      -- the detailed record this was raised from
  source_id       text,
  details         jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index exceptions_open_key on flow.exceptions (dedupe_key) where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer');
create index exceptions_status on flow.exceptions (status, severity);
create index exceptions_type on flow.exceptions (type_code, status);
create index exceptions_deadline on flow.exceptions (response_deadline) where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer');
create index exceptions_key_history on flow.exceptions (dedupe_key, created_at desc);

create table flow.exception_links (
  id           bigint generated always as identity primary key,
  exception_id uuid not null references flow.exceptions(id) on delete cascade,
  link_type    text not null check (link_type in ('order','order_line','sku','po','po_line','movement','machine','producer','supplier','communication','artwork','stock_item')),
  ref_id       uuid,
  ref_text     text
);
create unique index exception_links_uq on flow.exception_links (exception_id, link_type, coalesce(ref_id::text, ref_text));
create index exception_links_ref on flow.exception_links (link_type, ref_id);

create table flow.exception_actions (                          -- append-only audit trail / actions taken
  id           bigint generated always as identity primary key,
  exception_id uuid not null references flow.exceptions(id) on delete cascade,
  at           timestamptz not null default now(),
  actor        text,
  action       text not null,
  from_status  text,
  to_status    text,
  note         text,
  detail       jsonb not null default '{}'::jsonb
);
create index exception_actions_exc on flow.exception_actions (exception_id, at);
create or replace function flow.block_exception_log_mutation() returns trigger language plpgsql as $$
begin raise exception 'the exception audit trail is append-only'; end $$;
create trigger exception_actions_immutable before update or delete on flow.exception_actions for each row execute function flow.block_exception_log_mutation();
create trigger exceptions_touch before update on flow.exceptions for each row execute function flow.touch_updated_at();

alter table flow.exception_types enable row level security;
alter table flow.exceptions enable row level security;
alter table flow.exception_links enable row level security;
alter table flow.exception_actions enable row level security;
create policy exception_types_read on flow.exception_types for select to authenticated using (flow.is_member());
create policy exception_types_cfg_write on flow.exception_types for all to authenticated using (flow.has_role('admin','manager')) with check (flow.has_role('admin','manager'));
create policy exceptions_read on flow.exceptions for select to authenticated using (flow.is_member());
create policy exception_links_read on flow.exception_links for select to authenticated using (flow.is_member());
create policy exception_actions_read on flow.exception_actions for select to authenticated using (flow.is_member());
grant select on flow.exception_types, flow.exceptions, flow.exception_links, flow.exception_actions to authenticated;
grant insert, update on flow.exception_types to authenticated;
grant all on flow.exception_types, flow.exceptions, flow.exception_links, flow.exception_actions to service_role;
grant usage, select on all sequences in schema flow to authenticated, service_role;

insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('supplier_shortage', 'Supplier shortage', 'stock', 'high', '{completion,dispatch}', 'warehouse', 'Ask the supplier for the missing units urgently or a credit with the earliest replacement date, then decide whether to wait, reorder elsewhere, use an approved alternative or tell the customer.'),
 ('supplier_damage', 'Damaged goods from supplier', 'stock', 'high', '{completion,dispatch}', 'warehouse', 'Photograph the damage, ask the supplier for replacements or a credit, and check whether affected orders can still be met.'),
 ('supplier_incorrect', 'Incorrect goods from supplier', 'stock', 'high', '{completion,dispatch}', 'warehouse', 'Quarantine the wrong items, ask the supplier for the correct ones and collection of the wrong ones, or a credit.'),
 ('supplier_overage', 'Over-delivery from supplier', 'stock', 'low', '{}', 'warehouse', 'Decide whether to keep the extra units and be invoiced, or arrange collection.'),
 ('supplier_other', 'Supplier discrepancy', 'purchasing', 'medium', '{}', 'warehouse', 'Investigate with the supplier and record the outcome.'),
 ('po_late', 'Purchase order late', 'purchasing', 'medium', '{}', 'warehouse', 'Check whether it has arrived but was not booked in; otherwise chase the supplier for a firm date.'),
 ('po_unacknowledged', 'Purchase order not acknowledged', 'purchasing', 'medium', '{}', 'warehouse', 'Chase the supplier to confirm the order and delivery date.'),
 ('stock_shortage', 'Stock shortage with no cover', 'stock', 'medium', '{}', 'manager', 'Raise a purchase order, or use an approved alternative, or tell the customer.'),
 ('artwork_blocked', 'Artwork not ready', 'artwork', 'high', '{production,dispatch,completion}', 'production', 'Fix the listed artwork problems (upload or replace the file, get approval) and rebuild the producer job pack.'),
 ('producer_discrepancy', 'Producer discrepancy', 'producer', 'high', '{}', 'manager', 'Contact the producer, request proof and a return date, and decide whether to re-source or tell the customer.'),
 ('producer_no_receipt', 'Producer has not confirmed receipt', 'producer', 'high', '{}', 'manager', 'Call the producer, check the courier tracking, ask for a photo of the goods, and prepare an alternative producer.'),
 ('movement_no_tracking', 'Dispatched without tracking', 'logistics', 'medium', '{}', 'warehouse', 'Add the carrier and tracking reference, or record who is carrying the goods.'),
 ('order_at_risk', 'Order at risk of missing dispatch', 'production', 'high', '{}', 'manager', 'Remove the cause (stock, artwork, capacity) or agree a new date with the customer.'),
 ('sync_failed', 'Integration run failed', 'integration', 'high', '{}', 'admin', 'Look at the error, fix the cause and re-run the sync.'),
 ('sync_stale', 'Integration has not run', 'integration', 'high', '{}', 'admin', 'Check the workflow is published and its schedule is running; run it manually.'),
 ('email_failed', 'Email failed to send', 'integration', 'medium', '{}', 'manager', 'Check the recipient and mailbox connection, then resend from the communication log.'),
 ('unknown_deco_status', 'Unrecognised DecoNetwork status', 'data', 'medium', '{}', 'admin', 'Add the status code to the status map so orders using it have a known meaning.'),
 ('completed_with_open_exception', 'Order completed with an open blocking issue', 'order', 'critical', '{}', 'manager', 'Resolve or formally accept the open issue(s) and confirm the order really is complete.'),
 ('integrity_custody', 'Units with an unknown holder', 'data', 'high', '{completion}', 'warehouse', 'Find out who physically holds the units and correct the custody record.'),
 ('integrity_stock', 'Stock record is inconsistent', 'data', 'high', '{}', 'warehouse', 'Count the stock and correct the record with a recorded adjustment.'),
 ('integrity_po', 'Purchase order is missing key information', 'data', 'medium', '{}', 'warehouse', 'Add the missing expected date or detail.'),
 ('integrity_order', 'Order is missing key information', 'data', 'medium', '{}', 'manager', 'Add the missing due date or detail in DecoNetwork.'),
 ('order_hold_unexplained', 'Orders on hold with no recorded reason', 'order', 'low', '{}', 'manager', 'Record why each order is on hold and who is responsible for releasing it.'),
 ('manual_review', 'Raised by a person', 'other', 'medium', '{}', 'manager', 'See the description.');

insert into flow.flow_settings (key, value, description) values
 ('exceptions.config', '{
   "severity_deadline_hours": {"critical": 4, "high": 24, "medium": 72, "low": 168},
   "escalation_ladder_hours": {"critical": [2, 4], "high": [12, 24], "medium": [24, 48], "low": [72]},
   "escalation_owner_roles": ["manager", "admin"],
   "reopen_window_days": 7, "suppress_after_cancel_days": 30,
   "thresholds": {"artwork_horizon_days": 7, "po_unack_hours": 48, "producer_receipt_hours": 24, "tracking_grace_days": 1,
                  "order_risk_horizon_days": 7, "stock_shortage_horizon_days": 7, "po_late_high_days": 14},
   "sync_watch": {"sync_orders": {"max_age_minutes": 150}, "sync_stock": {"max_age_minutes": 400}, "sync_purchase_orders": {"max_age_minutes": 400}, "allocation": {"max_age_minutes": 150}}
 }'::jsonb, 'PLACEHOLDER values until the business sets real ones: response deadlines and escalation steps by severity, detector thresholds, and how long each integration may go without a successful run.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Core: raise (idempotent), links, log
-- ---------------------------------------------------------------------------
create or replace function flow.exc_cfg() returns jsonb language sql stable set search_path = flow, public as $$ select coalesce(flow.setting('exceptions.config'), '{}'::jsonb) $$;
create or replace function flow.exc_sev_rank(p text) returns int language sql immutable as $$ select case p when 'critical' then 1 when 'high' then 2 when 'medium' then 3 else 4 end $$;
create or replace function flow.exc_log(p_id uuid, p_actor text, p_action text, p_from text, p_to text, p_note text, p_detail jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = flow, public as $$
  insert into flow.exception_actions (exception_id, actor, action, from_status, to_status, note, detail) values (p_id, p_actor, p_action, p_from, p_to, p_note, coalesce(p_detail, '{}'::jsonb))
$$;
create or replace function flow.exc_add_links(p_id uuid, p_links jsonb) returns int language plpgsql security definer set search_path = flow, public as $$
declare l jsonb; n int := 0; c int;
begin
  for l in select * from jsonb_array_elements(coalesce(p_links, '[]'::jsonb)) loop
    if l->>'id' is null and l->>'text' is null then continue; end if;
    insert into flow.exception_links (exception_id, link_type, ref_id, ref_text) values (p_id, l->>'type', nullif(l->>'id', '')::uuid, l->>'text') on conflict do nothing;
    get diagnostics c = row_count; n := n + c;
  end loop;
  return n;
end $$;

-- p_opts: severity, status, deadline, owner, owner_role, root_cause, detected_by, customer_impact, financial_impact, financial_breakdown, recommended_action,
--         blocks (array), source_type, source_id, details
create or replace function flow.exc_raise(p_type text, p_key text, p_detector text, p_description text, p_links jsonb default '[]'::jsonb, p_opts jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  t flow.exception_types; cfg jsonb := flow.exc_cfg(); cur flow.exceptions; prev flow.exceptions; v_sev text; v_id uuid; v_deadline timestamptz; v_hours int; v_changed boolean := false;
  v_blocks text[]; v_new_links int; v_fin numeric; v_status text;
begin
  select * into t from flow.exception_types where code = p_type;
  if not found then raise exception 'unknown exception type %', p_type; end if;
  v_sev := coalesce(nullif(p_opts->>'severity', ''), t.default_severity);
  v_blocks := coalesce((select array_agg(x) from jsonb_array_elements_text(p_opts->'blocks') x), t.blocks);
  v_fin := nullif(p_opts->>'financial_impact', '')::numeric;
  select * into cur from flow.exceptions where dedupe_key = p_key and status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer');
  if found then
    if flow.exc_sev_rank(v_sev) < flow.exc_sev_rank(cur.severity) then
      update flow.exceptions set severity = v_sev where id = cur.id; v_changed := true;
      perform flow.exc_log(cur.id, 'system', 'severity_raised', null, null, cur.severity || ' -> ' || v_sev);
    end if;
    update flow.exceptions set description = p_description, customer_impact = coalesce(p_opts->>'customer_impact', customer_impact), financial_impact = coalesce(v_fin, financial_impact),
      financial_breakdown = coalesce(p_opts->'financial_breakdown', financial_breakdown), recommended_action = coalesce(p_opts->>'recommended_action', recommended_action),
      details = coalesce(p_opts->'details', details), blocks = v_blocks
      where id = cur.id and (description, customer_impact, financial_impact, financial_breakdown, recommended_action, details, blocks)
        is distinct from (p_description, coalesce(p_opts->>'customer_impact', customer_impact), coalesce(v_fin, financial_impact), coalesce(p_opts->'financial_breakdown', financial_breakdown),
                          coalesce(p_opts->>'recommended_action', recommended_action), coalesce(p_opts->'details', details), v_blocks);
    if found then v_changed := true; end if;
    v_new_links := flow.exc_add_links(cur.id, p_links);
    if v_changed or v_new_links > 0 then perform flow.exc_log(cur.id, 'system', 'updated', null, null, 'condition still present; details refreshed'); end if;
    return jsonb_build_object('id', cur.id, 'created', false, 'changed', v_changed or v_new_links > 0);
  end if;

  select * into prev from flow.exceptions where dedupe_key = p_key order by created_at desc limit 1;
  if found then
    if prev.status in ('written_off','cancelled') and prev.resolved_at > now() - make_interval(days => coalesce((cfg->>'suppress_after_cancel_days')::int, 30)) then
      return jsonb_build_object('id', prev.id, 'created', false, 'suppressed', true);
    end if;
    if prev.status = 'resolved' and not prev.auto_resolved and prev.resolved_at > now() - make_interval(days => coalesce((cfg->>'reopen_window_days')::int, 7)) then
      v_hours := coalesce(t.deadline_hours, (cfg->'severity_deadline_hours'->>prev.severity)::int, 24);
      update flow.exceptions set status = 'open', escalation_level = 0, escalated_at = null, resolved_at = null, resolved_by = null, resolution_method = null,
        response_deadline = now() + make_interval(hours => v_hours) where id = prev.id;
      perform flow.exc_log(prev.id, 'system', 'reopened', 'resolved', 'open', 'it was marked resolved but the condition is still present');
      perform flow.notify('exception_reopened', 'warning', 'Reopened: ' || prev.exc_ref, 'It was resolved but the problem is still there: ' || prev.description, 'exception', prev.id);
      return jsonb_build_object('id', prev.id, 'created', false, 'reopened', true);
    end if;
  end if;

  v_hours := coalesce(t.deadline_hours, (cfg->'severity_deadline_hours'->>v_sev)::int, 24);
  v_deadline := coalesce(nullif(p_opts->>'deadline', '')::timestamptz, now() + make_interval(hours => v_hours));
  if v_deadline < now() then v_deadline := now() + interval '1 hour'; end if;
  v_status := coalesce(nullif(p_opts->>'status', ''), 'open');
  insert into flow.exceptions (exc_ref, type_code, dedupe_key, detector, severity, status, blocks, root_cause, description, detected_by, owner, owner_role, response_deadline,
      customer_impact, financial_impact, financial_breakdown, recommended_action, source_type, source_id, details)
  values ('EXC-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.exception_seq')::text, 5, '0'), p_type, p_key, p_detector, v_sev, v_status, v_blocks, nullif(p_opts->>'root_cause', ''), p_description,
      coalesce(nullif(p_opts->>'detected_by', ''), 'automation'), nullif(p_opts->>'owner', ''), coalesce(nullif(p_opts->>'owner_role', '')::flow.app_role, t.owner_role), v_deadline,
      p_opts->>'customer_impact', v_fin, coalesce(p_opts->'financial_breakdown', '{}'::jsonb), coalesce(p_opts->>'recommended_action', t.recommended_action),
      p_opts->>'source_type', p_opts->>'source_id', coalesce(p_opts->'details', '{}'::jsonb))
  returning id into v_id;
  perform flow.exc_add_links(v_id, p_links);
  perform flow.exc_log(v_id, coalesce(p_detector, 'person'), 'detected', null, v_status, p_description);
  if v_sev in ('high','critical') then
    perform flow.notify('exception_' || v_sev, case when v_sev = 'critical' then 'critical' else 'warning' end, (select exc_ref from flow.exceptions where id = v_id) || ': ' || t.label, p_description, 'exception', v_id);
  end if;
  return jsonb_build_object('id', v_id, 'created', true);
end $$;

-- A detector reports everything currently wrong as rows; anything it raised earlier that is no longer in the rows is closed as cleared.
create or replace function flow.exc_sync(p_detector text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare r jsonb; res jsonb; v_keys text[] := '{}'; v_created int := 0; v_changed int := 0; v_reopened int := 0; v_suppressed int := 0; v_resolved int;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    res := flow.exc_raise(r->>'type', r->>'key', p_detector, r->>'description', coalesce(r->'links', '[]'::jsonb), coalesce(r->'opts', '{}'::jsonb));
    v_keys := array_append(v_keys, r->>'key');
    if (res->>'created')::boolean then v_created := v_created + 1;
    elsif coalesce((res->>'reopened')::boolean, false) then v_reopened := v_reopened + 1;
    elsif coalesce((res->>'suppressed')::boolean, false) then v_suppressed := v_suppressed + 1;
    elsif coalesce((res->>'changed')::boolean, false) then v_changed := v_changed + 1; end if;
  end loop;
  with c as (
    update flow.exceptions set status = 'resolved', resolved_at = now(), resolved_by = 'system', resolution_method = 'auto: condition cleared at source', auto_resolved = true
    where detector = p_detector and status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer') and not (dedupe_key = any (v_keys))
    returning id, status)
  insert into flow.exception_actions (exception_id, actor, action, from_status, to_status, note) select id, 'system', 'auto_resolved', null, 'resolved', 'the condition no longer exists at the source' from c;
  get diagnostics v_resolved = row_count;
  return jsonb_build_object('detector', p_detector, 'found', coalesce(jsonb_array_length(p_rows), 0), 'created', v_created, 'updated', v_changed, 'reopened', v_reopened, 'suppressed', v_suppressed, 'auto_resolved', v_resolved);
end $$;

-- ---------------------------------------------------------------------------
-- Detectors (each returns the rows that should currently be open)
-- ---------------------------------------------------------------------------
create or replace function flow.exc_cost(p_sku text) returns numeric language sql stable security definer set search_path = flow, public as $$
  select coalesce((select unit_cost from public.sku_costs where sku = p_sku), 0)
$$;

create or replace function flow.exc_detect_supplier() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', case d.disc_type when 'shortage' then 'supplier_shortage' when 'damaged' then 'supplier_damage' when 'incorrect' then 'supplier_incorrect' when 'overage' then 'supplier_overage' else 'supplier_other' end,
    'key', 'supdisc:' || d.id,
    'description', format('%s: %s x %s on PO %s (%s)', initcap(d.disc_type), d.qty, d.sku, coalesce(p.af_po_ref, p.po_number), coalesce(p.supplier, 'supplier')),
    'links', jsonb_build_array(jsonb_build_object('type', 'po', 'id', p.id), jsonb_build_object('type', 'sku', 'text', d.sku), jsonb_build_object('type', 'po_line', 'id', d.po_line_id))
             || case when d.supplier_id is not null then jsonb_build_array(jsonb_build_object('type', 'supplier', 'id', d.supplier_id)) else '[]'::jsonb end
             || coalesce((select jsonb_agg(jsonb_build_object('type', 'order', 'id', x->>'order_id')) from jsonb_array_elements(d.affected_orders) x where x->>'order_id' is not null), '[]'::jsonb)
             || case when d.communication_id is not null then jsonb_build_array(jsonb_build_object('type', 'communication', 'id', d.communication_id)) else '[]'::jsonb end,
    'opts', jsonb_build_object(
      'severity', case when d.disc_type = 'overage' then 'low' when exists (select 1 from jsonb_array_elements(d.affected_orders) x where (x->>'due_date')::date <= current_date + 1) then 'critical' else 'high' end,
      'status', case when d.status = 'awaiting_supplier' then 'awaiting_supplier' else 'open' end,
      'deadline', case when d.required_by is not null then ((d.required_by::timestamp + interval '17 hours') at time zone 'Europe/London')::text end,
      'root_cause', 'supplier', 'detected_by', case when d.origin = 'producer' then 'producer_portal' else 'warehouse_user' end,
      'financial_impact', round(d.qty * coalesce(pl.unit_cost, 0), 2), 'financial_breakdown', jsonb_build_object('stock_cost', round(d.qty * coalesce(pl.unit_cost, 0), 2)),
      'customer_impact', case when jsonb_array_length(d.affected_orders) > 0 then format('%s order(s) affected, earliest due %s', jsonb_array_length(d.affected_orders), (select min((x->>'due_date')::date) from jsonb_array_elements(d.affected_orders) x)) else 'No customer order identified yet' end,
      'source_type', 'supplier_discrepancy', 'source_id', d.id::text)) order by d.opened_at), '[]'::jsonb)
  from flow.supplier_discrepancies d join flow.purchase_orders p on p.id = d.po_id join flow.po_lines pl on pl.id = d.po_line_id
  where d.status in ('open','awaiting_supplier')
$$;

create or replace function flow.exc_detect_producer_discrepancies() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', 'producer_discrepancy', 'key', 'tpdisc:' || td.id,
    'description', format('%s: %s x %s with %s (%s)', initcap(td.disc_type::text), td.qty, coalesce(l.sku, 'item'), pr.name, m.movement_code),
    'links', jsonb_build_array(jsonb_build_object('type', 'movement', 'id', td.movement_id), jsonb_build_object('type', 'producer', 'id', td.producer_id),
                               jsonb_build_object('type', 'order', 'id', td.order_id), jsonb_build_object('type', 'order_line', 'id', td.order_line_id))
             || case when l.sku is not null then jsonb_build_array(jsonb_build_object('type', 'sku', 'text', l.sku)) else '[]'::jsonb end,
    'opts', jsonb_build_object(
      'severity', case td.disc_type::text when 'lost' then 'critical' when 'late' then 'medium' when 'overage' then 'low' else 'high' end,
      'status', 'awaiting_producer', 'root_cause', 'producer', 'detected_by', 'warehouse_user',
      'blocks', case when td.blocks_completion then jsonb_build_array('completion', 'dispatch') else '[]'::jsonb end,
      'financial_impact', round(td.qty * flow.exc_cost(l.sku), 2), 'financial_breakdown', jsonb_build_object('blank_cost', round(td.qty * flow.exc_cost(l.sku), 2)),
      'customer_impact', format('Order %s due %s', o.order_ref, (o.due_date at time zone 'Europe/London')::date),
      'source_type', 'tp_discrepancy', 'source_id', td.id::text)) order by td.opened_at), '[]'::jsonb)
  from flow.tp_discrepancies td join flow.producers pr on pr.id = td.producer_id join flow.tp_movements m on m.id = td.movement_id
  left join flow.order_lines l on l.id = td.order_line_id left join flow.orders o on o.id = td.order_id
  where td.status in ('open','investigating')
$$;

create or replace function flow.exc_detect_artwork() returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare cfg jsonb := flow.exc_cfg(); v_h int := coalesce((cfg->'thresholds'->>'artwork_horizon_days')::int, 7); o record; v_rows jsonb := '[]'::jsonb; v_n int; v_types text; v_first text; v_days int;
begin
  for o in select ord.id, ord.order_ref, ord.due_date, ord.order_value from flow.orders ord
           where ord.is_active and ord.order_status <> 'dispatched' and exists (select 1 from flow.order_lines l where l.order_id = ord.id and cardinality(l.decoration_methods) > 0)
             and (ord.due_date::date <= current_date + v_h or ord.order_status in ('ready_for_production','in_production','quality_check','ready_for_dispatch')) loop
    select count(*), string_agg(distinct issue, ', '), min(coalesce(area, method, 'order') || ': ' || detail) into v_n, v_types, v_first from flow.artwork_issues(o.id) where severity = 'blocking';
    if v_n > 0 then
      v_days := (o.due_date::date - current_date);
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'artwork_blocked', 'key', 'artwork:' || o.id,
        'description', format('Order %s: %s artwork problem(s) (%s). First: %s', o.order_ref, v_n, v_types, v_first),
        'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', o.id)),
        'opts', jsonb_build_object('severity', case when v_days <= 2 then 'critical' else 'high' end, 'root_cause', 'artwork', 'financial_impact', o.order_value,
           'financial_breakdown', jsonb_build_object('revenue_at_risk', o.order_value), 'customer_impact', format('Cannot be released to production; due %s', (o.due_date at time zone 'Europe/London')::date),
           'details', jsonb_build_object('issue_count', v_n, 'issue_types', v_types))));
    end if;
  end loop;
  return v_rows;
end $$;

create or replace function flow.exc_detect_purchasing() returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare cfg jsonb := flow.exc_cfg(); v_late_high int := coalesce((cfg->'thresholds'->>'po_late_high_days')::int, 14); v_unack int := coalesce((cfg->'thresholds'->>'po_unack_hours')::int, 48); v_rows jsonb := '[]'::jsonb; r record;
begin
  for r in select * from flow.v_overdue_pos loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'po_late', 'key', 'po_late:' || r.po_id,
      'description', format('PO %s from %s is %s day(s) late; %s unit(s) outstanding, %s promised to orders', r.po_number, coalesce(r.supplier, 'supplier'), r.days_overdue, r.units_outstanding, r.units_promised_to_orders),
      'links', jsonb_build_array(jsonb_build_object('type', 'po', 'id', r.po_id)),
      'opts', jsonb_build_object('severity', case when r.days_overdue >= v_late_high then 'high' else 'medium' end, 'root_cause', 'supplier',
        'customer_impact', case when r.units_promised_to_orders > 0 then format('%s unit(s) reserved for orders: %s', r.units_promised_to_orders, array_to_string(r.orders_waiting, ', ')) else null end,
        'recommended_action', r.suggestion)));
  end loop;
  for r in select p.id, p.af_po_ref, p.supplier, p.sent_at from flow.purchase_orders p
           where p.origin = 'atam_flow' and p.po_status = 'sent' and p.acknowledged_at is null and p.sent_at < now() - make_interval(hours => v_unack) loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'po_unacknowledged', 'key', 'po_unack:' || r.id,
      'description', format('PO %s sent to %s on %s has not been acknowledged', r.af_po_ref, coalesce(r.supplier, 'supplier'), to_char(r.sent_at, 'DD Mon HH24:MI')),
      'links', jsonb_build_array(jsonb_build_object('type', 'po', 'id', r.id)), 'opts', jsonb_build_object('root_cause', 'supplier')));
  end loop;
  return v_rows;
end $$;

create or replace function flow.exc_detect_stock_shortage() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('type', 'stock_shortage', 'key', 'shortage:' || s.sku,
    'description', format('%s is short of %s unit(s) (%s on hand, %s on order); earliest due %s', s.sku, s.units_short, s.on_hand, s.on_order, s.earliest_due),
    'links', jsonb_build_array(jsonb_build_object('type', 'sku', 'text', s.sku))
             || coalesce((select jsonb_agg(jsonb_build_object('type', 'order', 'id', o.id)) from flow.orders o where o.order_ref = any (s.order_refs)), '[]'::jsonb),
    'opts', jsonb_build_object('severity', case when s.earliest_due <= current_date + 3 then 'high' else 'medium' end, 'root_cause', 'supplier',
      'financial_impact', round(s.units_short * flow.exc_cost(s.sku), 2), 'financial_breakdown', jsonb_build_object('stock_to_buy', round(s.units_short * flow.exc_cost(s.sku), 2)),
      'customer_impact', format('%s order(s) waiting', s.orders_affected))) order by s.earliest_due), '[]'::jsonb)
  from flow.v_shortages s
  where s.earliest_due <= current_date + coalesce((flow.exc_cfg()->'thresholds'->>'stock_shortage_horizon_days')::int, 7)
$$;

create or replace function flow.exc_detect_orders_at_risk() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('type', 'order_at_risk', 'key', 'risk:' || x.id,
    'description', format('Order %s (%s) is at risk: %s', x.order_ref, coalesce(x.customer_name, 'customer'), array_to_string(x.reasons, '; ')),
    'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', x.id)),
    'opts', jsonb_build_object('severity', case when x.days_to_due <= 0 then 'critical' when x.days_to_due <= 2 then 'high' else 'medium' end, 'root_cause', 'unknown',
      'financial_impact', x.order_value, 'financial_breakdown', jsonb_build_object('revenue_at_risk', x.order_value),
      'customer_impact', case when x.days_to_due < 0 then format('Already %s day(s) past the promised dispatch date', -x.days_to_due) when x.days_to_due = 0 then 'Due for dispatch today' else format('Promised dispatch in %s day(s)', x.days_to_due) end)) order by x.days_to_due), '[]'::jsonb)
  from (
    select o.id, o.order_ref, o.customer_name, o.order_value, (o.due_date::date - current_date) as days_to_due,
      array_remove(array[
        case when o.due_date::date < current_date then 'already past its due date' end,
        case when (d.score_breakdown->>'late_risk') = 'true' then 'stock is projected to arrive after the due date' end,
        case when exists (select 1 from flow.job_steps js where js.order_id = o.id and js.is_late and js.status <> 'complete') then 'production is scheduled to finish after the due date' end
      ], null) as reasons
    from flow.orders o
    left join lateral (select dd.score_breakdown from flow.allocation_decisions dd where dd.order_id = o.id and dd.order_line_id is null order by dd.created_at desc limit 1) d on true
    where o.is_active and o.order_status <> 'dispatched' and o.due_date is not null
      and o.due_date::date <= current_date + coalesce((flow.exc_cfg()->'thresholds'->>'order_risk_horizon_days')::int, 7)
  ) x
  where cardinality(x.reasons) > 0
$$;

create or replace function flow.exc_detect_sync() returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare w record; v_rows jsonb := '[]'::jsonb; v_last flow.flow_runs; v_ok timestamptz; v_max int; v_age numeric;
begin
  for w in select key, value from jsonb_each(coalesce(flow.exc_cfg()->'sync_watch', '{}'::jsonb)) loop
    v_max := coalesce((w.value->>'max_age_minutes')::int, 240);
    select * into v_last from flow.flow_runs where workflow = w.key and status <> 'skipped' order by started_at desc limit 1;
    select max(started_at) into v_ok from flow.flow_runs where workflow = w.key and status in ('success','partial');
    v_age := case when v_ok is null then null else extract(epoch from (now() - v_ok)) / 60 end;
    if v_last.id is not null and v_last.status = 'failed' then
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'sync_failed', 'key', 'sync:' || w.key,
        'description', format('%s failed at %s: %s', w.key, to_char(v_last.started_at, 'DD Mon HH24:MI'), left(coalesce(v_last.error, 'no error recorded'), 200)),
        'links', '[]'::jsonb, 'opts', jsonb_build_object('root_cause', 'data_integration', 'details', jsonb_build_object('workflow', w.key, 'run_id', v_last.id))));
    elsif v_ok is null or v_age > v_max then
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'sync_stale', 'key', 'sync:' || w.key,
        'description', case when v_ok is null then format('%s has never run successfully', w.key) else format('%s has not succeeded for %s minutes (allowed %s)', w.key, round(v_age), v_max) end,
        'links', '[]'::jsonb, 'opts', jsonb_build_object('severity', case when v_ok is null or v_age > v_max * 3 then 'critical' else 'high' end, 'root_cause', 'data_integration',
          'customer_impact', 'Dashboard data may be out of date', 'details', jsonb_build_object('workflow', w.key))));
    end if;
  end loop;
  return v_rows;
end $$;

create or replace function flow.exc_detect_logistics() returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare cfg jsonb := flow.exc_cfg(); v_h int := coalesce((cfg->'thresholds'->>'producer_receipt_hours')::int, 24); v_g int := coalesce((cfg->'thresholds'->>'tracking_grace_days')::int, 1); v_rows jsonb := '[]'::jsonb; m record;
begin
  for m in select mv.id, mv.movement_code, mv.dispatch_date, mv.producer_id, pr.name as producer_name,
            (select coalesce(sum(i.qty_sent), 0) from flow.tp_movement_items i where i.movement_id = mv.id) as units,
            (select coalesce(sum(i.qty_sent * flow.exc_cost(i.sku)), 0) from flow.tp_movement_items i where i.movement_id = mv.id) as stock_value,
            (select min(o.due_date::date) from flow.tp_movement_items i join flow.orders o on o.id = i.order_id where i.movement_id = mv.id) as earliest_due,
            (select coalesce(jsonb_agg(distinct jsonb_build_object('type', 'order', 'id', i.order_id)), '[]'::jsonb) from flow.tp_movement_items i where i.movement_id = mv.id) as order_links
           from flow.tp_movements mv join flow.producers pr on pr.id = mv.producer_id
           where mv.movement_type = 'outbound_to_producer' and mv.status = 'dispatched' and mv.received_by_producer_at is null and mv.dispatch_date is not null
             and mv.dispatch_date::timestamp < (now() at time zone 'Europe/London') - make_interval(hours => v_h) loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'producer_no_receipt', 'key', 'noreceipt:' || m.id,
      'description', format('%s has not confirmed receipt of %s unit(s) dispatched on %s (%s)', m.producer_name, m.units, m.dispatch_date, m.movement_code),
      'links', jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id), jsonb_build_object('type', 'producer', 'id', m.producer_id)) || m.order_links,
      'opts', jsonb_build_object('severity', case when m.dispatch_date < current_date - 3 or m.earliest_due <= current_date + 2 then 'critical' else 'high' end, 'status', 'awaiting_producer', 'root_cause', 'producer',
        'financial_impact', round(m.stock_value, 2), 'financial_breakdown', jsonb_build_object('stock_exposed', round(m.stock_value, 2)),
        'customer_impact', case when m.earliest_due is not null then format('Earliest affected order due %s', m.earliest_due) end)));
  end loop;
  for m in select mv.id, mv.movement_code, mv.dispatch_date from flow.tp_movements mv
           where mv.status in ('dispatched','in_transit_back') and mv.tracking_ref is null and coalesce(mv.return_tracking_ref, '') = '' and coalesce(mv.carrier, '') not in ('own_van','collection')
             and mv.dispatch_date is not null and mv.dispatch_date < current_date - v_g loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'movement_no_tracking', 'key', 'notrack:' || m.id,
      'description', format('Movement %s dispatched on %s has no tracking reference', m.movement_code, m.dispatch_date),
      'links', jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id)), 'opts', jsonb_build_object('root_cause', 'internal_process')));
  end loop;
  return v_rows;
end $$;

create or replace function flow.exc_detect_system() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('type', 'email_failed', 'key', 'email:' || c.id, 'description', format('Email "%s" (%s) failed: %s', left(c.subject, 80), c.comm_ref, left(coalesce(c.error, 'no detail'), 150)),
      'links', jsonb_build_array(jsonb_build_object('type', 'communication', 'id', c.id)), 'opts', jsonb_build_object('root_cause', 'data_integration')) as x
    from flow.communications c where c.status = 'failed'
    union all
    select jsonb_build_object('type', 'unknown_deco_status', 'key', 'decostatus:' || o.deco_status, 'description', format('%s active order(s) have DecoNetwork status %s which is not in the status map', count(*), o.deco_status),
      'links', (select coalesce(jsonb_agg(jsonb_build_object('type', 'order', 'id', z.id)), '[]'::jsonb) from (select id from flow.orders where is_active and deco_status = o.deco_status limit 20) z),
      'opts', jsonb_build_object('root_cause', 'data_integration'))
    from flow.orders o where o.is_active and o.deco_status is not null and not exists (select 1 from flow.deco_status_map m where m.code = o.deco_status) group by o.deco_status
  ) q
$$;

create or replace function flow.exc_detect_integrity() returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare v_rows jsonb := '[]'::jsonb; r record; v_n int; v_links jsonb;
begin
  for r in select c.id, c.qty, c.location_state::text as st, l.sku, l.order_id, c.order_line_id from flow.stock_custody c join flow.order_lines l on l.id = c.order_line_id
           where c.qty > 0 and c.location_state in ('picked_for_producer','in_transit_to_producer','at_producer','in_production_at_producer','in_transit_back') and (c.movement_id is null or c.producer_id is null) loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'integrity_custody', 'key', 'int_cust:' || r.id,
      'description', format('%s unit(s) of %s are recorded as "%s" but the movement or producer is unknown', r.qty, r.sku, replace(r.st, '_', ' ')),
      'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', r.order_id), jsonb_build_object('type', 'order_line', 'id', r.order_line_id), jsonb_build_object('type', 'sku', 'text', r.sku)),
      'opts', jsonb_build_object('root_cause', 'internal_process', 'financial_impact', round(r.qty * flow.exc_cost(r.sku), 2))));
  end loop;
  for r in select s.id, s.sku, s.qty_on_hand + s.qty_pending_receipt as eff from flow.stock_items s where s.qty_on_hand + s.qty_pending_receipt < 0 loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'integrity_stock', 'key', 'int_stock:' || r.id,
      'description', format('%s shows negative stock (%s)', r.sku, r.eff),
      'links', jsonb_build_array(jsonb_build_object('type', 'sku', 'text', r.sku), jsonb_build_object('type', 'stock_item', 'id', r.id)), 'opts', jsonb_build_object('root_cause', 'data_integration')));
  end loop;
  for r in select p.id, coalesce(p.af_po_ref, p.po_number) as ref from flow.purchase_orders p
           where p.is_active and p.expected_date is null and exists (select 1 from flow.po_lines l where l.po_id = p.id and l.qty_outstanding_eff > 0) loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'integrity_po', 'key', 'int_po:' || r.id, 'description', format('PO %s has units outstanding but no expected date', r.ref),
      'links', jsonb_build_array(jsonb_build_object('type', 'po', 'id', r.id)), 'opts', jsonb_build_object('root_cause', 'internal_process')));
  end loop;
  select count(*), coalesce(jsonb_agg(jsonb_build_object('type', 'order', 'id', z.id)), '[]'::jsonb) into v_n, v_links
    from (select id from flow.orders where is_active and order_status <> 'dispatched' and due_date is null order by order_ref limit 200) z;
  if v_n > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'integrity_order', 'key', 'no_due_date',
      'description', format('%s active order(s) have no due date, so their priority, risk and schedule cannot be worked out', (select count(*) from flow.orders where is_active and order_status <> 'dispatched' and due_date is null)),
      'links', v_links, 'opts', jsonb_build_object('root_cause', 'data_integration')));
  end if;
  select count(*), coalesce(jsonb_agg(jsonb_build_object('type', 'order', 'id', z.id)), '[]'::jsonb) into v_n, v_links
    from (select id from flow.orders where is_active and order_status = 'on_hold' and coalesce(btrim(status_reason), '') = '') z;
  if v_n > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('type', 'order_hold_unexplained', 'key', 'hold_unexplained',
      'description', format('%s order(s) are on hold with no recorded reason or owner for the hold', v_n), 'links', v_links, 'opts', jsonb_build_object('root_cause', 'unknown')));
  end if;
  return v_rows;
end $$;

-- Orders that DecoNetwork (or anyone) has completed while blocking exceptions are still open.
create or replace function flow.exc_detect_completed_open() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('type', 'completed_with_open_exception', 'key', 'completed_open:' || g.id,
    'description', format('Order %s is marked dispatched/shipped but has %s unresolved blocking issue(s): %s', g.order_ref, g.n, g.refs),
    'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', g.id)), 'opts', jsonb_build_object('root_cause', 'internal_process'))), '[]'::jsonb)
  from (
    select o.id, o.order_ref, count(distinct e.id) as n, string_agg(distinct e.exc_ref, ', ') as refs
    from flow.orders o
    join flow.exception_links el on el.link_type = 'order' and el.ref_id = o.id
    join flow.exceptions e on e.id = el.exception_id and e.status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer') and 'completion' = any (e.blocks)
    where o.order_status = 'dispatched' or o.deco_status = 3
    group by o.id, o.order_ref
  ) g
$$;

-- Runs every detector. completed_open must run last because it reads the blocking exceptions the others raise.
create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb;
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity'] loop
    begin
      execute format('select flow.exc_detect_%s()', d) into v_rows;
      v_res := v_res || jsonb_build_array(flow.exc_sync('detector:' || d, v_rows));
    exception when others then
      v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:' || d, 'error', sqlerrm));
      perform flow.notify('detector_failed', 'warning', 'Exception detector failed: ' || d, sqlerrm, null, null);
    end;
  end loop;
  -- must run last: it reads the blocking exceptions the others just raised
  begin
    v_res := v_res || jsonb_build_array(flow.exc_sync('detector:completed_open', flow.exc_detect_completed_open()));
  exception when others then v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:completed_open', 'error', sqlerrm));
  end;
  return jsonb_build_object('ok', not exists (select 1 from jsonb_array_elements(v_res) x where x ? 'error'), 'at', now(), 'detectors', v_res,
    'open_now', (select count(*) from flow.exceptions where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')),
    'critical_open', (select count(*) from flow.exceptions where severity = 'critical' and status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')));
end $$;

-- Move overdue exceptions up the ladder; each step gets a new deadline and a more senior responsible role. Idempotent.
create or replace function flow.exceptions_escalate() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare cfg jsonb := flow.exc_cfg(); e record; v_lad jsonb; v_max int; v_hrs int; v_roles jsonb := coalesce(cfg->'escalation_owner_roles', '["manager","admin"]'::jsonb); v_role text; v_n int := 0; v_items jsonb := '[]'::jsonb;
begin
  for e in select * from flow.exceptions where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer') and response_deadline < now() order by response_deadline loop
    v_lad := coalesce(cfg->'escalation_ladder_hours'->e.severity, '[24]'::jsonb);
    v_max := jsonb_array_length(v_lad);
    if e.escalation_level >= v_max then continue; end if;
    v_hrs := (v_lad->>e.escalation_level)::int;
    v_role := v_roles->>least(e.escalation_level, jsonb_array_length(v_roles) - 1);
    update flow.exceptions set escalation_level = escalation_level + 1, escalated_at = now(), response_deadline = now() + make_interval(hours => v_hrs), owner_role = v_role::flow.app_role where id = e.id;
    perform flow.exc_log(e.id, 'system', 'escalated', null, null, format('no response by the deadline: escalated to level %s, now with %s, new deadline in %s h', e.escalation_level + 1, v_role, v_hrs));
    perform flow.notify('exception_escalated', case when e.severity in ('high','critical') then 'critical' else 'warning' end, 'Escalated: ' || e.exc_ref, e.description, 'exception', e.id);
    v_n := v_n + 1; v_items := v_items || jsonb_build_array(jsonb_build_object('exc_ref', e.exc_ref, 'level', e.escalation_level + 1, 'role', v_role));
  end loop;
  return jsonb_build_object('ok', true, 'escalated', v_n, 'items', v_items);
end $$;

-- ---------------------------------------------------------------------------
-- Working an exception
-- ---------------------------------------------------------------------------
create or replace function flow.exc_unresolved(p text) returns boolean language sql immutable as $$ select p in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer') $$;

create or replace function flow.assign_exception(p_id uuid, p_owner text, p_actor text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare e flow.exceptions;
begin
  select * into e from flow.exceptions where id = p_id; if not found then return jsonb_build_object('ok', false, 'error', 'exception not found'); end if;
  if not flow.exc_unresolved(e.status) then return jsonb_build_object('ok', false, 'error', 'this exception is already ' || e.status); end if;
  if coalesce(p_owner, '') = '' then return jsonb_build_object('ok', false, 'error', 'an owner is required'); end if;
  update flow.exceptions set owner = p_owner, status = case when status = 'open' then 'investigating' else status end where id = p_id;
  perform flow.exc_log(p_id, p_actor, 'assigned', e.status, case when e.status = 'open' then 'investigating' else e.status end, coalesce(p_note, 'assigned to ' || p_owner), jsonb_build_object('previous_owner', e.owner, 'owner', p_owner));
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.set_exception_status(p_id uuid, p_status text, p_actor text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare e flow.exceptions;
begin
  select * into e from flow.exceptions where id = p_id; if not found then return jsonb_build_object('ok', false, 'error', 'exception not found'); end if;
  if not flow.exc_unresolved(p_status) then return jsonb_build_object('ok', false, 'error', 'use resolve, cancel or write-off to close an exception'); end if;
  if not flow.exc_unresolved(e.status) then return jsonb_build_object('ok', false, 'error', 'this exception is already ' || e.status || ': reopen it first'); end if;
  update flow.exceptions set status = p_status where id = p_id;
  perform flow.exc_log(p_id, p_actor, 'status', e.status, p_status, p_note);
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.add_exception_note(p_id uuid, p_actor text, p_note text, p_is_action boolean default false) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  if coalesce(p_note, '') = '' then return jsonb_build_object('ok', false, 'error', 'a note is required'); end if;
  if not exists (select 1 from flow.exceptions where id = p_id) then return jsonb_build_object('ok', false, 'error', 'exception not found'); end if;
  perform flow.exc_log(p_id, p_actor, case when p_is_action then 'action_taken' else 'note' end, null, null, p_note);
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.link_exception_communication(p_id uuid, p_comm uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  if not exists (select 1 from flow.communications where id = p_comm) then return jsonb_build_object('ok', false, 'error', 'communication not found'); end if;
  perform flow.exc_add_links(p_id, jsonb_build_array(jsonb_build_object('type', 'communication', 'id', p_comm)));
  perform flow.exc_log(p_id, p_actor, 'communication_linked', null, null, (select comm_ref || ': ' || subject from flow.communications where id = p_comm));
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.resolve_exception(p_id uuid, p_method text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare e flow.exceptions;
begin
  select * into e from flow.exceptions where id = p_id; if not found then return jsonb_build_object('ok', false, 'error', 'exception not found'); end if;
  if not flow.exc_unresolved(e.status) then return jsonb_build_object('ok', false, 'error', 'this exception is already ' || e.status); end if;
  if coalesce(p_note, '') = '' or coalesce(p_method, '') = '' then return jsonb_build_object('ok', false, 'error', 'a resolution method and a note are required'); end if;
  if p_method not in ('fixed','replacement_received','credit_issued','rework_complete','rerouted','customer_agreed','supplier_resolved','producer_resolved','no_action_needed','other') then
    return jsonb_build_object('ok', false, 'error', 'unknown resolution method'); end if;
  update flow.exceptions set status = 'resolved', resolved_at = now(), resolved_by = p_actor, resolution_method = p_method, resolution_note = p_note, auto_resolved = false where id = p_id;
  perform flow.exc_log(p_id, p_actor, 'resolved', e.status, 'resolved', p_note, jsonb_build_object('method', p_method));
  return jsonb_build_object('ok', true, 'note', 'If the underlying problem is still there the next detection run will reopen this.');
end $$;

create or replace function flow.write_off_exception(p_id uuid, p_reason text, p_financial_impact numeric, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare e flow.exceptions;
begin
  select * into e from flow.exceptions where id = p_id; if not found then return jsonb_build_object('ok', false, 'error', 'exception not found'); end if;
  if not flow.exc_unresolved(e.status) then return jsonb_build_object('ok', false, 'error', 'this exception is already ' || e.status); end if;
  if coalesce(p_reason, '') = '' or p_financial_impact is null then return jsonb_build_object('ok', false, 'error', 'a reason and the amount written off are required'); end if;
  update flow.exceptions set status = 'written_off', resolved_at = now(), resolved_by = p_actor, resolution_method = 'written_off', resolution_note = p_reason, financial_impact = p_financial_impact, auto_resolved = false where id = p_id;
  perform flow.exc_log(p_id, p_actor, 'written_off', e.status, 'written_off', p_reason, jsonb_build_object('financial_impact', p_financial_impact));
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.cancel_exception(p_id uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare e flow.exceptions;
begin
  select * into e from flow.exceptions where id = p_id; if not found then return jsonb_build_object('ok', false, 'error', 'exception not found'); end if;
  if not flow.exc_unresolved(e.status) then return jsonb_build_object('ok', false, 'error', 'this exception is already ' || e.status); end if;
  if coalesce(p_reason, '') = '' then return jsonb_build_object('ok', false, 'error', 'a reason is required'); end if;
  update flow.exceptions set status = 'cancelled', resolved_at = now(), resolved_by = p_actor, resolution_method = 'cancelled', resolution_note = p_reason, auto_resolved = false where id = p_id;
  perform flow.exc_log(p_id, p_actor, 'cancelled', e.status, 'cancelled', p_reason);
  return jsonb_build_object('ok', true, 'note', 'The detector will not raise this same issue again for 30 days.');
end $$;

create or replace function flow.reopen_exception(p_id uuid, p_actor text, p_reason text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare e flow.exceptions; v_hours int;
begin
  select * into e from flow.exceptions where id = p_id; if not found then return jsonb_build_object('ok', false, 'error', 'exception not found'); end if;
  if flow.exc_unresolved(e.status) then return jsonb_build_object('ok', false, 'error', 'this exception is already open'); end if;
  if coalesce(p_reason, '') = '' then return jsonb_build_object('ok', false, 'error', 'a reason is required'); end if;
  if exists (select 1 from flow.exceptions x where x.dedupe_key = e.dedupe_key and flow.exc_unresolved(x.status)) then return jsonb_build_object('ok', false, 'error', 'a newer exception for the same problem is already open'); end if;
  v_hours := coalesce((select deadline_hours from flow.exception_types where code = e.type_code), (flow.exc_cfg()->'severity_deadline_hours'->>e.severity)::int, 24);
  update flow.exceptions set status = 'open', escalation_level = 0, escalated_at = null, resolved_at = null, resolved_by = null, resolution_method = null, resolution_note = null, auto_resolved = false,
    response_deadline = now() + make_interval(hours => v_hours) where id = p_id;
  perform flow.exc_log(p_id, p_actor, 'reopened', e.status, 'open', p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.raise_manual_exception(p_category text, p_severity text, p_description text, p_links jsonb, p_owner text, p_deadline timestamptz, p_actor text, p_blocks text[] default '{}') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_res jsonb;
begin
  if coalesce(p_description, '') = '' then return jsonb_build_object('ok', false, 'error', 'a description is required'); end if;
  if p_severity not in ('low','medium','high','critical') then return jsonb_build_object('ok', false, 'error', 'severity must be low, medium, high or critical'); end if;
  v_res := flow.exc_raise('manual_review', 'manual:' || gen_random_uuid(), null, p_description, coalesce(p_links, '[]'::jsonb),
    jsonb_build_object('severity', p_severity, 'owner', p_owner, 'deadline', p_deadline::text, 'detected_by', 'manual_review', 'blocks', to_jsonb(coalesce(p_blocks, '{}'::text[]))));
  perform flow.exc_log((v_res->>'id')::uuid, p_actor, 'raised_by_person', null, 'open', p_category);
  return jsonb_build_object('ok', true, 'id', v_res->>'id');
end $$;

-- ---------------------------------------------------------------------------
-- No order completes while a blocking exception is open
-- ---------------------------------------------------------------------------
create or replace function flow.order_blocking_exceptions(p_order uuid, p_block text default 'completion') returns jsonb
language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'exc_ref', e.exc_ref, 'type', e.type_code, 'severity', e.severity, 'status', e.status, 'description', e.description) order by flow.exc_sev_rank(e.severity), e.detected_at), '[]'::jsonb)
  from flow.exceptions e join flow.exception_links el on el.exception_id = e.id and el.link_type = 'order' and el.ref_id = p_order
  where e.status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer') and p_block = any (e.blocks)
$$;

create or replace function flow.order_completion_check(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare v_open int; v_routed int; v_at_prod int; v_unchecked int; v_ready int; v_done int; v_written_off int; v_blockers jsonb := '[]'::jsonb; v_exc jsonb; v_exc_dispatch jsonb;
begin
  select count(*) into v_open from flow.tp_discrepancies where order_id = p_order and status in ('open','investigating') and blocks_completion;
  select coalesce(sum(rl.qty), 0) into v_routed from flow.route_lines rl join flow.production_routes r on r.id = rl.route_id
    where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed';
  select coalesce(sum(c.qty) filter (where c.location_state in ('picked_for_producer','in_transit_to_producer','at_producer','in_production_at_producer','in_transit_back')), 0),
         coalesce(sum(c.qty) filter (where c.location_state = 'returned_to_warehouse'), 0),
         coalesce(sum(c.qty) filter (where c.location_state = 'ready_for_dispatch'), 0),
         coalesce(sum(c.qty) filter (where c.location_state = 'dispatched_to_customer'), 0)
    into v_at_prod, v_unchecked, v_ready, v_done
    from flow.stock_custody c join flow.order_lines l on l.id = c.order_line_id where l.order_id = p_order;
  select coalesce(sum(qty), 0) into v_written_off from flow.tp_discrepancies where order_id = p_order and status = 'written_off';
  v_exc := flow.order_blocking_exceptions(p_order, 'completion');
  v_exc_dispatch := flow.order_blocking_exceptions(p_order, 'dispatch');
  if v_open > 0 then v_blockers := v_blockers || jsonb_build_array(format('%s open discrepancy record(s)', v_open)); end if;
  if v_at_prod > 0 then v_blockers := v_blockers || jsonb_build_array(format('%s unit(s) still with or travelling to/from a producer', v_at_prod)); end if;
  if v_unchecked > 0 then v_blockers := v_blockers || jsonb_build_array(format('%s returned unit(s) not yet checked', v_unchecked)); end if;
  if v_ready > 0 then v_blockers := v_blockers || jsonb_build_array(format('%s checked unit(s) waiting to be dispatched', v_ready)); end if;
  if v_routed > 0 and v_done + v_written_off < v_routed then
    v_blockers := v_blockers || jsonb_build_array(format('%s of %s routed unit(s) accounted for (dispatched or written off)', v_done + v_written_off, v_routed));
  end if;
  if jsonb_array_length(v_exc) > 0 then
    v_blockers := v_blockers || jsonb_build_array(format('%s unresolved blocking exception(s): %s', jsonb_array_length(v_exc), (select string_agg(x->>'exc_ref', ', ') from jsonb_array_elements(v_exc) x)));
  end if;
  return jsonb_build_object('order_id', p_order, 'routed_units', v_routed, 'with_producer_units', v_at_prod, 'unchecked_units', v_unchecked,
    'ready_units', v_ready, 'dispatched_units', v_done, 'written_off_units', v_written_off, 'open_discrepancies', v_open,
    'blocking_exceptions', v_exc,
    'can_dispatch_partial', v_ready > 0 and v_open = 0 and jsonb_array_length(v_exc_dispatch) = 0,
    'can_dispatch_all', v_open = 0 and v_at_prod = 0 and v_unchecked = 0 and v_ready > 0 and v_done + v_ready + v_written_off >= v_routed and jsonb_array_length(v_exc_dispatch) = 0,
    'can_complete', jsonb_array_length(v_blockers) = 0, 'blockers', v_blockers);
end $$;

-- ---------------------------------------------------------------------------
-- Every order has a known status, owner, location and next action
-- ---------------------------------------------------------------------------
create or replace view flow.v_order_accountability with (security_invoker = true) as
select o.id as order_id, o.order_ref, o.customer_name, o.due_date::date as due_date, o.order_status::text as status,
       coalesce(o.assigned_to, 'role: ' || case when o.order_status in ('awaiting_stock','stock_allocated') then 'warehouse' when o.order_status in ('ready_for_production','in_production','quality_check') then 'production'
                                                  when o.order_status = 'ready_for_dispatch' then 'warehouse' else 'manager' end) as owner,
       case when exists (select 1 from flow.stock_custody c join flow.order_lines l on l.id = c.order_line_id where l.order_id = o.id and c.qty > 0 and c.producer_id is not null
                         and c.location_state in ('at_producer','in_production_at_producer','in_transit_to_producer','in_transit_back'))
            then 'With producer: ' || (select string_agg(distinct pr.name, ', ') from flow.stock_custody c join flow.order_lines l on l.id = c.order_line_id join flow.producers pr on pr.id = c.producer_id
                                         where l.order_id = o.id and c.qty > 0 and c.location_state in ('at_producer','in_production_at_producer','in_transit_to_producer','in_transit_back'))
            when o.order_status = 'dispatched' then 'With customer'
            when o.order_status in ('awaiting_stock','stock_allocated') and not o.stock_secured then 'Not yet in stock (on order or unallocated)'
            when o.order_status = 'in_production' then 'In production'
            when o.order_status in ('ready_for_production','quality_check','ready_for_dispatch') then 'Warehouse'
            else null end as location,
       case when jsonb_array_length(flow.order_blocking_exceptions(o.id, 'completion')) > 0 then 'Resolve blocking issue(s): ' || (select string_agg(x->>'exc_ref', ', ') from jsonb_array_elements(flow.order_blocking_exceptions(o.id, 'completion')) x)
            when o.order_status = 'dispatched' then 'None: complete'
            when o.order_status = 'on_hold' then case when coalesce(btrim(o.status_reason), '') = '' then null else 'Review hold: ' || o.status_reason end
            when o.order_status = 'awaiting_stock' then 'Raise or chase a purchase order for the missing stock'
            when o.order_status = 'stock_allocated' then 'Wait for allocated stock, then release to production'
            when o.order_status = 'ready_for_production' then 'Check artwork and route (in-house or producer), then produce'
            when o.order_status = 'in_production' then 'Finish production and quality check'
            when o.order_status = 'quality_check' then 'Complete the quality check'
            when o.order_status = 'ready_for_dispatch' then 'Pack and dispatch'
            when o.order_status = 'blocked' then 'Resolve what is blocking this order'
            else null end as next_action,
       (select count(*) from flow.exceptions e join flow.exception_links el on el.exception_id = e.id and el.link_type = 'order' and el.ref_id = o.id
         where e.status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')) as open_exceptions
from flow.orders o where o.is_active;

-- ---------------------------------------------------------------------------
-- Dashboard read models
-- ---------------------------------------------------------------------------
create or replace view flow.v_exceptions_open with (security_invoker = true) as
select e.id, e.exc_ref, e.type_code, t.label as type_label, t.category, e.severity, flow.exc_sev_rank(e.severity) as severity_rank, e.status, e.blocks, (cardinality(e.blocks) > 0) as is_blocking,
       e.description, e.detected_by, e.detected_at, e.owner, e.owner_role, (e.owner is null) as needs_owner, e.response_deadline, (e.response_deadline < now()) as is_overdue,
       round(extract(epoch from (now() - e.detected_at)) / 3600, 1) as age_hours,
       case when now() - e.detected_at < interval '1 day' then '< 1 day' when now() - e.detected_at < interval '3 days' then '1-3 days' when now() - e.detected_at < interval '7 days' then '3-7 days' else '> 7 days' end as age_bucket,
       e.escalation_level, e.customer_impact, e.financial_impact, e.financial_breakdown, e.recommended_action, e.root_cause,
       coalesce((select array_agg(distinct o.order_ref order by o.order_ref) from flow.exception_links l join flow.orders o on o.id = l.ref_id where l.exception_id = e.id and l.link_type = 'order'), '{}') as order_refs,
       coalesce((select array_agg(distinct l.ref_text order by l.ref_text) from flow.exception_links l where l.exception_id = e.id and l.link_type = 'sku'), '{}') as skus,
       coalesce((select array_agg(distinct coalesce(p.af_po_ref, p.po_number)) from flow.exception_links l join flow.purchase_orders p on p.id = l.ref_id where l.exception_id = e.id and l.link_type = 'po'), '{}') as po_refs,
       coalesce((select array_agg(distinct m.movement_code) from flow.exception_links l join flow.tp_movements m on m.id = l.ref_id where l.exception_id = e.id and l.link_type = 'movement'), '{}') as movement_refs,
       coalesce((select array_agg(distinct pr.name) from flow.exception_links l join flow.producers pr on pr.id = l.ref_id where l.exception_id = e.id and l.link_type = 'producer'), '{}') as producers,
       (select count(*) from flow.exception_links l where l.exception_id = e.id and l.link_type = 'communication') as communications
from flow.exceptions e join flow.exception_types t on t.code = e.type_code
where e.status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer');

create or replace view flow.v_exception_summary with (security_invoker = true) as
select category, severity, status, count(*) as n, count(*) filter (where is_overdue) as overdue, count(*) filter (where is_blocking) as blocking, count(*) filter (where needs_owner) as unowned,
       coalesce(sum(financial_impact), 0) as financial_impact
from flow.v_exceptions_open group by category, severity, status;

create or replace view flow.v_exception_history with (security_invoker = true) as
select a.exception_id, e.exc_ref, a.at, a.actor, a.action, a.from_status, a.to_status, a.note, a.detail from flow.exception_actions a join flow.exceptions e on e.id = a.exception_id;

-- ---------------------------------------------------------------------------
-- n8n wrappers + permissions
-- ---------------------------------------------------------------------------
create or replace function public.flow_exceptions_detect_all() returns jsonb language sql security definer set search_path = flow, public as $$ select flow.exceptions_detect_all() $$;
create or replace function public.flow_exceptions_escalate() returns jsonb language sql security definer set search_path = flow, public as $$ select flow.exceptions_escalate() $$;
create or replace function public.flow_assign_exception(p_id uuid, p_owner text, p_actor text, p_note text default null) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.assign_exception(p_id, p_owner, p_actor, p_note) $$;
create or replace function public.flow_set_exception_status(p_id uuid, p_status text, p_actor text, p_note text default null) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.set_exception_status(p_id, p_status, p_actor, p_note) $$;
create or replace function public.flow_add_exception_note(p_id uuid, p_actor text, p_note text, p_is_action boolean default false) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.add_exception_note(p_id, p_actor, p_note, p_is_action) $$;
create or replace function public.flow_link_exception_communication(p_id uuid, p_comm uuid, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.link_exception_communication(p_id, p_comm, p_actor) $$;
create or replace function public.flow_resolve_exception(p_id uuid, p_method text, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.resolve_exception(p_id, p_method, p_note, p_actor) $$;
create or replace function public.flow_write_off_exception(p_id uuid, p_reason text, p_financial_impact numeric, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.write_off_exception(p_id, p_reason, p_financial_impact, p_actor) $$;
create or replace function public.flow_cancel_exception(p_id uuid, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.cancel_exception(p_id, p_reason, p_actor) $$;
create or replace function public.flow_reopen_exception(p_id uuid, p_actor text, p_reason text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.reopen_exception(p_id, p_actor, p_reason) $$;
create or replace function public.flow_raise_manual_exception(p_category text, p_severity text, p_description text, p_links jsonb, p_owner text, p_deadline timestamptz, p_actor text, p_blocks text[] default '{}') returns jsonb language sql security definer set search_path = flow, public as $$ select flow.raise_manual_exception(p_category, p_severity, p_description, p_links, p_owner, p_deadline, p_actor, p_blocks) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'flow.exc_cfg()', 'flow.exc_log(uuid,text,text,text,text,text,jsonb)', 'flow.exc_add_links(uuid,jsonb)', 'flow.exc_raise(text,text,text,text,jsonb,jsonb)', 'flow.exc_sync(text,jsonb)', 'flow.exc_cost(text)',
    'flow.exc_detect_supplier()', 'flow.exc_detect_producer_discrepancies()', 'flow.exc_detect_artwork()', 'flow.exc_detect_purchasing()', 'flow.exc_detect_stock_shortage()', 'flow.exc_detect_orders_at_risk()',
    'flow.exc_detect_sync()', 'flow.exc_detect_logistics()', 'flow.exc_detect_system()', 'flow.exc_detect_integrity()', 'flow.exc_detect_completed_open()', 'flow.exceptions_detect_all()', 'flow.exceptions_escalate()',
    'flow.assign_exception(uuid,text,text,text)', 'flow.set_exception_status(uuid,text,text,text)', 'flow.add_exception_note(uuid,text,text,boolean)', 'flow.link_exception_communication(uuid,uuid,text)',
    'flow.resolve_exception(uuid,text,text,text)', 'flow.write_off_exception(uuid,text,numeric,text)', 'flow.cancel_exception(uuid,text,text)', 'flow.reopen_exception(uuid,text,text)',
    'flow.raise_manual_exception(text,text,text,jsonb,text,timestamptz,text,text[])',
    'public.flow_exceptions_detect_all()', 'public.flow_exceptions_escalate()', 'public.flow_assign_exception(uuid,text,text,text)', 'public.flow_set_exception_status(uuid,text,text,text)',
    'public.flow_add_exception_note(uuid,text,text,boolean)', 'public.flow_link_exception_communication(uuid,uuid,text)', 'public.flow_resolve_exception(uuid,text,text,text)',
    'public.flow_write_off_exception(uuid,text,numeric,text)', 'public.flow_cancel_exception(uuid,text,text)', 'public.flow_reopen_exception(uuid,text,text)',
    'public.flow_raise_manual_exception(text,text,text,jsonb,text,timestamptz,text,text[])']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant select on flow.v_exceptions_open, flow.v_exception_summary, flow.v_exception_history, flow.v_order_accountability to authenticated;
