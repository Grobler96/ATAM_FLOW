-- Buying stock, step 1: supplier cards and shipping options.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000b1', 'manager') on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);

-- 1. a new supplier ---------------------------------------------------------------------------------------------------------------------------------
insert into r select 's0', public.supplier_save(null, '{"name": "  "}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's0'), 'a supplier needs a name');
insert into r select 's1', public.supplier_save(null, '{"name": "Cardtest Textiles", "email": "Orders@CardTest.test", "order_method": "api", "order_method_notes": "API key is in n8n", "lead_time_days": "2", "min_order_value": "150", "contact_name": "Sam", "payment_terms": "30 days", "account_number": "AC123", "website": "https://cardtest.test", "can_deliver_to_producer": true}'::jsonb);
select j->>'id' as s1 from r where k = 's1' \gset
select pg_temp.assert((select (j->>'ok')::bool and (j->>'created')::bool and (j->>'code') like 'CARDTESTTE-%' from r where k = 's1'), 'a supplier is created with a code made from its name: ' || (select j::text from r where k = 's1'));
select pg_temp.assert((select email = 'orders@cardtest.test' and order_method = 'api' and order_method_notes = 'API key is in n8n' and lead_time_days = 2 and min_order_value = 150 and account_number = 'AC123' and can_deliver_to_producer and is_active from public.ui_supplier_cards where id = :'s1'), 'the card holds what was entered, email in lower case');
insert into r select 's2', public.supplier_save(null, '{"name": "cardtest textiles"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's2'), 'the same name twice is refused');
insert into r select 's3', public.supplier_save(:'s1', '{"email": "not an email"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's3'), 'a bad email is refused');
insert into r select 's4', public.supplier_save(:'s1', '{"order_method": "carrier pigeon"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's4'), 'an unknown ordering method is refused');
insert into r select 's5', public.supplier_save(:'s1', '{"lead_time_days": "soon"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's5'), 'a lead time that is not a number is refused');
insert into r select 's6', public.supplier_save(:'s1', '{"phone": "01234 567890", "notes": "Ask for Sam", "min_order_value": ""}'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'created')::bool from r where k = 's6') and (select phone = '01234 567890' and notes = 'Ask for Sam' and min_order_value is null and order_method = 'api' from public.ui_supplier_cards where id = :'s1'), 'changing some fields leaves the rest alone, and an empty value clears a field');
select pg_temp.assert((select count(*) >= 2 from flow.audit_log where entity = 'supplier' and action in ('supplier_created', 'supplier_saved')), 'supplier changes are audited');

-- 2. shipping options -----------------------------------------------------------------------------------------------------------------------------------
insert into r select 'h0', public.supplier_shipping_save(:'s1', null, '{"name": ""}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'h0'), 'an option needs a name');
insert into r select 'h1', public.supplier_shipping_save(:'s1', null, '{"name": "Standard", "cost": "6.95", "free_over": "150", "lead_time_days": "3", "cut_off_time": "14:30"}'::jsonb);
select j->>'id' as h1 from r where k = 'h1' \gset
select pg_temp.assert((select (j->>'ok')::bool and (j->>'is_default')::bool from r where k = 'h1'), 'the first option becomes the default');
select pg_temp.assert((select cost = 6.95 and free_over = 150 and lead_time_days = 3 and cut_off_time = '14:30' and is_default from public.ui_supplier_shipping where id = :'h1'), 'the option holds its cost, free-over amount, lead time and cut-off');
select pg_temp.assert((select delivery_cost = 6.95 and free_delivery_over = 150 from flow.suppliers where id = :'s1'), 'the default option keeps the older delivery fields in step');
insert into r select 'h2', public.supplier_shipping_save(:'s1', null, '{"name": "Next day", "cost": "9.95", "lead_time_days": "1", "cut_off_time": "12:00"}'::jsonb);
select j->>'id' as h2 from r where k = 'h2' \gset
select pg_temp.assert((select not (j->>'is_default')::bool from r where k = 'h2') and (select is_default from public.ui_supplier_shipping where id = :'h1'), 'a second option is not the default');
insert into r select 'h3', public.supplier_shipping_save(:'s1', null, '{"name": "standard", "cost": "1"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'h3'), 'the same option name twice is refused');
insert into r select 'h4', public.supplier_shipping_save(:'s1', null, '{"name": "Pallet", "cost": "-5"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'h4'), 'a negative cost is refused');
insert into r select 'h5', public.supplier_shipping_save(:'s1', null, '{"name": "Pallet", "cost": "20", "cut_off_time": "late"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'h5'), 'a cut-off that is not a time is refused');
insert into r select 'h6', public.supplier_shipping_save(:'s1', :'h2', '{"is_default": true}'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'h6') and (select is_default from public.ui_supplier_shipping where id = :'h2') and not (select is_default from public.ui_supplier_shipping where id = :'h1') and (select count(*) = 1 from public.ui_supplier_shipping where supplier_id = :'s1' and is_default), 'making another option the default switches the old one off, so there is always exactly one');
select pg_temp.assert((select delivery_cost = 9.95 and free_delivery_over is null from flow.suppliers where id = :'s1'), 'the older delivery fields follow the new default');
insert into r select 'h7', public.supplier_shipping_save(:'s1', :'h2', '{"is_active": false}'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'h7') and (select is_default and is_active from public.ui_supplier_shipping where id = :'h1') and not (select is_default or is_active from public.ui_supplier_shipping where id = :'h2'), 'switching the default off promotes the other option');
select pg_temp.assert((select delivery_cost = 6.95 from flow.suppliers where id = :'s1'), 'and the delivery fields follow it');
insert into r select 'h8', public.supplier_shipping_save(:'s1', :'h1', '{"is_active": false}'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'h8') and (select count(*) = 0 from public.ui_supplier_shipping where supplier_id = :'s1' and is_default and is_active) and (select delivery_cost = 0 and free_delivery_over is null from flow.suppliers where id = :'s1'), 'with no option left on there is no default and no delivery fee');
insert into r select 'h9', public.supplier_shipping_save(:'s1', :'h2', '{"is_active": true, "name": "Next day", "cost": "8.50"}'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'is_default')::bool from r where k = 'h9') and (select delivery_cost = 8.50 from flow.suppliers where id = :'s1'), 'switching an option back on makes it the default when there is none');
select pg_temp.assert((select count(*) = 2 from public.ui_supplier_shipping where supplier_id = :'s1'), 'options are switched off, never removed');
insert into r select 'h10', public.supplier_shipping_save(:'s1', gen_random_uuid(), '{"name": "X"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'h10'), 'an option that does not exist is refused');
insert into r select 'h11', public.supplier_shipping_save(gen_random_uuid(), null, '{"name": "X"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'h11'), 'a supplier that does not exist is refused');

-- 3. switching a supplier off -------------------------------------------------------------------------------------------------------------------
insert into r select 'a1', public.supplier_save(:'s1', '{"is_active": false}'::jsonb);
select pg_temp.assert((select not is_active from public.ui_supplier_cards where id = :'s1'), 'a supplier can be switched off, and stays on the list');

-- 4. who may change things ---------------------------------------------------------------------------------------------------------------------------
delete from flow.user_roles where user_id = '00000000-0000-0000-0000-0000000000b1';
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000b1', 'warehouse');
insert into r select 'p1', public.supplier_save(null, '{"name": "Warehouse made this"}'::jsonb);
insert into r select 'p2', public.supplier_shipping_save(:'s1', null, '{"name": "Sneaky"}'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'p1') and not (select (j->>'ok')::bool from r where k = 'p2') and not exists (select 1 from flow.suppliers where name = 'Warehouse made this'), 'a warehouse login cannot add suppliers or options');
delete from flow.user_roles where user_id = '00000000-0000-0000-0000-0000000000b1';
select pg_temp.assert(not has_function_privilege('anon', 'public.supplier_save(uuid,jsonb)', 'execute') and has_function_privilege('authenticated', 'public.supplier_save(uuid,jsonb)', 'execute') and not has_function_privilege('authenticated', 'flow.supplier_save(uuid,jsonb,text)', 'execute') and not has_function_privilege('authenticated', 'flow.supplier_shipping_save(uuid,uuid,jsonb,text)', 'execute') and not has_table_privilege('authenticated', 'flow.supplier_shipping_options', 'insert'), 'the private functions and the table cannot be reached directly');
select 'supplier_cards_test OK';
