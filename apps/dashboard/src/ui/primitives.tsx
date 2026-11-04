import { useState, type ButtonHTMLAttributes, type ReactNode } from 'react';
import { Icon } from './Icon';

export function Button({ variant = '', size = '', icon, children, ...r }: { variant?: 'primary' | 'good' | 'danger' | 'ghost' | ''; size?: 'sm' | ''; icon?: string } & ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button {...r} className={`btn ${variant} ${size} ${!children ? 'icon' : ''} ${r.className ?? ''}`}>{icon && <Icon name={icon} size={size === 'sm' ? 14 : 16} />}{children}</button>;
}

export type Tone = 'critical' | 'high' | 'medium' | 'low' | 'good' | 'info' | '';
export const Status = ({ tone = '', children, plain }: { tone?: Tone; children: ReactNode; plain?: boolean }) => <span className={`status ${tone} ${plain ? 'plain' : ''}`}>{children}</span>;
export const Tag = ({ children, block }: { children: ReactNode; block?: boolean }) => <span className={`tag ${block ? 'block' : ''}`}>{children}</span>;

export function Chip({ on, count, children, onClick, title }: { on?: boolean; count?: number; children: ReactNode; onClick?: () => void; title?: string }) {
  return <button className={`chip ${on ? 'on' : ''} ${count === 0 ? 'zero' : ''}`} aria-pressed={on} onClick={onClick} title={title}>{children}{count !== undefined && <b>{count}</b>}</button>;
}

export function Panel({ title, count, actions, children, flush, className = '', icon }: { title?: ReactNode; count?: number | string; actions?: ReactNode; children: ReactNode; flush?: boolean; className?: string; icon?: string }) {
  return (
    <section className={`panel ${className}`}>
      {(title || actions) && <header className="panel-head"><div className="panel-title">{icon && <Icon name={icon} size={16} />}{title}{count !== undefined && <span className="count num">{count}</span>}</div>{actions && <div className="row">{actions}</div>}</header>}
      <div className={`panel-body ${flush ? 'flush' : ''}`}>{children}</div>
    </section>
  );
}

export function Kpi({ label, value, sub, tone = '', onClick, text }: { label: string; value?: number | string; text?: string; sub?: ReactNode; tone?: Tone; onClick?: () => void }) {
  const zero = value === 0 || value === '0';
  const body = <><span className="kpi-label">{label}</span><span className="kpi-value">{text ?? value}</span>{sub && <span className="kpi-sub">{sub}</span>}</>;
  return onClick ? <button className={`kpi ${tone} ${zero ? 'zero' : ''}`} onClick={onClick}>{body}</button> : <div className={`kpi ${tone} ${zero ? 'zero' : ''}`}>{body}</div>;
}

export function Segmented<T extends string>({ value, options, onChange, label }: { value: T; options: { id: T; label: string }[]; onChange: (v: T) => void; label: string }) {
  return <div className="seg" role="tablist" aria-label={label}>{options.map((o) => <button key={o.id} role="tab" aria-selected={value === o.id} onClick={() => onChange(o.id)}>{o.label}</button>)}</div>;
}

export function Tabs<T extends string>({ value, tabs, onChange, label }: { value: T; tabs: { id: T; label: string; count?: number }[]; onChange: (v: T) => void; label: string }) {
  return <div className="tabs" role="tablist" aria-label={label}>{tabs.map((t) => <button key={t.id} role="tab" aria-selected={value === t.id} onClick={() => onChange(t.id)}>{t.label}{!!t.count && <span className="count num">{t.count}</span>}</button>)}</div>;
}

export const Skeleton = ({ w = '100%', h = 14, r }: { w?: number | string; h?: number; r?: number }) => <div className="skel" style={{ width: w, height: h, borderRadius: r }} />;
export function SkeletonRows({ rows = 6 }: { rows?: number }) { return <div className="stack" style={{ padding: 16 }} role="status" aria-label="Loading">{Array.from({ length: rows }, (_, i) => <Skeleton key={i} h={18} w={`${92 - (i % 3) * 9}%`} />)}</div>; }

export function EmptyState({ title, children, icon = 'info', action }: { title: string; children?: ReactNode; icon?: string; action?: ReactNode }) {
  return <div className="state"><Icon name={icon} size={28} /><h3>{title}</h3>{children && <p>{children}</p>}{action}</div>;
}
export function ErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return <div className="state err" role="alert"><Icon name="exceptions" size={28} /><h3>Could not load this</h3><p>{message}</p>{onRetry && <Button onClick={onRetry} icon="refresh">Try again</Button>}</div>;
}

export const Progress = ({ value, tone = '' }: { value: number; tone?: 'good' | 'bad' | 'warn' | '' }) => <div className={`progress ${tone}`} role="progressbar" aria-valuenow={Math.round(value)} aria-valuemin={0} aria-valuemax={100}><i style={{ width: `${Math.max(0, Math.min(100, value))}%` }} /></div>;

export function Field({ label, children }: { label: string; children: ReactNode }) { return <label className="field">{label}{children}</label>; }

export function Facts({ items }: { items: [string, ReactNode][] }) {
  return <dl className="facts">{items.filter(([, v]) => v !== null && v !== undefined && v !== '').map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>;
}

export function useToggle(initial = false): [boolean, () => void, (v: boolean) => void] { const [v, set] = useState(initial); return [v, () => set((x) => !x), set]; }
