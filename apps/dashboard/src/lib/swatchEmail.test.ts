import { describe, expect, it } from 'vitest';
import { activeTemplates, addressProblem, canEmailSwatch, defaultTemplate, fillTemplate, lastAddresses, parseAddresses, photoProblem, swatchEmailWords, swatchPhotoPath, swatchVars, swatchWaiting, swatchesFor, unknownPlaceholders, type EmailTemplateRow, type EmbSwatchRow } from './swatchEmail';
import type { EmbDesignRow } from './embroidery';

const tpl = (o: Partial<EmailTemplateRow>): EmailTemplateRow => ({ code: 'c', kind: 'embroidery_swatch', name: 'T', subject: 'S', body: 'B', is_default: false, is_active: true, updated_by: null, updated_at: '', ...o });
const sw = (o: Partial<EmbSwatchRow>): EmbSwatchRow => ({ id: 's', design_id: 'd', round: 1, order_ref: '#1', area: 'Back', to_addresses: ['a@b.co'], subject: 'x', template_code: null, photo_path: 'swatches/d/x.jpg', status: 'queued', created_by: null, created_at: '2026-11-21T10:00:00Z', sent_at: null, comm_ref: 'COM-1', comm_status: 'pending_review', ...o });
const file = (name: string, size = 1000) => ({ name, size }) as File;

describe('swatch email template', () => {
  it('fills in the placeholders and leaves unknown ones alone', () => {
    const v = swatchVars({ customer_name: 'Seaview FC', design_name: 'Club crest', order_ref: '#636890', area: 'Left Chest', design_round: 2 });
    expect(fillTemplate('Hello {customer}, your {logo} ({order_ref}, {placement}) sample {round} {nope}', v)).toBe('Hello Seaview FC, your Club crest (#636890, Left Chest) sample 2 {nope}');
    expect(swatchVars({ customer_name: null, design_name: null, order_ref: '#1', area: 'Back', design_round: null })).toMatchObject({ customer: 'there', logo: 'logo', round: '1' });
  });
  it('warns about anything in curly brackets it does not know', () => { expect(unknownPlaceholders('Hi {customer} {custmer} {custmer} {x}')).toEqual(['{custmer}', '{x}']); expect(unknownPlaceholders('Hi {customer}')).toEqual([]); });
  it('offers active templates with the default first', () => {
    const l = [tpl({ code: 'b', name: 'B' }), tpl({ code: 'a', name: 'A', is_default: true }), tpl({ code: 'c', name: 'C', is_active: false }), tpl({ code: 'd', kind: 'other' as never })];
    expect(activeTemplates(l).map((t) => t.code)).toEqual(['a', 'b']); expect(defaultTemplate(l)?.code).toBe('a'); expect(defaultTemplate([])).toBeNull();
  });
});

describe('recipients and photo', () => {
  it('splits and tidies addresses', () => { expect(parseAddresses('A@b.co, c@d.co;  a@b.co\nx@y.zz')).toEqual(['a@b.co', 'c@d.co', 'x@y.zz']); });
  it('checks addresses in plain words', () => { expect(addressProblem([])).toBe('Add the customer\'s email address.'); expect(addressProblem(['a@b.co'])).toBeNull(); expect(addressProblem(['nope'])).toBe('"nope" is not an email address.'); expect(addressProblem(['a@b.co', 'b@b.co', 'c@b.co', 'd@b.co', 'e@b.co', 'f@b.co'])).toBe('Five addresses at most.'); });
  it('prefills with the addresses last used for the same customer, ignoring cancelled ones', () => {
    const d = (id: string, c: string): EmbDesignRow => ({ id, customer_id: c, customer_name: null, name: id, status: 'known', round: 1, status_by: null, status_at: null, note: null, created_at: '', orders_using: 1 });
    const s = [sw({ id: '1', design_id: 'd1', to_addresses: ['old@x.co'], created_at: '2026-11-20T10:00:00Z' }), sw({ id: '2', design_id: 'd2', to_addresses: ['new@x.co'], created_at: '2026-11-21T10:00:00Z' }), sw({ id: '3', design_id: 'd2', to_addresses: ['cancelled@x.co'], status: 'cancelled', created_at: '2026-11-22T10:00:00Z' }), sw({ id: '4', design_id: 'd3', to_addresses: ['other@x.co'] })];
    expect(lastAddresses('C1', s, [d('d1', 'C1'), d('d2', 'C1'), d('d3', 'C2')])).toEqual(['new@x.co']); expect(lastAddresses('C9', s, [d('d1', 'C1')])).toEqual([]); expect(lastAddresses(null, s, [])).toEqual([]);
  });
  it('accepts only a photo of a sensible size', () => {
    expect(photoProblem(null)).toBe('Add a photo of the swatch.'); expect(photoProblem(file('a.jpg'))).toBeNull(); expect(photoProblem(file('a.PNG'))).toBeNull(); expect(photoProblem(file('a.pdf'))).toBe('.pdf photos are not accepted. Use jpg, jpeg, png, webp.');
    expect(photoProblem(file('a.jpg', 0))).toBe('That photo is empty.'); expect(photoProblem(file('a.jpg', 11 * 1048576))).toBe('That photo is 11 MB. The limit is 10 MB.');
  });
  it('keeps swatch photos under the design\'s own folder with a safe name', () => { expect(swatchPhotoPath('d-1', 2, '../My Photo (1).JPG', 5)).toBe('swatches/d-1/r2-5-My-Photo-1.jpg'); });
});

describe('swatch emails on a design', () => {
  it('says where an email has got to', () => { expect(swatchEmailWords(sw({}))).toBe('Waiting for approval'); expect(swatchEmailWords(sw({ comm_status: 'approved' }))).toBe('Approved, about to send'); expect(swatchEmailWords(sw({ comm_status: 'failed' }))).toBe('Sending failed'); expect(swatchEmailWords(sw({ status: 'sent' }))).toBe('Sent to the customer'); expect(swatchEmailWords(sw({ status: 'cancelled' }))).toBe('Cancelled'); });
  it('finds a design\'s emails newest first and any waiting for this round', () => {
    const l = [sw({ id: '1', created_at: '2026-11-20T10:00:00Z', status: 'sent' }), sw({ id: '2', round: 2, created_at: '2026-11-21T10:00:00Z' }), sw({ id: '3', design_id: 'x' })];
    expect(swatchesFor(l, 'd').map((s) => s.id)).toEqual(['2', '1']); expect(swatchWaiting(l, 'd', 2)?.id).toBe('2'); expect(swatchWaiting(l, 'd', 1)).toBeNull(); expect(swatchesFor(l, null)).toEqual([]);
  });
  it('can be sent only while the swatch is in progress', () => { expect(canEmailSwatch('swatch_in_progress')).toBe(true); expect(canEmailSwatch('swatch_required')).toBe(false); expect(canEmailSwatch('swatch_sent')).toBe(false); expect(canEmailSwatch(null)).toBe(false); });
});
