import { reasonOk } from './makeThirdParty';
import type { RoutingRuleRow } from './orderRules';

// The forms for adding or changing a routing rule or a tag rule. The database checks everything again; these checks only save a round trip and
// say what is wrong in plain words before anything is sent.
export interface KindDef { id: string; label: string; needs: 'n' | 'field' | 'tag' | 'method'; unit: string }
export const ROUTING_KINDS: KindDef[] = [
  { id: 'decorations_over', label: 'The order has more decorations than…', needs: 'n', unit: 'decorations (added up over the whole order)' },
  { id: 'units_over', label: 'The order has more units than…', needs: 'n', unit: 'units' },
  { id: 'tag_present', label: 'The order has the tag…', needs: 'tag', unit: '' },
  { id: 'custom_field_filled', label: 'A name is filled in on the custom field…', needs: 'field', unit: '' },
  { id: 'method_includes', label: 'The order uses the process…', needs: 'method', unit: '' }
];
export const TAG_KINDS: KindDef[] = ROUTING_KINDS.filter((k) => k.id !== 'tag_present');
export const kindDef = (id: string): KindDef | undefined => ROUTING_KINDS.find((k) => k.id === id);

export interface ParamInput { n: string; field: string; tag: string; method?: string }
// The settings object the database stores for a condition, or null when the value is not usable yet.
export function paramsFor(kind: string, v: ParamInput): Record<string, unknown> | null {
  const k = kindDef(kind); if (!k) return null;
  if (k.needs === 'n') return /^\d{1,6}$/.test(v.n.trim()) ? { n: Number(v.n.trim()) } : null;
  if (k.needs === 'field') return v.field.trim() ? { field: v.field.trim() } : null;
  if (k.needs === 'method') return (v.method ?? '').trim() ? { method: (v.method ?? '').trim().toLowerCase() } : null;
  return v.tag.trim() ? { tag: v.tag.trim() } : null;
}
export function valueFromParams(_kind: string, params: Record<string, unknown> | null | undefined): ParamInput {
  const p = params ?? {}; return { n: p.n == null ? '' : String(p.n), field: p.field == null ? '' : String(p.field), tag: p.tag == null ? '' : String(p.tag), method: p.method == null ? '' : String(p.method) };
}

// "Needs folding" -> needs_folding (the code the database uses for a tag)
export function slugCode(label: string): string {
  const s = label.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
  return /^[a-z]/.test(s) ? s.slice(0, 40) : s ? ('t_' + s).slice(0, 40) : '';
}
// Rules are checked lowest number first; a new rule goes after the others by default.
export function nextPosition(rules: Pick<RoutingRuleRow, 'position'>[]): number { return rules.length === 0 ? 10 : Math.floor(Math.max(...rules.map((r) => r.position)) / 10) * 10 + 10; }

export interface RoutingForm { name: string; kind: string; value: ParamInput; scope: string; producerId: string; position: string; active: boolean; reason: string }
export function validateRouting(f: RoutingForm): string | null {
  if (!f.name.trim()) return 'Give the rule a name.';
  if (!paramsFor(f.kind, f.value)) return kindDef(f.kind)?.needs === 'n' ? 'Give a whole number for "more than".' : kindDef(f.kind)?.needs === 'tag' ? 'Choose a tag.' : kindDef(f.kind)?.needs === 'method' ? 'Give the name of the process, for example dtf.' : 'Give the name of the custom field.';
  if (!/^\d{1,6}$/.test(f.position.trim())) return 'Give the rule a position: a whole number, lowest is checked first.';
  if (f.scope === 'in_house' && f.producerId) return 'A rule that makes an order in house has no producer.';
  if (!reasonOk(f.reason)) return 'Give a reason (at least 5 characters). It is recorded in the audit trail.';
  return null;
}
export interface TagForm { tagCode: string; tagLabel: string; isNew: boolean; name: string; kind: string; value: ParamInput; active: boolean; reason: string }
export function validateTag(f: TagForm): string | null {
  if (f.isNew && !f.tagLabel.trim()) return 'Give the new tag a label.';
  if (f.isNew && !slugCode(f.tagLabel)) return 'The tag label needs some letters or numbers.';
  if (!f.isNew && !f.tagCode) return 'Choose a tag.';
  if (!f.name.trim()) return 'Give the rule a name.';
  if (!paramsFor(f.kind, f.value)) return kindDef(f.kind)?.needs === 'n' ? 'Give a whole number for "more than".' : kindDef(f.kind)?.needs === 'method' ? 'Give the name of the process, for example dtf.' : 'Give the name of the custom field.';
  if (!reasonOk(f.reason)) return 'Give a reason (at least 5 characters). It is recorded in the audit trail.';
  return null;
}

// What goes to the n8n action (the database function names its own arguments)
export function routingParams(f: RoutingForm, id: string | null): Record<string, unknown> {
  return { id, name: f.name.trim(), kind: f.kind, params: paramsFor(f.kind, f.value), scope: f.scope, producer_id: f.scope === 'third_party' && f.producerId ? f.producerId : null, position: Number(f.position.trim()), active: f.active, reason: f.reason.trim() };
}
export function tagParams(f: TagForm, id: string | null): Record<string, unknown> {
  return { id, tag_code: f.isNew ? slugCode(f.tagLabel) : f.tagCode, tag_label: f.isNew ? f.tagLabel.trim() : null, name: f.name.trim(), kind: f.kind, params: paramsFor(f.kind, f.value), active: f.active, reason: f.reason.trim() };
}
