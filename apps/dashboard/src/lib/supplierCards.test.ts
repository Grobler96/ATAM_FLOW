import { describe, expect, it } from 'vitest';
import { canEditSuppliers, cardGaps, defaultOption, emptyShippingForm, emptySupplierForm, formFromCard, formFromOption, isAutomatic, matchesCard, optionWords, optionsFor, orderMethodLabel, shippingProblem, shippingSummary, sortCards, supplierPayload, supplierProblem, type ShippingOptionRow, type SupplierCardRow } from './supplierCards';

const card = (o: Partial<SupplierCardRow> = {}): SupplierCardRow => ({ id: 's1', code: 'RAL-1', name: 'Ralawise', contact_name: 'Sam', email: 'o@r.test', phone: null, address: null, website: null, account_number: 'AC1', payment_terms: null, lead_time_days: 3, min_order_value: null, currency: 'GBP', order_method: 'email', order_method_notes: null, notes: null, can_deliver_to_producer: false, is_active: true, updated_at: '', catalogue_items: 5, ...o });
const opt = (o: Partial<ShippingOptionRow> = {}): ShippingOptionRow => ({ id: 'o1', supplier_id: 's1', name: 'Standard', cost: 6.95, free_over: 150, lead_time_days: 3, cut_off_time: '14:30', is_default: true, is_active: true, notes: null, updated_at: '', ...o });

describe('supplier card words', () => {
  it('names the ways of ordering and knows which are automatic', () => { expect(orderMethodLabel('api')).toBe('API (automatic)'); expect(orderMethodLabel('weird')).toBe('weird'); expect(isAutomatic('api')).toBe(true); expect(isAutomatic('edi')).toBe(true); expect(isAutomatic('email')).toBe(false); });
  it('describes a delivery option', () => { expect(optionWords(opt())).toBe('Standard £6.95 · free over £150.00 · 3 days · order by 14:30'); expect(optionWords(opt({ cost: 0, free_over: null, lead_time_days: 1, cut_off_time: null }))).toBe('Standard free · 1 day'); });
  it('summarises a supplier\'s options', () => {
    expect(shippingSummary([])).toBe('No delivery options yet'); expect(shippingSummary([opt({ is_active: false })])).toBe('No delivery options yet');
    expect(shippingSummary([opt(), opt({ id: 'o2', name: 'Next day', is_default: false, cost: 9.95 })])).toBe('2 options · usually Standard £6.95 · free over £150.00');
  });
  it('puts the active, default and cheapest options first', () => {
    const l = [opt({ id: 'a', name: 'Pallet', cost: 20, is_default: false }), opt({ id: 'b', is_active: false, is_default: false }), opt({ id: 'c' }), opt({ id: 'd', supplier_id: 'other' }), opt({ id: 'e', name: 'Next day', cost: 9.95, is_default: false })];
    expect(optionsFor(l, 's1').map((o) => o.id)).toEqual(['c', 'e', 'a', 'b']); expect(defaultOption(l.filter((o) => o.supplier_id === 's1'))?.id).toBe('c'); expect(defaultOption([opt({ is_active: false })])).toBeNull();
  });
});

describe('what is missing on a card', () => {
  it('lists the gaps in plain words', () => {
    expect(cardGaps(card(), [opt()])).toEqual([]); expect(cardGaps(card({ email: null }), [opt()])).toEqual(['No email address to send orders to']);
    expect(cardGaps(card({ order_method: 'api', email: null }), [opt()])).toEqual([]); expect(cardGaps(card({ catalogue_items: 0 }), [])).toEqual(['No delivery option', 'No prices in the catalogue']);
    expect(cardGaps(card({ is_active: false, email: null }), [])).toEqual([]);
  });
  it('lists active suppliers first, by name, and searches name, code, contact, email and account', () => {
    expect(sortCards([card({ id: '1', name: 'Zed' }), card({ id: '2', name: 'Alpha', is_active: false }), card({ id: '3', name: 'Beta' })]).map((c) => c.id)).toEqual(['3', '1', '2']);
    expect(matchesCard(card(), 'sam')).toBe(true); expect(matchesCard(card(), 'ac1')).toBe(true); expect(matchesCard(card(), 'nope')).toBe(false); expect(matchesCard(card(), '  ')).toBe(true);
  });
  it('only managers and admins can change suppliers', () => { expect(['admin', 'manager'].map(canEditSuppliers)).toEqual([true, true]); expect(canEditSuppliers('production')).toBe(false); expect(canEditSuppliers('viewer')).toBe(false); expect(canEditSuppliers(null)).toBe(false); });
});

describe('the supplier form', () => {
  it('starts sensible and round-trips a card', () => { expect(emptySupplierForm()).toMatchObject({ order_method: 'email', lead_time_days: '3', is_active: true }); expect(formFromCard(card({ min_order_value: 150 }))).toMatchObject({ name: 'Ralawise', min_order_value: '150', email: 'o@r.test' }); });
  it('checks the form in plain words', () => {
    const ok = { ...emptySupplierForm(), name: 'X' }; expect(supplierProblem(ok)).toBeNull(); expect(supplierProblem({ ...ok, name: ' ' })).toBe('Give the supplier a name.'); expect(supplierProblem({ ...ok, email: 'nope' })).toBe('"nope" is not an email address.');
    expect(supplierProblem({ ...ok, lead_time_days: 'soon' })).toBe('The lead time has to be between 0 and 99 days.'); expect(supplierProblem({ ...ok, lead_time_days: '' })).toBe('The lead time has to be between 0 and 99 days.'); expect(supplierProblem({ ...ok, min_order_value: '-5' })).toBe('The minimum order has to be an amount, or empty.');
    expect(supplierProblem({ ...ok, min_order_value: '' })).toBeNull();
  });
  it('trims what it sends', () => { expect(supplierPayload({ ...emptySupplierForm(), name: '  Ralawise ', email: ' a@b.co ' })).toMatchObject({ name: 'Ralawise', email: 'a@b.co' }); });
});

describe('the shipping form', () => {
  it('makes the first option the default', () => { expect(emptyShippingForm(true).is_default).toBe(true); expect(emptyShippingForm(false).is_default).toBe(false); expect(formFromOption(opt())).toMatchObject({ name: 'Standard', cost: '6.95', free_over: '150', cut_off_time: '14:30' }); });
  it('checks it in plain words', () => {
    const ok = { ...emptyShippingForm(true), name: 'Standard' }; expect(shippingProblem(ok)).toBeNull(); expect(shippingProblem({ ...ok, name: '' })).toBe('Give the option a name, for example Standard or Next day.');
    expect(shippingProblem({ ...ok, cost: 'lots' })).toBe('The cost has to be an amount, or 0 for free.'); expect(shippingProblem({ ...ok, cost: '-1' })).toBe('The cost has to be an amount, or 0 for free.'); expect(shippingProblem({ ...ok, free_over: 'x' })).toBe('The free-over amount has to be an amount, or empty.');
    expect(shippingProblem({ ...ok, lead_time_days: 'x' })).toBe('The lead time has to be a number of days, or empty.'); expect(shippingProblem({ ...ok, cut_off_time: '25:00' })).toBe('The cut-off has to be a time like 14:30, or empty.'); expect(shippingProblem({ ...ok, cut_off_time: '9:05' })).toBeNull();
  });
});
