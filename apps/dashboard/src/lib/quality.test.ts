import { describe, expect, it } from 'vitest';
import { applicableItems, checklistProblem, type CriterionRow } from './quality';

const item = (o: Partial<CriterionRow>): CriterionRow => ({ id: 'a', method_code: null, name: 'Item', description: null, sort_order: 10, is_active: true, gates: null, is_required: true, is_critical: false, needs_photo: false, is_placeholder: false, version: 1, updated_by: null, updated_at: null, ...o });

describe('applicableItems', () => {
  const rows = [item({ id: '1', name: 'All' }), item({ id: '2', method_code: 'dtf', gates: ['final'] }), item({ id: '3', method_code: 'embroidery' }), item({ id: '4', is_active: false })];
  it('filters by method and stage and skips inactive items', () => {
    expect(applicableItems(rows, 'final', ['dtf']).map((c) => c.id)).toEqual(['1', '2']);
    expect(applicableItems(rows, 'in_line', ['dtf']).map((c) => c.id)).toEqual(['1']);
    expect(applicableItems(rows, 'final', ['dtf', 'embroidery']).map((c) => c.id)).toEqual(['1', '2', '3']);
  });
});

describe('checklistProblem', () => {
  const list = [item({ id: 'r', name: 'Required one' }), item({ id: 'p', name: 'Photo one', is_required: false, needs_photo: true })];
  it('names unanswered required items', () => expect(checklistProblem(list, {}, {}, '', false)).toContain('Required one'));
  it('needs a reason for a failed item', () => expect(checklistProblem(list, { r: false }, {}, '', false)).toContain('say what is wrong'));
  it('accepts a check-level note as the reason', () => expect(checklistProblem(list, { r: false }, {}, 'bad', false)).toBeNull());
  it('needs a photo link when a photo item fails', () => {
    expect(checklistProblem(list, { r: true, p: false }, { p: 'cracked' }, '', false)).toContain('photo');
    expect(checklistProblem(list, { r: true, p: false }, { p: 'cracked' }, '', true)).toBeNull();
  });
  it('is fine when all passes', () => expect(checklistProblem(list, { r: true }, {}, '', false)).toBeNull());
});
