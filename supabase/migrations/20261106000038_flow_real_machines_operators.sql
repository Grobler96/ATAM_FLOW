-- Real production machines and operators (supplied by the business, 6 Nov 2026).
-- The embroidery and heat press placeholders are renamed in place so existing job steps keep pointing at them.
update flow.machines set code = 'HAPPY-6', name = 'Happy 6 head', notes = 'Embroidery, 6 heads. Hourly rate is a placeholder to confirm.', machine_type = '6-head embroidery' where code = 'EMB-1';
update flow.machines set code = 'PRESS-BLACK', name = 'Black press', notes = 'Heat press. Hourly rate is a placeholder to confirm.', machine_type = 'heat press' where code = 'HP-1';
insert into flow.machines (code, name, method_code, units_per_hour, machine_type, notes) values
  ('TOYOTA-1', 'Toyota 1 head', 'embroidery', 10, '1-head embroidery', 'Embroidery, 1 head. Hourly rate is a placeholder to confirm.'),
  ('PRESS-ADKINS', 'Adkin''s press', 'heat_press', 60, 'heat press', 'Heat press. Hourly rate is a placeholder to confirm.'),
  ('PRESS-SILVER', 'Silver press', 'heat_press', 60, 'heat press', 'Heat press. Hourly rate is a placeholder to confirm.')
on conflict (code) do nothing;

create table if not exists flow.operators (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  is_active  boolean not null default true,
  notes      text,
  created_at timestamptz not null default now()
);
alter table flow.operators enable row level security;
create policy operators_read on flow.operators for select to authenticated using (flow.is_member());
insert into flow.operators (name) values ('Gill Pick'), ('Sam Trew'), ('Beth Harman') on conflict (name) do nothing;

create or replace view public.ui_operators with (security_invoker = true) as select id, name, is_active, notes from flow.operators;
revoke all on public.ui_operators from public, anon;
grant select on public.ui_operators to authenticated;
