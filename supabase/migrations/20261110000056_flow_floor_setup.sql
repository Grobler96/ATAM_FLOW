-- Floor set-up as told by the business (9 Nov 2026): the three presses all do DTF; Happy 6 head and Toyota 1 head do
-- embroidery; Beth and Sam do print (DTF); Gill does embroidery; third-party decorators do DTF.
-- Data only. Skill rows are retired with removed_at (never removed), so the history stays.
update flow.machines set method_code = 'dtf' where code in ('PRESS-BLACK', 'PRESS-ADKINS', 'PRESS-SILVER') and method_code is distinct from 'dtf';

update flow.operator_skills set removed_at = now(), set_by = 'floor set-up 9 Nov', note = 'Not part of this person''s job (told by the business)'
 where removed_at is null and kind = 'method' and (
   (operator_id = (select id from flow.operators where name = 'Gill Pick') and ref <> 'embroidery') or
   (operator_id in (select id from flow.operators where name in ('Sam Trew', 'Beth Harman')) and ref <> 'dtf'));

insert into flow.operator_skills (operator_id, kind, ref, level, note, set_by)
select o.id, 'method', 'dtf', 3, 'Print (told by the business); level 3 assumed, adjust if needed', 'floor set-up 9 Nov' from flow.operators o where o.name = 'Beth Harman'
on conflict (operator_id, kind, ref) do update set removed_at = null, set_by = excluded.set_by, level = greatest(flow.operator_skills.level, 3)
  where flow.operator_skills.removed_at is not null or flow.operator_skills.level < 3;
