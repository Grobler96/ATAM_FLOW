import type { ReactNode } from 'react';
import { Status, Tag } from '../ui/primitives';
import { dueLabel, ORDER_STATUS, PRIORITY } from '../lib/domain';
import { href } from '../router';

export const OrderLink = ({ r }: { r: string }) => <a className="mono" href={href('orders/' + r.replace('#', ''))} onClick={(e) => e.stopPropagation()}>{r}</a>;
export const OrderTags = ({ refs, max = 4 }: { refs: string[] | null | undefined; max?: number }) => { const l = refs ?? []; return <span className="row wrap" style={{ gap: 4 }}>{l.slice(0, max).map((r) => <OrderLink key={r} r={r} />)}{l.length > max && <Tag>+{l.length - max}</Tag>}{l.length === 0 && <span className="dim">—</span>}</span>; };
export const DueCell = ({ days, date }: { days: number | null; date?: string | null }) => { const d = dueLabel(days); return <span className="row" style={{ gap: 8 }}><Status tone={d.tone} plain>{d.text}</Status>{date && <span className="dim num">{new Date(date).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' })}</span>}</span>; };
export const StatusCell = ({ s }: { s: string }) => { const m = ORDER_STATUS[s]; return <Status tone={m?.tone ?? ''}>{m?.label ?? s.replace(/_/g, ' ')}</Status>; };
export const PriorityCell = ({ p, vip }: { p: number; vip?: boolean }) => <span className="row" style={{ gap: 6 }}>{p > 0 ? <Status tone={PRIORITY[p]?.tone} plain>{PRIORITY[p]?.label}</Status> : <span className="dim">Normal</span>}{vip && <Tag>VIP</Tag>}</span>;
export const Num = ({ v, dim0 }: { v: number | null | undefined; dim0?: boolean }) => <span className={`num ${dim0 && !v ? 'dim' : ''}`}>{v == null ? '—' : v.toLocaleString('en-GB')}</span>;
export function Section({ title, children, actions }: { title: string; children: ReactNode; actions?: ReactNode }) { return <section className="stack" style={{ marginTop: 20 }}><div className="row"><h3 className="grow">{title}</h3>{actions}</div>{children}</section>; }
export const KV = ({ k, v }: { k: string; v: ReactNode }) => <div className="row" style={{ justifyContent: 'space-between', gap: 16, padding: '6px 0', borderBottom: '1px solid var(--border)' }}><span className="muted">{k}</span><span className="num" style={{ textAlign: 'right' }}>{v}</span></div>;
