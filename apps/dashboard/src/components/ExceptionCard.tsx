import type { ExceptionRow } from '../types';
import { ageText, BLOCK_LABEL, deadlineText, gbp, STATUS_LABEL } from '../lib/format';

export function ExceptionCard({ e, onOpen }: { e: ExceptionRow; onOpen: (e: ExceptionRow) => void }) {
  const refs = [...e.order_refs.slice(0, 4), ...e.skus.slice(0, 2), ...e.po_refs.slice(0, 2), ...e.movement_refs.slice(0, 1), ...e.producers.slice(0, 1)];
  const more = e.order_refs.length + e.skus.length + e.po_refs.length + e.movement_refs.length + e.producers.length - refs.length;
  return (
    <li>
      <button className={`card sev-${e.severity}`} onClick={() => onOpen(e)} aria-label={`${e.severity} ${e.type_label}: ${e.description}`}>
        <div className="card-top">
          <span className={`badge sev-${e.severity}`}>{e.severity}</span>
          <span className="type">{e.type_label}</span>
          <span className="ref">{e.exc_ref}</span>
          {e.is_overdue && <span className="badge overdue">Overdue</span>}
          {e.escalation_level > 0 && <span className="badge esc" title="Escalated because nobody responded in time">Escalated ×{e.escalation_level}</span>}
        </div>
        <p className="desc">{e.description}</p>
        {refs.length > 0 && (
          <div className="chips-row">
            {refs.map((r) => <span className="tag" key={r}>{r}</span>)}
            {more > 0 && <span className="tag more">+{more} more</span>}
          </div>
        )}
        <div className="card-meta">
          <span className={e.needs_owner ? 'warn' : ''}>{e.owner ? e.owner : `No owner · ${e.owner_role ?? 'unassigned'}`}</span>
          <span className={e.is_overdue ? 'bad' : ''}>{deadlineText(e.response_deadline, e.is_overdue)}</span>
          <span>{STATUS_LABEL[e.status] ?? e.status}</span>
          <span>{ageText(e.age_hours)}</span>
          {e.financial_impact != null && <span className="money">{gbp(e.financial_impact)} at stake</span>}
        </div>
        {e.blocks.length > 0 && <div className="chips-row">{e.blocks.map((b) => <span className="tag block" key={b}>{BLOCK_LABEL[b] ?? b}</span>)}</div>}
      </button>
    </li>
  );
}
