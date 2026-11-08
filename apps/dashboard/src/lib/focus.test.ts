import { beforeEach, describe, expect, it } from 'vitest';
import { exceptionHidden, getPref, orderHidden, scopeMaps, wantFocus, writePref } from './focus';

const maps = scopeMaps([
  { order_id: 'a', order_ref: '#1', scope: 'third_party' }, { order_id: 'b', order_ref: '#2', scope: 'in_house' },
  { order_id: 'c', order_ref: '#3', scope: 'unclassified' }, { order_id: 'd', order_ref: '#4', scope: 'out_of_scope' }
]);

describe('third-party focus', () => {
  it('hides orders known not to be third-party, keeps third-party and unknown ones', () => {
    expect(['a', 'b', 'c', 'd', 'zzz'].map((id) => orderHidden(id, maps))).toEqual([false, true, true, true, false]);
  });
  it('hides an exception only when every linked order is non-third-party', () => {
    expect(exceptionHidden(['#2'], maps)).toBe(true);
    expect(exceptionHidden(['#2', '#3', '#4'], maps)).toBe(true);
    expect(exceptionHidden(['#2', '#1'], maps)).toBe(false);   // one third-party order keeps it visible
    expect(exceptionHidden(['#9'], maps)).toBe(false);          // unknown order is never hidden
  });
  it('never hides exceptions that are not about an order', () => { expect(exceptionHidden([], maps)).toBe(false); });
  it('defaults on only while in-house is off; a saved choice wins', () => {
    expect(wantFocus(null, true)).toBe(true); expect(wantFocus(null, false)).toBe(false);
    expect(wantFocus('off', true)).toBe(false); expect(wantFocus('on', false)).toBe(true);
  });
  describe('saved choice', () => {
    beforeEach(() => { try { localStorage.clear(); } catch { /* none */ } });
    it('is remembered', () => { writePref('off'); expect(getPref()).toBe('off'); writePref('on'); expect(getPref()).toBe('on'); });
  });
});
