import { describe, expect, it } from 'vitest';
import { parseScan } from './parse';

const p = (s: string, k = {}) => { const r = parseScan(s, k); return `${r.kind}:${r.ref}`; };

describe('parseScan', () => {
  it('reads consignment codes in every form they appear in', () => {
    expect(p('TP-2026-00007')).toBe('consignment:TP-2026-00007');
    expect(p('tp:TP-2026-00007')).toBe('consignment:TP-2026-00007');
    expect(p('https://grobler96.github.io/ATAM_FLOW/#/tp/TP-2026-00007')).toBe('consignment:TP-2026-00007');
    expect(p('#/producers/movement/TP-2026-00007')).toBe('consignment:TP-2026-00007');
    expect(p('PRO-TP-2026-00007-261109')).toBe('consignment:TP-2026-00007');   // the printed barcode is the label code
    expect(p('  tp-2026-00007\r\n')).toBe('consignment:TP-2026-00007');          // hardware scanners add an Enter
  });
  it('reads the courier label on an outgoing parcel', () => {
    expect(p('DSP-636220-1of3')).toBe('parcel:DSP-636220-1OF3');
    expect(p('dsp-636220-2of3')).toBe('parcel:DSP-636220-2OF3');
    expect(p('DSP-636220-1of1-a1b2')).toBe('parcel:DSP-636220-1OF1-A1B2');
    expect(p('DSP-636220')).toBe('unknown:');
  });
  it('reads orders', () => {
    expect(p('order:#636220')).toBe('order:#636220');
    expect(p('order:636220')).toBe('order:#636220');
    expect(p('https://x.github.io/ATAM_FLOW/#/orders/636220')).toBe('order:#636220');
    expect(p('ORD-636220-261109')).toBe('order:#636220');
    expect(p('ORD-636220-261109-a1b2')).toBe('order:#636220');
    expect(p('636220')).toBe('order:#636220');
    expect(p('#636220')).toBe('order:#636220');
  });
  it('reads bins and stock items, and knows plain codes only when it has been told about them', () => {
    expect(p('bin:A-01-03')).toBe('bin:A-01-03');
    expect(p('#/warehouse/A-01-03')).toBe('bin:A-01-03');
    expect(p('sku:POLO-NVY-M')).toBe('sku:POLO-NVY-M');
    expect(p('STO-POLO-NVY-M-261109')).toBe('sku:POLO-NVY-M');   // the printed barcode on a stock label
    expect(p('STO-POLO-NVY-M-261109-a1b2')).toBe('sku:POLO-NVY-M');
    expect(p('BIN-A-01-03-261109')).toBe('bin:A-01-03');         // the printed barcode on a bin label
    expect(p('POLO-NVY-M')).toBe('unknown:');
    expect(p('POLO-NVY-M', { skus: new Set(['POLO-NVY-M']) })).toBe('sku:POLO-NVY-M');
    expect(p('A-01-03', { bins: new Set(['A-01-03']) })).toBe('bin:A-01-03');
  });
  it('refuses anything it does not recognise, empty input and absurdly long input', () => {
    expect(p('hello world')).toBe('unknown:');
    expect(p('')).toBe('unknown:');
    expect(p('x'.repeat(400))).toBe('unknown:');
    expect(p('12')).toBe('unknown:');
  });
});
