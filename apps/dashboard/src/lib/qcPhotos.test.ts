import { describe, expect, it } from 'vitest';
import { QC_MAX_BYTES, evidenceLabel, isWebLink, qcPhotoPath, qcPhotoProblem, qcUploadProblem } from './qcPhotos';

describe('QC photo checks', () => {
  it('accepts photos and PDFs under 10 MB', () => {
    for (const type of ['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf']) expect(qcPhotoProblem({ name: 'a', type, size: 1000 })).toBeNull();
    expect(qcPhotoProblem({ name: 'big.jpg', type: 'image/jpeg', size: QC_MAX_BYTES })).toBeNull();
  });
  it('refuses other types, empty files and files over the limit, naming the file', () => {
    expect(qcPhotoProblem({ name: 'x.exe', type: 'application/octet-stream', size: 10 })).toContain('x.exe: only photos');
    expect(qcPhotoProblem({ name: 'e.jpg', type: 'image/jpeg', size: 0 })).toContain('empty');
    expect(qcPhotoProblem({ name: 'big.jpg', type: 'image/jpeg', size: QC_MAX_BYTES + 1 })).toContain('over 10 MB');
  });
  it('builds a safe path inside qc/<order>/', () => {
    expect(qcPhotoPath('#700101', 'left chest.jpg', 1700000000000)).toBe('qc/700101/1700000000000-left_chest.jpg');
    const tricky = qcPhotoPath('#70 01/../x', '../../etc/passwd', 5);
    expect(tricky).toBe('qc/70_01_x/5-_.._etc_passwd'); expect(tricky.split('/')).toHaveLength(3);   // slashes are gone, so ".." can never be a folder step
    expect(qcPhotoPath('', '', 7)).toBe('qc/order/7-photo');
    expect(qcPhotoPath('#1', 'a'.repeat(200) + '.jpg', 1).length).toBeLessThan(120);
    expect(qcPhotoPath('#1', '...hidden', 1)).toBe('qc/1/1-hidden');
  });
  it('explains a refused upload in plain words', () => {
    expect(qcUploadProblem('a.jpg', 'new row violates row-level security policy')).toBe('a.jpg: your login cannot add photos here yet. Paste a link instead, or ask an admin.');
    expect(qcUploadProblem('a.jpg', 'Failed to fetch')).toBe('a.jpg: Failed to fetch. Remove it and try again, or paste a link instead.');
    expect(qcUploadProblem('a.jpg', '')).toContain('the photo did not upload');
  });
  it('labels evidence and only treats real web links as links', () => {
    expect(evidenceLabel({ path: 'qc/1/a.jpg', name: 'left.jpg' }, 0)).toBe('left.jpg'); expect(evidenceLabel({ url: 'https://x.test', name: 'Quality evidence' }, 1)).toBe('Photo 2'); expect(evidenceLabel({ url: 'https://x.test' }, 2)).toBe('Photo 3');
    expect(isWebLink({ url: 'https://x.test/a.jpg' })).toBe(true); expect(isWebLink({ url: 'http://x.test' })).toBe(true);
    expect(isWebLink({ url: 'javascript:alert(1)' })).toBe(false); expect(isWebLink({ url: 'data:text/html,x' })).toBe(false); expect(isWebLink({ path: 'qc/1/a.jpg' })).toBe(false); expect(isWebLink({})).toBe(false);
  });
});
