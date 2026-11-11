// Plain words for a decorator when a file will not upload. The storage rule that limits how many files and how much data a job may hold
// (and the rule that keeps a decorator to their own folder) answers with a database message, which means nothing to a decorator.
export const UPLOAD_LIMIT_HINT = 'this job may already hold as many files as ATAM allows. Tell ATAM in a message and they will sort it out';

export function uploadProblem(message: string | null | undefined): string {
  const m = (message ?? '').trim();
  if (!m) return 'something went wrong';
  return /row-level security/i.test(m) ? UPLOAD_LIMIT_HINT : m;
}
