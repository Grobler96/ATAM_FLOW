import { describe, expect, it } from 'vitest';
import { addressLines } from './dispatch';

describe('addressLines', () => {
  it('keeps DecoNetwork\'s own line breaks', () => { expect(addressLines('Sam Ship\r\nShip Co, 1 High Street\nLeeds, LS1 4AB, GB')).toEqual(['Sam Ship', 'Ship Co, 1 High Street', 'Leeds, LS1 4AB, GB']); });
  it('breaks a one-line address at the commas', () => { expect(addressLines('8 Armston Road, Quorn,, Loughborough, LE12 8QP, GB')).toEqual(['8 Armston Road', 'Quorn', 'Loughborough', 'LE12 8QP', 'GB']); });
  it('copes with nothing', () => { expect(addressLines(null)).toEqual([]); expect(addressLines('  ')).toEqual([]); });
});
