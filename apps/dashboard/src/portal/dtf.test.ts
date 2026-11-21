import { describe, expect, it } from 'vitest';
import { canFinish, canStart, downloadable, dtfWords, groupByOrder, orderSheet, uniqueFiles, type PortalDtfItem } from './dtf';

const it_ = (o: Partial<PortalDtfItem>): PortalDtfItem => ({ id: 'a', order_ref: '#1', customer: 'A', due_date: '2026-12-01', area: 'Front', product: 'Tee', qty: 10, status: 'required', file: 'dtf/a.png', file_name: 'a.png', file_format: 'png', thumbnail_url: null, design_key: 'k1', ...o });

describe('portal DTF helpers', () => {
  it('uses plain words for each status', () => { expect(dtfWords('required')).toBe('Prints required'); expect(dtfWords('in_progress')).toBe('Prints in production'); expect(dtfWords('done')).toBe('Produced'); expect(dtfWords('odd_one')).toBe('odd one'); });
  it('totals the same design across orders on the sheet', () => {
    const s = orderSheet([it_({ id: '1', qty: 10 }), it_({ id: '2', order_ref: '#2', qty: 5 }), it_({ id: '3', order_ref: '#3', qty: 7, design_key: 'k2', file: 'dtf/b.png', file_name: 'b.png' })]);
    expect(s.map((l) => [l.label, l.qty, l.orders])).toEqual([['a.png', 15, ['#1', '#2']], ['b.png', 7, ['#3']]]);
  });
  it('counts only unfinished garments as outstanding', () => { expect(orderSheet([it_({ id: '1', qty: 10, status: 'done' }), it_({ id: '2', order_ref: '#2', qty: 5 })])[0]).toMatchObject({ qty: 15, outstanding: 5 }); });
  it('keeps a placement with no file on its own line', () => {
    const s = orderSheet([it_({ id: '1', file: null, file_name: null }), it_({ id: '2', order_ref: '#2', file: null, file_name: null })]);
    expect(s).toHaveLength(2); expect(s.every((l) => !l.hasFile)).toBe(true);
  });
  it('groups placements by order and works out the order status', () => {
    const g = groupByOrder([it_({ id: '1', order_ref: '#2', due_date: '2026-12-05', status: 'done' }), it_({ id: '2', order_ref: '#2', due_date: '2026-12-05', status: 'required' }), it_({ id: '3', order_ref: '#1', status: 'done' })]);
    expect(g.map((x) => [x.order_ref, x.status])).toEqual([['#1', 'done'], ['#2', 'in_progress']]);
  });
  it('picks what each button can act on', () => {
    const l = [it_({ id: '1' }), it_({ id: '2', status: 'in_progress' }), it_({ id: '3', status: 'done' }), it_({ id: '4', file: null })];
    expect(canStart(l).map((i) => i.id)).toEqual(['1', '4']); expect(canFinish(l).map((i) => i.id)).toEqual(['1', '2', '4']); expect(downloadable(l)).toHaveLength(3);
  });
  it('downloads each shared file once', () => { expect(uniqueFiles([it_({ id: '1' }), it_({ id: '2', order_ref: '#2' }), it_({ id: '3', file: null })])).toEqual([{ file: 'dtf/a.png', name: 'a.png' }]); });
});
