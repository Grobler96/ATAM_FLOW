export const gbp = (n: number | null | undefined): string => (n == null ? '—' : (n < 0 ? '-£' : '£') + Math.abs(Math.round(n)).toLocaleString('en-GB'));

export function relativeTime(iso: string, now: number = Date.now()): string {
  const ms = Date.parse(iso) - now; const abs = Math.abs(ms);
  const m = Math.round(abs / 60000), h = Math.round(abs / 3600000), d = Math.round(abs / 86400000);
  const label = m < 1 ? 'now' : m < 60 ? m + ' min' : h < 48 ? h + ' h' : d + ' days';
  if (label === 'now') return 'now';
  return ms >= 0 ? 'in ' + label : label + ' ago';
}

export function deadlineText(iso: string, overdue: boolean, now: number = Date.now()): string {
  return overdue ? 'Overdue by ' + relativeTime(iso, now).replace(' ago', '') : 'Respond ' + relativeTime(iso, now);
}

export function ageText(hours: number): string {
  if (hours < 1) return 'just now';
  if (hours < 48) return Math.round(hours) + ' h old';
  return Math.round(hours / 24) + ' days old';
}

export const dateTime = (iso: string): string => new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });

export function minutesSince(iso: string | null, now: number = Date.now()): number | null {
  return iso ? Math.max(0, Math.round((now - Date.parse(iso)) / 60000)) : null;
}

export const STATUS_LABEL: Record<string, string> = {
  open: 'Open', investigating: 'Investigating', awaiting_supplier: 'Awaiting supplier', awaiting_producer: 'Awaiting producer', awaiting_customer: 'Awaiting customer'
};
export const BLOCK_LABEL: Record<string, string> = { completion: 'Blocks completion', dispatch: 'Blocks dispatch', production: 'Blocks production', assignment: 'Blocks assignment' };
export const ACTION_LABEL: Record<string, string> = {
  detected: 'Detected', updated: 'Updated', assigned: 'Assigned', status: 'Status changed', note: 'Note', action_taken: 'Action taken', resolved: 'Resolved', auto_resolved: 'Cleared automatically',
  escalated: 'Escalated', reopened: 'Reopened', cancelled: 'Cancelled', written_off: 'Written off', communication_linked: 'Email linked', severity_raised: 'Severity raised', raised_by_person: 'Raised by a person'
};
