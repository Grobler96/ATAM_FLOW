// Which of the ticked orders a "Make third-party" action will switch, and what it says about the rest.
export interface TpCandidate { id: string; ref: string; scope: string | undefined }
export interface TpPlan { toSwitch: TpCandidate[]; already: TpCandidate[]; outOfScope: TpCandidate[] }

export function planMakeThirdParty(rows: TpCandidate[]): TpPlan {
  const plan: TpPlan = { toSwitch: [], already: [], outOfScope: [] };
  for (const r of rows) (r.scope === 'third_party' ? plan.already : r.scope === 'out_of_scope' ? plan.outOfScope : plan.toSwitch).push(r);
  return plan;
}

export const MIN_REASON = 5;
export const reasonOk = (s: string) => s.trim().length >= MIN_REASON;

export interface TpResult { ok: string[]; failed: { ref: string; error: string }[] }
export function summarise(res: TpResult): string {
  const n = res.ok.length;
  return `${n} order${n === 1 ? '' : 's'} switched to third-party${res.failed.length ? `, ${res.failed.length} failed` : ''}.`;
}
