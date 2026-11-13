-- Jobs that the decorator posts straight to the customer ("direct dispatch"):
--  1. The decorator can now see where to send it. Only for direct jobs, only after they have accepted the job, and only until it is closed.
--     The address comes from the order (DecoNetwork), or from a manual fallback on the order (orders.ship_to_override) for orders that have none.
--  2. A decorator cannot mark a direct job complete until they have added a photo of the finished goods (evidence kind "finished"),
--     because nobody here sees those goods before the customer does. Staff can still record steps on a decorator's behalf.
alter table flow.orders add column if not exists ship_to_override text;

-- the dispatch screens use the same fallback
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.dispatch_address(uuid)'::regprocedure) into v_def;
  if v_def not like '%ship_to_override%' then
    v_def := replace(v_def, 'nullif(btrim(coalesce(u.shipping_address, '''')), '''')', 'coalesce(nullif(btrim(coalesce(u.shipping_address, '''')), ''''), nullif(btrim(coalesce(o.ship_to_override, '''')), ''''))');
    if v_def not like '%ship_to_override%' then raise exception 'dispatch_address anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

do $$
declare v_def text;
begin
  select pg_get_functiondef('public.portal_job(text)'::regprocedure) into v_def;
  if v_def not like '%''ship_to''%' then
    v_def := replace(v_def, '''accepted_at'', m.portal_accepted_at,',
      '''ship_to'', case when m.movement_type = ''direct_dispatch_to_customer'' and m.portal_accepted_at is not null and m.status <> ''closed'' then coalesce((
          select jsonb_agg(jsonb_build_object(''order_ref'', x.order_ref, ''customer'', x.customer_name, ''address'', x.addr, ''shipping_method'', x.method) order by x.order_ref)
          from (select distinct on (o.id) o.order_ref, o.customer_name,
                       coalesce(nullif(btrim(coalesce(u.shipping_address, '''')), ''''), nullif(btrim(coalesce(o.ship_to_override, '''')), '''')) as addr,
                       coalesce(nullif(btrim(coalesce(u.shipping_method, '''')), ''''), o.shipping_method) as method
                from flow.tp_movement_items i join flow.orders o on o.id = i.order_id left join public.upcoming_orders u on u.order_id = o.deco_order_id
                where i.movement_id = m.id order by o.id) x), ''[]''::jsonb) else null end,
    ''accepted_at'', m.portal_accepted_at,');
    if v_def not like '%''ship_to''%' then raise exception 'portal_job anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

do $$
declare v_def text;
begin
  select pg_get_functiondef('public.portal_stage(text,text,text,date)'::regprocedure) into v_def;
  if v_def not like '%photo of the finished goods%' then
    v_def := replace(v_def, 'elsif p_stage = ''production_complete'' then',
      'elsif p_stage = ''production_complete'' then
    if m.movement_type = ''direct_dispatch_to_customer'' and not exists (select 1 from flow.tp_evidence e where e.movement_id = m.id and e.kind = ''finished'') then
      return jsonb_build_object(''ok'', false, ''needs_photo'', true, ''error'', ''This job goes straight to the customer, so add a photo of the finished goods before you mark it complete.'');
    end if;');
    if v_def not like '%photo of the finished goods%' then raise exception 'portal_stage anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;
