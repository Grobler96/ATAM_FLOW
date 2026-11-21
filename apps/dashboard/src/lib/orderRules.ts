import type { Tone } from '../ui/primitives';

// Order tags and routing rules (shadow mode). The database checks each order against the tag rules and then the routing rules, and records what
// WOULD happen. Nothing here changes an order. These are the read models and the plain words for the screens.
export interface TagRow { order_id: string; order_ref: string; tag_code: string; label: string; quantity: number | null; evidence: string | null; set_at: string }
export interface DecisionRow {
  order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; outcome: Outcome; rule_name: string | null; would_scope: string | null;
  would_producer_id: string | null; would_producer_name: string | null; current_scope: string; current_source: string; detail: string | null; evaluated_at: string; decoration_count: number | null
}
export interface RoutingRuleRow { id: string; position: number; name: string; kind: string; params: Record<string, unknown>; outcome_scope: string; producer_id: string | null; producer_name: string | null; is_active: boolean; created_at: string; created_by: string | null; mode: string }
export interface TagRuleRow { id: string; tag_code: string; tag_label: string; name: string; kind: string; params: Record<string, unknown>; is_active: boolean; created_at: string; created_by: string | null }
export type Outcome = 'no_rule_matched' | 'would_change' | 'already_matches' | 'manual_wins' | 'protected';

export const OUTCOME_LABEL: Record<string, string> = { would_change: 'Would move', protected: 'Left alone', already_matches: 'Already right', manual_wins: 'Set by hand', no_rule_matched: 'No rule applies' };
export const outcomeLabel = (o: string) => OUTCOME_LABEL[o] ?? o.replace(/_/g, ' ');
export const outcomeTone = (o: string): Tone => (o === 'would_change' ? 'high' : o === 'protected' ? 'medium' : o === 'already_matches' ? 'good' : o === 'manual_wins' ? 'info' : '');

// What each outcome means, in plain words (shown under the table and in the drawer).
export const OUTCOME_HELP: Record<string, string> = {
  would_change: 'A rule matches and this order is not set that way yet. If rules were switched on, the order would move.',
  protected: 'A rule matches, but the order has already been dispatched or has work started, so it would be left alone and flagged.',
  already_matches: 'A rule matches and the order is already set that way (for example it is already third party).',
  manual_wins: 'A person set this order\'s scope by hand, which always wins over a rule.',
  no_rule_matched: 'No routing rule applies to this order.'
};

export const SCOPE_LABEL: Record<string, string> = { third_party: 'Third party', in_house: 'In house', out_of_scope: 'Out of scope', unclassified: 'Not decided' };
export const scopeLabel = (s: string | null | undefined) => (s ? SCOPE_LABEL[s] ?? s.replace(/_/g, ' ') : '—');
export const SOURCE_LABEL: Record<string, string> = { override: 'set by hand', deco_flag: 'DecoNetwork Priority flag', none: 'nothing decided it' };
export const sourceLabel = (s: string) => SOURCE_LABEL[s] ?? s;

// "More than 20 decorations", "A name is filled in on 'Uniform For'", …
export function conditionText(kind: string, params: Record<string, unknown> | null | undefined): string {
  const p = params ?? {};
  if (kind === 'decorations_over') return `More than ${String(p.n ?? '?')} decorations on the whole order`;
  if (kind === 'units_over') return `More than ${String(p.n ?? '?')} units on the whole order`;
  if (kind === 'custom_field_filled') return `A name is filled in on "${String(p.field ?? '?')}"`;
  if (kind === 'tag_present') return `The order has the tag "${String(p.tag ?? '?')}"`;
  return kind.replace(/_/g, ' ');
}
export function resultText(scope: string, producerName: string | null): string {
  return scope === 'in_house' ? 'Make it in house' : `Send to a third party${producerName ? ': ' + producerName : ''}`;
}

export function decisionCounts(rows: DecisionRow[]) {
  const c = { total: rows.length, would_change: 0, protected: 0, already_matches: 0, manual_wins: 0, no_rule_matched: 0 };
  for (const r of rows) if (r.outcome in c) (c as Record<string, number>)[r.outcome]++;
  return c;
}
export const tagsFor = (tags: TagRow[], orderId: string | null | undefined): TagRow[] => (orderId ? tags.filter((t) => t.order_id === orderId).sort((a, b) => a.label.localeCompare(b.label)) : []);
export const decisionFor = (rows: DecisionRow[], orderId: string | null | undefined): DecisionRow | null => (orderId ? rows.find((r) => r.order_id === orderId) ?? null : null);
export const tagText = (t: Pick<TagRow, 'label' | 'quantity'>): string => (t.quantity != null && t.quantity > 0 ? `${t.label} · ${t.quantity}` : t.label);
// Order of the rules table: the one that runs first is at the top.
export const rulesInOrder = (rules: RoutingRuleRow[]): RoutingRuleRow[] => [...rules].sort((a, b) => a.position - b.position || a.created_at.localeCompare(b.created_at));
// What a person reviewing the shadow run should look at first.
export const needsLook = (r: DecisionRow): boolean => r.outcome === 'would_change';
