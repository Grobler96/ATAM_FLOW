import { describe, expect, it } from 'vitest';
import { batchItems, batchWords, canApproveHere, canBuildRole, DELIVERY_OPTIONS, deliveryWords, canReceiveRole, outstanding, planBuild, refsOf, skipReason, SKIP_NO_FILE, SKIP_ON_ORDER, SKIP_STARTED, SKIP_THIRD_PARTY } from './dtfOrders';
import type { DtfItemRow } from './preproduction';

const item = (o: Partial<DtfItemRow> = {}): DtfItemRow => ({ id: 'i1', order_id: 'o1', order_ref: '#1', customer_name: 'A', due_date: null, scope: 'in_house', deco_line_id: 'L1', product_name: 'Polo', area: 'Back', qty: 3, status: 'required', artwork_id: 'a1', thumbnail_url: 'https://x/t.png', file_format: 'png', storage_status: 'stored', approval_status: 'pending', content_hash: 'h1', updated_at: '', batch_id: null, batch_ref: null, batch_status: null, ...o });

describe('what can go on a DTF order', () => {
  it('leaves out what cannot be ordered, with the reason', () => {
    expect(skipReason(item())).toBeNull();
    expect(skipReason(item({ scope: 'third_party' }))).toBe(SKIP_THIRD_PARTY);
    expect(skipReason(item({ batch_id: 'b1' }))).toBe(SKIP_ON_ORDER);
    expect(skipReason(item({ status: 'in_progress' }))).toBe(SKIP_STARTED);
    expect(skipReason(item({ artwork_id: null, storage_status: null }))).toBe(SKIP_NO_FILE);
    expect(skipReason(item({ storage_status: 'failed' }))).toBe(SKIP_NO_FILE);
    expect(skipReason(item({ qty: 0 }))).toBe('No garments');
  });
  it('a third-party order is left alone even when everything else is fine', () => { expect(skipReason(item({ scope: 'third_party', batch_id: null, status: 'required' }))).toBe(SKIP_THIRD_PARTY); });
  it('plans a build: the same design on two orders is one line, and only the chosen orders count', () => {
    const p = planBuild([item({ id: '1', qty: 3 }), item({ id: '2', order_id: 'o2', order_ref: '#2', qty: 4 }), item({ id: '3', order_id: 'o3', order_ref: '#3', scope: 'third_party' }), item({ id: '4', order_id: 'o1', area: 'Front', artwork_id: null, storage_status: null }), item({ id: '5', order_id: 'o9', order_ref: '#9' })], ['o1', 'o2', 'o3']);
    expect(p.included.map((i) => i.id)).toEqual(['1', '2']); expect(p.prints).toBe(7); expect(p.orders).toBe(2);
    expect(p.designs).toHaveLength(1); expect(p.designs[0]).toMatchObject({ qty: 7, orders: 2 });
    expect(p.skipped.map((s) => s.reason)).toEqual([SKIP_NO_FILE, SKIP_THIRD_PARTY]);
  });
  it('plans nothing when nothing can be ordered', () => { const p = planBuild([item({ scope: 'third_party' })], ['o1']); expect(p.included).toEqual([]); expect(p.prints).toBe(0); expect(p.skipped).toHaveLength(1); });
  it('lists order references briefly', () => { expect(refsOf([item({ order_ref: '#1' }), item({ order_ref: '#1' }), item({ order_ref: '#2' })])).toBe('#1, #2'); expect(refsOf(Array.from({ length: 8 }, (_, i) => item({ order_ref: '#' + i })), 3)).toBe('#0, #1, #2 and 5 more'); });
});

describe('DTF orders in plain words', () => {
  const b = (o: object) => ({ status: 'draft', comm_status: 'pending_review', supplier_has_email: true, supplier_name: 'Super Print', ...o });
  it('says where a DTF order has got to', () => {
    expect(batchWords(b({ supplier_has_email: false }))).toBe('Waiting: Super Print has no email address yet');
    expect(batchWords(b({ comm_status: 'draft' }))).toBe('Waiting: Super Print has no email address yet');
    expect(batchWords(b({}))).toBe('The email is waiting for approval'); expect(batchWords(b({ comm_status: 'approved' }))).toBe('Approved: waiting to be sent'); expect(batchWords(b({ comm_status: 'failed' }))).toBe('The email failed to send');
    expect(batchWords(b({ status: 'ordered' }))).toBe('Ordered: waiting for the prints'); expect(batchWords(b({ status: 'received' }))).toBe('Received'); expect(batchWords(b({ status: 'cancelled' }))).toBe('Cancelled');
  });
  it('finds what is still to arrive on an order', () => {
    const items = [item({ id: '1', batch_id: 'b1', status: 'done' }), item({ id: '2', batch_id: 'b1', status: 'in_progress', area: 'Front' }), item({ id: '3', batch_id: 'b2' })];
    expect(outstanding(items, 'b1').map((i) => i.id)).toEqual(['2']); expect(batchItems(items, 'b1').map((i) => i.id)).toEqual(['1', '2']);
  });
  it('who can build and who can book prints in', () => {
    expect(['admin', 'manager', 'production'].every(canBuildRole)).toBe(true); expect(canBuildRole('warehouse')).toBe(false); expect(canBuildRole('viewer')).toBe(false); expect(canBuildRole(null)).toBe(false);
    expect(canReceiveRole('warehouse')).toBe(true); expect(canReceiveRole('viewer')).toBe(false);
  });
  it('delivery choices and approving the email from the DTF page', () => {
    expect(DELIVERY_OPTIONS.map((o) => o.value)).toEqual(['standard', 'next_day_pre12']); expect(deliveryWords('next_day_pre12')).toBe('Next day before 12'); expect(deliveryWords('standard')).toBeNull(); expect(deliveryWords(null)).toBeNull();
    const b = { status: 'draft', comm_status: 'pending_review', supplier_has_email: true, comm_id: 'c1' };
    expect(canApproveHere(b)).toBe(true); expect(canApproveHere({ ...b, comm_status: 'failed' })).toBe(true);
    expect(canApproveHere({ ...b, supplier_has_email: false })).toBe(false); expect(canApproveHere({ ...b, comm_id: null })).toBe(false);
    expect(canApproveHere({ ...b, comm_status: 'approved' })).toBe(false); expect(canApproveHere({ ...b, status: 'ordered' })).toBe(false);
  });
});
