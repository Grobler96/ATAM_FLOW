import { useMemo, useState } from 'react';
import { Chip, EmptyState, Panel, Status } from '../ui/primitives';
import { useView } from '../data/store';
import { navigate } from '../router';
import { deadlineText } from '../lib/format';
import { OrderTags } from './common';

export interface AttentionRow { id: string; exc_ref: string; type_label: string; severity: 'critical' | 'high' | 'medium' | 'low'; severity_rank: number; description: string; owner: string | null; owner_role: string; needs_owner: boolean; response_deadline: string; is_overdue: boolean; escalation_level: number; order_refs: string[]; last_activity: string; reasons: string[] }
export interface DigestRow { owner_role: string; open_count: number; overdue: number; escalated: number; due_soon: number; unowned: number; critical: number; untouched: number; needs_attention: number }

export const REASON_LABEL: Record<string, string> = { overdue: 'Overdue', escalated: 'Escalated', due_soon: 'Due soon', no_owner: 'Nobody owns it', untouched: 'Untouched' };
const REASON_TONE: Record<string, 'critical' | 'high' | 'medium'> = { overdue: 'critical', escalated: 'high', due_soon: 'medium', no_owner: 'high', untouched: 'medium' };

// In-app digest: who has what waiting, and why each issue needs a person. (No emails: this is what an emailed digest would say.)
export function ExceptionDigest({ hide, email }: { hide: (orderRefs: string[]) => boolean; email: string | null }) {
  const att = useView<AttentionRow>('ui_exception_attention'); const dig = useView<DigestRow>('ui_exception_digest');
  const [role, setRole] = useState<string>('all'); const [mine, setMine] = useState(false); const [all, setAll] = useState(false);
  const rows = useMemo(() => att.rows.filter((r) => !hide(r.order_refs) && (role === 'all' || r.owner_role === role) && (!mine || (email !== null && (r.owner ?? '').includes(email))))
    .sort((a, b) => b.reasons.length - a.reasons.length || a.severity_rank - b.severity_rank || Date.parse(a.response_deadline) - Date.parse(b.response_deadline)), [att.rows, hide, role, mine, email]);
  const roles = dig.rows.filter((d) => d.needs_attention > 0);
  return (
    <Panel title="Needs a person" count={att.rows.length} icon="exceptions">
      <div className="stack" data-testid="exception-digest">
        <div className="row wrap" style={{ gap: 6 }}>
          <Chip on={role === 'all'} count={att.rows.length} onClick={() => setRole('all')}>Everyone</Chip>
          {roles.map((d) => <Chip key={d.owner_role} on={role === d.owner_role} count={d.needs_attention} onClick={() => setRole(d.owner_role)}>{d.owner_role}</Chip>)}
          {email && <Chip on={mine} onClick={() => setMine((v) => !v)}>Assigned to me</Chip>}
        </div>
        {role !== 'all' && (() => { const d = dig.rows.find((x) => x.owner_role === role); return d ? <p className="dim">{d.open_count} open · {d.overdue} overdue · {d.escalated} escalated · {d.due_soon} due soon · {d.unowned} with no owner · {d.untouched} untouched</p> : null; })()}
        {att.loading ? null : rows.length === 0 ? <EmptyState icon="check" title="Nothing is waiting on anyone">No issue is overdue, escalated, close to its deadline, unowned (high or critical) or untouched.</EmptyState> :
          <div className="stack" style={{ gap: 0 }}>{(all ? rows : rows.slice(0, 6)).map((r) => (
            <button key={r.id} type="button" className="attn-row" style={{ textAlign: 'left' }} onClick={() => navigate('exceptions/' + r.exc_ref)}>
              <Status tone={r.severity}>{r.severity}</Status>
              <div style={{ minWidth: 0 }}>
                <div className="row wrap" style={{ gap: 6 }}><b>{r.type_label}</b>{r.reasons.map((x) => <Status key={x} tone={REASON_TONE[x]} plain>{x === 'escalated' ? `Escalated ×${r.escalation_level}` : REASON_LABEL[x] ?? x}</Status>)}</div>
                <p className="muted" style={{ margin: '2px 0 4px' }}>{r.description}</p>
                <div className="row wrap" style={{ gap: 12, fontSize: 12 }}><OrderTags refs={r.order_refs} max={3} /><span className={r.needs_owner ? 'warn' : 'dim'}>{r.owner ?? `No owner · ${r.owner_role}`}</span><span className={r.is_overdue ? 'bad' : 'dim'}>{deadlineText(r.response_deadline, r.is_overdue)}</span></div>
              </div>
            </button>))}
            {rows.length > 6 && <button type="button" className="link" onClick={() => setAll((v) => !v)}>{all ? 'Show fewer' : `Show all ${rows.length}`}</button>}</div>}
      </div>
    </Panel>);
}
