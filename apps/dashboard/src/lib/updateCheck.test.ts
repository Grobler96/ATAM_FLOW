import { describe, expect, it } from 'vitest';
import { decideUpdate, isBusy } from './updateCheck';

const base = { current: 'b1', latest: 'b2', busy: false, trigger: 'navigate' as const, reloadedFor: null };
describe('decideUpdate', () => {
  it('does nothing when the page is current, or the newest build is unknown', () => {
    expect(decideUpdate({ ...base, latest: 'b1' })).toBe('none'); expect(decideUpdate({ ...base, latest: null })).toBe('none'); expect(decideUpdate({ ...base, current: '' })).toBe('none');
  });
  it('refreshes when the person moves to another page, or comes back to the tab', () => {
    expect(decideUpdate(base)).toBe('reload'); expect(decideUpdate({ ...base, trigger: 'return' })).toBe('reload');
  });
  it('only shows the bar on a timer check (never refreshes at a random moment)', () => { expect(decideUpdate({ ...base, trigger: 'poll' })).toBe('banner'); });
  it('never refreshes while the person is busy: it shows the bar and waits', () => { expect(decideUpdate({ ...base, busy: true })).toBe('banner'); expect(decideUpdate({ ...base, trigger: 'return', busy: true })).toBe('banner'); });
  it('refreshes by itself only once for the same newer build, so a slow cache cannot cause a loop', () => { expect(decideUpdate({ ...base, reloadedFor: 'b2' })).toBe('banner'); expect(decideUpdate({ ...base, reloadedFor: 'b1' })).toBe('reload'); });
});
describe('isBusy', () => {
  const none = { dialogOpen: false, activeTag: null, activeEditable: false, activeType: null };
  it('is not busy with nothing focused or a button focused', () => { expect(isBusy(none)).toBe(false); expect(isBusy({ ...none, activeTag: 'BUTTON' })).toBe(false); expect(isBusy({ ...none, activeTag: 'A' })).toBe(false); });
  it('is busy with a box open', () => { expect(isBusy({ ...none, dialogOpen: true })).toBe(true); });
  it('is busy while typing in a field', () => {
    expect(isBusy({ ...none, activeTag: 'INPUT', activeType: 'text' })).toBe(true); expect(isBusy({ ...none, activeTag: 'input', activeType: null })).toBe(true); expect(isBusy({ ...none, activeTag: 'TEXTAREA' })).toBe(true);
    expect(isBusy({ ...none, activeTag: 'SELECT' })).toBe(true); expect(isBusy({ ...none, activeEditable: true, activeTag: 'DIV' })).toBe(true);
  });
  it('is not busy with a tick box or button input focused', () => { expect(isBusy({ ...none, activeTag: 'INPUT', activeType: 'checkbox' })).toBe(false); expect(isBusy({ ...none, activeTag: 'INPUT', activeType: 'submit' })).toBe(false); });
});
