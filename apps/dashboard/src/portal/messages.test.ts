import { describe, expect, it } from 'vitest';
import { UPLOAD_LIMIT_HINT, uploadProblem } from './messages';

describe('portal upload messages', () => {
  it('explains a refused upload in plain words', () => {
    expect(uploadProblem('new row violates row-level security policy')).toBe(UPLOAD_LIMIT_HINT);
    expect(uploadProblem('New row violates Row-Level Security policy for table "objects"')).toBe(UPLOAD_LIMIT_HINT);
  });
  it('leaves other messages alone, and never shows nothing', () => {
    expect(uploadProblem('The object exceeded the maximum allowed size')).toBe('The object exceeded the maximum allowed size');
    expect(uploadProblem('Failed to fetch')).toBe('Failed to fetch');
    expect(uploadProblem('')).toBe('something went wrong'); expect(uploadProblem(null)).toBe('something went wrong'); expect(uploadProblem(undefined)).toBe('something went wrong');
  });
});
