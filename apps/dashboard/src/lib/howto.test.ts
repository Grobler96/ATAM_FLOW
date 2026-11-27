import { describe, expect, it } from 'vitest';
import { filterHowTo, HOWTO, lengthText, sectionsOf, videoPath, type HowTo } from './howto';

const t = (o: Partial<HowTo>): HowTo => ({ id: 'x', title: 'Raise a PO', section: 'Stock and buying', level: 'Managers', summary: 'Buy stock', page: 'purchasing', pageLabel: 'Purchasing', seconds: 48, steps: ['Press approve'], ...o });

describe('how-to videos', () => {
  it('ships a list where every video has steps, a page to open and a length', () => {
    expect(HOWTO.length).toBeGreaterThan(0);
    for (const h of HOWTO) { expect(h.steps.length).toBeGreaterThan(2); expect(h.page).toBeTruthy(); expect(h.seconds).toBeGreaterThan(10); expect(h.title).toBeTruthy(); }
    expect(new Set(HOWTO.map((h) => h.id)).size).toBe(HOWTO.length);
  });
  it('searches title, summary, section, page and the written steps', () => {
    const l = [t({}), t({ id: 'y', title: 'Print labels', section: 'Warehouse', pageLabel: 'Labels', summary: 'Make order labels', steps: ['Scan the QR code'] })];
    expect(filterHowTo(l, { q: '', section: '' })).toHaveLength(2);
    expect(filterHowTo(l, { q: 'qr', section: '' }).map((x) => x.id)).toEqual(['y']);
    expect(filterHowTo(l, { q: ' PO ', section: '' }).map((x) => x.id)).toEqual(['x']);
    expect(filterHowTo(l, { q: '', section: 'Warehouse' }).map((x) => x.id)).toEqual(['y']);
    expect(filterHowTo(l, { q: 'nothing like this', section: '' })).toHaveLength(0);
  });
  it('lists each section once, in order', () => { expect(sectionsOf([t({}), t({ id: 'b' }), t({ id: 'c', section: 'Warehouse' })])).toEqual(['Stock and buying', 'Warehouse']); });
  it('shows lengths as minutes and seconds', () => { expect(lengthText(48)).toBe('0:48'); expect(lengthText(125)).toBe('2:05'); expect(lengthText(60)).toBe('1:00'); });
  it('stores each video as <id>.mp4', () => { expect(videoPath('cc-tour')).toBe('cc-tour.mp4'); });
});
