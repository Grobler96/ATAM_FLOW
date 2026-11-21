import { describe, expect, it } from 'vitest';
import { conditionText, decisionCounts, decisionFor, needsLook, outcomeLabel, outcomeTone, resultText, rulesInOrder, scopeLabel, tagText, tagsFor, type DecisionRow, type RoutingRuleRow, type TagRow } from './orderRules';

const dec = (o: Partial<DecisionRow>): DecisionRow => ({ order_id: 'o1', order_ref: '#1', customer_name: 'A', due_date: null, outcome: 'no_rule_matched', rule_name: null, would_scope: null, would_producer_id: null, would_producer_name: null, current_scope: 'unclassified', current_source: 'none', detail: null, evaluated_at: '2026-11-21T00:00:00Z', decoration_count: 0, ...o });
const rule = (o: Partial<RoutingRuleRow>): RoutingRuleRow => ({ id: 'r', position: 10, name: 'x', kind: 'decorations_over', params: { n: 20 }, outcome_scope: 'third_party', producer_id: null, producer_name: null, is_active: true, created_at: '2026-11-21T00:00:00Z', created_by: null, mode: 'shadow', ...o });

describe('order rules wording', () => {
  it('says what each condition means in plain words', () => {
    expect(conditionText('decorations_over', { n: 20 })).toBe('More than 20 decorations on the whole order');
    expect(conditionText('units_over', { n: 10 })).toBe('More than 10 units on the whole order');
    expect(conditionText('custom_field_filled', { field: 'Uniform For' })).toBe('A name is filled in on "Uniform For"');
    expect(conditionText('tag_present', { tag: 'person_packing' })).toBe('The order has the tag "person_packing"');
    expect(conditionText('method_includes', { method: 'dtf' })).toBe('Garments on the order are decorated with dtf');
    expect(conditionText('something_new', null)).toBe('something new');
  });
  it('says where a rule sends the order', () => {
    expect(resultText('third_party', 'DPS')).toBe('Send to a third party: DPS');
    expect(resultText('third_party', null)).toBe('Send to a third party');
    expect(resultText('in_house', null)).toBe('Make it in house');
  });
  it('labels outcomes and scopes, and tolerates unknown ones', () => {
    expect(outcomeLabel('would_change')).toBe('Would move');
    expect(outcomeLabel('protected')).toBe('Left alone');
    expect(outcomeLabel('brand_new')).toBe('brand new');
    expect(outcomeTone('would_change')).toBe('high');
    expect(scopeLabel('third_party')).toBe('Third party');
    expect(scopeLabel('unclassified')).toBe('Not decided');
    expect(scopeLabel(null)).toBe('—');
  });
});

describe('order rules data helpers', () => {
  it('counts decisions by outcome', () => {
    const c = decisionCounts([dec({ outcome: 'would_change' }), dec({ order_id: 'o2', outcome: 'would_change' }), dec({ order_id: 'o3', outcome: 'protected' }), dec({ order_id: 'o4' })]);
    expect(c).toMatchObject({ total: 4, would_change: 2, protected: 1, no_rule_matched: 1, already_matches: 0 });
  });
  it('only a would-change decision needs a look', () => { expect(needsLook(dec({ outcome: 'would_change' }))).toBe(true); expect(needsLook(dec({ outcome: 'protected' }))).toBe(false); });
  it('finds the decision and tags for one order', () => {
    expect(decisionFor([dec({ order_id: 'a' }), dec({ order_id: 'b', outcome: 'protected' })], 'b')?.outcome).toBe('protected');
    expect(decisionFor([], 'a')).toBeNull(); expect(decisionFor([dec({})], null)).toBeNull();
    const tags: TagRow[] = [{ order_id: 'a', order_ref: '#1', tag_code: 'z', label: 'Zed', quantity: 3, evidence: null, set_at: '' }, { order_id: 'a', order_ref: '#1', tag_code: 'p', label: 'Alpha', quantity: null, evidence: null, set_at: '' }, { order_id: 'b', order_ref: '#2', tag_code: 'p', label: 'Alpha', quantity: 1, evidence: null, set_at: '' }];
    expect(tagsFor(tags, 'a').map((t) => t.label)).toEqual(['Alpha', 'Zed']); expect(tagsFor(tags, 'nope')).toEqual([]); expect(tagsFor(tags, undefined)).toEqual([]);
  });
  it('shows a tag with its quantity only when there is one', () => {
    expect(tagText({ label: 'Requires person packing', quantity: 14 })).toBe('Requires person packing · 14');
    expect(tagText({ label: 'Needs folding', quantity: null })).toBe('Needs folding');
    expect(tagText({ label: 'Needs folding', quantity: 0 })).toBe('Needs folding');
  });
  it('lists the rule that runs first at the top', () => {
    expect(rulesInOrder([rule({ id: 'b', position: 20 }), rule({ id: 'a', position: 5 }), rule({ id: 'c', position: 20, created_at: '2026-11-22T00:00:00Z' })]).map((r) => r.id)).toEqual(['a', 'b', 'c']);
  });
});
