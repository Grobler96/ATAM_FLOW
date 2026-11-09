import { describe, expect, it } from 'vitest';
import { artworkPath, checkFile, fileNameOf, isImage, MAX_BYTES, proofPath, safeName, slug } from './artworkFiles';

const f = (name: string, size = 10) => ({ name, size } as File);

describe('artwork files', () => {
  it('makes file names safe and gives every file a lower-case extension', () => {
    expect(safeName('Logo (final) v2.DST')).toBe('Logo-final-v2.dst');
    expect(safeName('../../etc/passwd')).toBe('passwd');
    expect(safeName('C:\\Users\\me\\logo.dst')).toBe('logo.dst');
    expect(safeName('a/b/c.pdf/')).not.toContain('/');
    expect(safeName('   .pdf')).toBe('file.pdf');
    expect(safeName('café menu.png')).toMatch(/^cafe-menu\.png$/);
  });
  it('builds paths the database accepts', () => {
    expect(proofPath('#636220', 'Proof 1.pdf', 123)).toBe('proofs/636220/123-Proof-1.pdf');
    expect(artworkPath('#636220', 'Left chest', 2, 'logo.dst', 123)).toBe('orders/636220/left-chest/v2-123-logo.dst');
    expect(slug('  Back / Neck!! ')).toBe('back-neck');
  });
  it('accepts embroidery and artwork formats and refuses the rest', () => {
    expect(checkFile(f('logo.dst'))).toBeNull();
    expect(checkFile(f('logo.exe'))).toMatch(/not accepted/);
    expect(checkFile(f('noext'))).toMatch(/not accepted/);
    expect(checkFile(f('proof.dst'), ['pdf', 'png'])).toMatch(/not accepted/);
  });
  it('refuses empty and oversized files', () => {
    expect(checkFile(f('a.pdf', 0))).toMatch(/empty/);
    expect(checkFile(f('a.pdf', MAX_BYTES + 1))).toMatch(/limit/);
  });
  it('recognises images and recovers a readable name from a stored path', () => {
    expect(isImage('x.JPG')).toBe(true); expect(isImage('x.dst')).toBe(false);
    expect(fileNameOf('orders/636220/left-chest/v2-1700000000000-logo.dst')).toBe('logo.dst');
    expect(fileNameOf('proofs/636220/1700000000000-proof.pdf')).toBe('proof.pdf');
    expect(fileNameOf(null)).toBe('');
  });
});
