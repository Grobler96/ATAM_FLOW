import { describe, expect, it } from 'vitest';
import { areasFor, canChangeEmbroidery, designsFor, embCounts, embDone, embLight, embMoves, embScore, embWords, eventsFor, eventWords, sizeText, suggestionText, type EmbAreaRow, type EmbDesignRow, type EmbEventRow } from './embroidery';

const area = (o: Partial<EmbAreaRow> = {}): EmbAreaRow => ({ artwork_id: 'a', order_id: 'o1', order_ref: '#1', customer_id: 'C1', customer_name: 'Club', due_date: null, scope: 'in_house', order_status: 'awaiting_stock', deco_line_id: 'L1', area: 'Left Chest', thumbnail_url: null, stitch_count: 5200, width_mm: 80, height_mm: 60, file_format: 'dst', storage_status: 'failed', approval_status: 'unknown', version: 1, design_id: null, design_name: null, design_status: null, design_round: null, status_by: null, status_at: null, area_status: 'to_review', suggested_design_id: null, suggested_design_name: null, suggested_status: null, suggested_why: null, ...o });

describe('embroidery status words and lights', () => {
  it('says each status in plain words and tolerates unknown ones', () => { expect(embWords('swatch_required')).toBe('Swatch required'); expect(embWords('known')).toBe('Done before'); expect(embWords('swatch_sent')).toBe('Swatch sent to customer'); expect(embWords('some_new_one')).toBe('some new one'); });
  it('red until work starts, amber while a swatch is under way, green when done', () => {
    expect(['to_review', 'swatch_required', 'changes_needed'].map(embLight)).toEqual(['red', 'red', 'red']); expect(['swatch_in_progress', 'swatch_sent'].map(embLight)).toEqual(['amber', 'amber']); expect(['known', 'swatch_approved'].map(embLight)).toEqual(['green', 'green']);
    expect(embDone('known')).toBe(true); expect(embDone('swatch_sent')).toBe(false); expect(embLight('nonsense')).toBe('red');
  });
  it('sorts worst first', () => { expect(embScore(area({ area_status: 'to_review' }))).toBeGreaterThan(embScore(area({ area_status: 'swatch_sent' }))); expect(embScore(area({ area_status: 'swatch_sent' }))).toBeGreaterThan(embScore(area({ area_status: 'known' }))); });
});

describe('the moves a design can make (mirrors the database)', () => {
  it('a new swatch goes required, in progress, sent, approved', () => {
    expect(embMoves('swatch_required').map((m) => m.to)).toEqual(['swatch_in_progress', 'known']); expect(embMoves('swatch_in_progress').map((m) => m.to)).toEqual(['swatch_sent', 'swatch_approved', 'changes_needed']);
    expect(embMoves('swatch_sent').map((m) => m.to)).toEqual(['swatch_approved', 'changes_needed']);
  });
  it('a rejected swatch can only start again', () => { expect(embMoves('changes_needed').map((m) => m.to)).toEqual(['swatch_in_progress']); });
  it('a finished design can be reopened, but only with a reason', () => { const m = embMoves('swatch_approved'); expect(m.map((x) => x.to)).toEqual(['changes_needed', 'swatch_required']); expect(m.every((x) => x.note)).toBe(true); expect(embMoves('known').every((x) => x.note)).toBe(true); });
  it('asking for changes always needs a reason; starting a swatch does not', () => { expect(embMoves('swatch_sent').find((m) => m.to === 'changes_needed')?.note).toBe(true); expect(embMoves('swatch_required')[0].note).toBe(false); });
  it('offers nothing for an area still to review', () => { expect(embMoves('to_review')).toEqual([]); });
  it('only planners can change a design', () => { expect(['admin', 'manager', 'production'].map(canChangeEmbroidery)).toEqual([true, true, true]); expect(canChangeEmbroidery('warehouse')).toBe(false); expect(canChangeEmbroidery('viewer')).toBe(false); expect(canChangeEmbroidery(null)).toBe(false); });
});

describe('embroidery lists', () => {
  it('splits areas by where the order is made and counts them', () => {
    const rows = [area({ scope: 'in_house' }), area({ artwork_id: 'b', scope: 'third_party', area_status: 'swatch_sent' }), area({ artwork_id: 'c', scope: 'in_house', area_status: 'known', design_id: 'd1' }), area({ artwork_id: 'd', suggested_design_id: 'd1' })];
    expect(areasFor(rows, 'in_house')).toHaveLength(3); expect(areasFor(rows, 'third_party')).toHaveLength(1); expect(areasFor(rows, 'unclassified')).toHaveLength(0);
    expect(embCounts(rows)).toEqual({ total: 4, todo: 2, busy: 1, done: 1, suggested: 1 });
  });
  it('writes stitches and size, or a dash', () => { expect(sizeText(area())).toBe('5,200 stitches · 80 × 60 mm'); expect(sizeText(area({ stitch_count: null, width_mm: null, height_mm: null }))).toBe('—'); expect(sizeText(area({ width_mm: null }))).toBe('5,200 stitches'); });
  it('describes a suggestion, with why', () => {
    expect(suggestionText(area({ suggested_design_id: 'd1', suggested_design_name: 'Club crest', suggested_why: 'Same artwork', suggested_status: 'swatch_approved' }))).toBe('Same artwork: Club crest (swatch approved)');
    expect(suggestionText(area())).toBe('');
  });
  it('finds a customer\'s designs and a design\'s history in order', () => {
    const d = (o: Partial<EmbDesignRow>): EmbDesignRow => ({ id: 'd', customer_id: 'C1', customer_name: 'Club', name: 'B', status: 'known', round: 1, status_by: null, status_at: null, note: null, created_at: '', orders_using: 1, ...o });
    expect(designsFor([d({ id: '1', name: 'B' }), d({ id: '2', name: 'A' }), d({ id: '3', customer_id: 'C2' })], 'C1').map((x) => x.id)).toEqual(['2', '1']); expect(designsFor([d({})], null)).toEqual([]);
    const e = (o: Partial<EmbEventRow>): EmbEventRow => ({ id: 1, design_id: 'd', event: 'status', from_status: null, to_status: null, round: 1, actor: null, note: null, order_ref: null, at: '2026-11-21T10:00:00Z', ...o });
    expect(eventsFor([e({ id: 2, at: '2026-11-21T11:00:00Z' }), e({ id: 1 }), e({ id: 3, design_id: 'x' })], 'd').map((x) => x.id)).toEqual([1, 2]);
  });
  it('words the history', () => {
    expect(eventWords({ id: 1, design_id: 'd', event: 'created', from_status: null, to_status: 'swatch_required', round: 1, actor: null, note: null, order_ref: '#5', at: '' })).toBe('Design created from #5');
    expect(eventWords({ id: 2, design_id: 'd', event: 'status', from_status: 'swatch_sent', to_status: 'changes_needed', round: 1, actor: null, note: 'Thread too dark', order_ref: null, at: '' })).toBe('Swatch sent to customer → Changes needed: Thread too dark');
    expect(eventWords({ id: 3, design_id: 'd', event: 'status', from_status: 'changes_needed', to_status: 'swatch_in_progress', round: 2, actor: null, note: null, order_ref: null, at: '' })).toBe('Changes needed → Swatch in progress (round 2)');
    expect(eventWords({ id: 4, design_id: 'd', event: 'linked', from_status: null, to_status: null, round: 1, actor: null, note: 'Left Chest', order_ref: '#7', at: '' })).toBe('Used on #7 (Left Chest)');
  });
});
