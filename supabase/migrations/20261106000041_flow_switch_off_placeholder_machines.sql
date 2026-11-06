-- The DTF, DTG, UV and Packing machines were placeholders; the business does not have them (confirmed 6 Nov 2026).
-- Switched off, not removed, so history and any job steps that point at them stay intact. Reversible by setting is_active back to true.
update flow.machines set is_active = false, notes = 'Switched off 6 Nov 2026: placeholder, the business does not have this machine.' where code in ('DTF-1', 'DTG-1', 'UV-1', 'PACK-1');
