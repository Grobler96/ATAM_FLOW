import { describe, expect, it } from 'vitest';
import { planMakeThirdParty, reasonOk, summarise } from './makeThirdParty';

const c = (ref: string, scope?: string) => ({ id: 'id-' + ref, ref, scope });
describe('planMakeThirdParty', () => {
  it('switches in-house and unclassified orders, leaves the rest alone', () => {
    const p = planMakeThirdParty([c('#1', 'in_house'), c('#2', 'unclassified'), c('#3'), c('#4', 'third_party'), c('#5', 'out_of_scope')]);
    expect(p.toSwitch.map((x) => x.ref)).toEqual(['#1', '#2', '#3']);
    expect(p.already.map((x) => x.ref)).toEqual(['#4']);
    expect(p.outOfScope.map((x) => x.ref)).toEqual(['#5']);
  });
  it('needs a real reason', () => { expect(reasonOk('  ')).toBe(false); expect(reasonOk('abcd')).toBe(false); expect(reasonOk('Sent to DPS')).toBe(true); });
  it('says what happened', () => {
    expect(summarise({ ok: ['a'], failed: [] })).toBe('1 order switched to third-party.');
    expect(summarise({ ok: ['a', 'b'], failed: [{ ref: '#3', error: 'x' }] })).toBe('2 orders switched to third-party, 1 failed.');
  });
});
