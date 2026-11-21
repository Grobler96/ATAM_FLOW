import { describe, expect, it } from 'vitest';
import { esc, proofSheetHtml, proofTitle, safeUrl } from './proofSheet';
import type { EmbAreaRow } from './embroidery';

const area = (o: Partial<EmbAreaRow> = {}): EmbAreaRow => ({ artwork_id: 'a', order_id: 'o1', order_ref: '#636890', customer_id: 'C1', customer_name: 'Northside FC', due_date: '2026-12-01T00:00:00Z', scope: 'in_house', order_status: 'awaiting_stock', deco_line_id: 'L1', area: 'Left Chest', thumbnail_url: 'https://example.test/logo.png', stitch_count: 5200, width_mm: 80, height_mm: 60, file_format: 'dst', storage_status: 'stored', approval_status: 'pending', version: 2, design_id: 'd1', design_name: 'Club crest', design_status: 'swatch_required', design_round: 1, status_by: null, status_at: null, area_status: 'swatch_required', suggested_design_id: null, suggested_design_name: null, suggested_status: null, suggested_why: null, ...o });

describe('proof sheet', () => {
  it('escapes anything typed by a person', () => { expect(esc('<b>"A" & \'B\'</b>')).toBe('&lt;b&gt;&quot;A&quot; &amp; &#39;B&#39;&lt;/b&gt;'); expect(esc(null)).toBe(''); });
  it('only uses a normal web address for the picture', () => { expect(safeUrl('https://x/y.png')).toBe('https://x/y.png'); expect(safeUrl('javascript:alert(1)')).toBe(''); expect(safeUrl('data:text/html,hi')).toBe(''); expect(safeUrl(null)).toBe(''); });
  it('shows the order, customer, placement, logo, stitches and size', () => {
    const h = proofSheetHtml([area()], new Date('2026-11-21T10:00:00Z'));
    for (const t of ['#636890', 'Northside FC', 'Left Chest', 'Club crest', 'Swatch required', '5,200 stitches · 80 × 60 mm', 'DST · version 2', 'In house order', 'Printed 21 Nov 2026', 'https://example.test/logo.png']) expect(h).toContain(t);
  });
  it('leaves space to write in the thread colours and the sign-off', () => { const h = proofSheetHtml([area()]); expect((h.match(/<tr><td>\d<\/td>/g) ?? []).length).toBe(8); expect(h).toContain('Customer sign-off'); expect(h).toContain('Thread colour / code'); });
  it('is one page per area', () => { const h = proofSheetHtml([area(), area({ artwork_id: 'b', area: 'Back' }), area({ artwork_id: 'c', area: 'Sleeve' })]); expect((h.match(/<section class="pg">/g) ?? []).length).toBe(3); });
  it('says so when there is no picture or no design', () => { const h = proofSheetHtml([area({ thumbnail_url: null, design_name: null, area_status: 'to_review', design_status: null })]); expect(h).toContain('No picture of the visual is held in Flow'); expect(h).toContain('Not linked to a design yet'); expect(h).toContain('To review'); });
  it('cannot be made to run a script from a customer name or picture address', () => { const h = proofSheetHtml([area({ customer_name: '<script>alert(1)</script>', thumbnail_url: 'javascript:alert(1)' })]); expect(h).not.toContain('<script>alert(1)'); expect(h).not.toContain('javascript:'); });
  it('names the document after the area, or the count', () => { expect(proofTitle([area()])).toBe('Proof sheet #636890 Left Chest'); expect(proofTitle([area(), area()])).toBe('Proof sheets (2)'); });
});
