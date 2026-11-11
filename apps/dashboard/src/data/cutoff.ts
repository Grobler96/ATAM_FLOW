// A list that is cut off must never look complete. The store loads each view with a row limit (5,000 by default). Two ways a list can be short:
//  1. it reached that limit, so there may be more rows than were loaded;
//  2. the API itself returned fewer rows than exist (a server-side maximum, often 1,000, below our limit): only a count can tell.
export const SUSPECT_SERVER_CAP = 1000;

// Only worth asking the database for a count when the answer could be a server-side cap: a big list that did not reach our own limit.
export const needsCountCheck = (returned: number, limit: number) => returned >= SUSPECT_SERVER_CAP && returned < limit;

// How many rows the list was cut off at, or null when it is complete (or we cannot tell).
export function cutOffAt(returned: number, limit: number, total: number | null): number | null {
  if (returned >= limit) return returned;
  if (total !== null && total > returned) return returned;
  return null;
}

// "ui_purchase_orders" -> "Purchase orders"
export function viewLabel(view: string): string {
  const words = view.replace(/^ui_/, '').replace(/_/g, ' ').trim();
  return words ? words.charAt(0).toUpperCase() + words.slice(1) : view;
}

export interface CutOff { view: string; label: string; shown: number }

// One plain sentence for the banner. Lists are named once each, biggest cut first.
export function cutOffMessage(items: { view: string; shown: number }[]): string | null {
  const seen = new Map<string, CutOff>();
  for (const i of items) if (!seen.has(i.view)) seen.set(i.view, { view: i.view, label: viewLabel(i.view), shown: i.shown });
  const list = [...seen.values()].sort((a, b) => b.shown - a.shown || a.label.localeCompare(b.label));
  if (list.length === 0) return null;
  const named = list.map((l) => `${l.label} (first ${l.shown.toLocaleString('en-GB')} rows)`).join(', ');
  return `${list.length === 1 ? 'A list loaded here is' : 'Some lists loaded here are'} cut off: ${named}. Rows beyond that are not shown, so counts and totals here may be too low. Narrow the list with filters, or ask an admin.`;
}
