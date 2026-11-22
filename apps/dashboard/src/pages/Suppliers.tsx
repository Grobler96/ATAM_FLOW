import { useMemo, useState } from 'react';
import { Button, EmptyState, Skeleton, Status } from '../ui/primitives';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { SupplierCardDialog } from '../components/SupplierCardDialog';
import { canEditSuppliers, cardGaps, isAutomatic, matchesCard, optionsFor, orderMethodLabel, shippingSummary, sortCards, type ShippingOptionRow, type SupplierCardRow } from '../lib/supplierCards';
import { money } from '../lib/domain';

// Supplier cards: who we buy from, how we order from them and what delivery costs. The catalogue holds their prices; purchase orders use both.
export function SuppliersPage() {
  const cards = useView<SupplierCardRow>('ui_supplier_cards'), shipping = useView<ShippingOptionRow>('ui_supplier_shipping'); const { role } = useCtx(); const can = canEditSuppliers(role);
  const [q, setQ] = useState(''); const [off, setOff] = useState(false); const [open, setOpen] = useState<string | 'new' | null>(null);
  const list = useMemo(() => sortCards(cards.rows.filter((c) => (off || c.is_active) && matchesCard(c, q))), [cards.rows, off, q]);
  const current = open && open !== 'new' ? cards.rows.find((c) => c.id === open) ?? null : null; const active = cards.rows.filter((c) => c.is_active).length;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Suppliers</h1><p>{cards.loading ? 'Loading…' : `${active} supplier${active === 1 ? '' : 's'} in use. Each card holds how we order, the delivery options and what delivery costs; prices are in the catalogue under Purchasing.`}</p></div>
        <Button variant="primary" disabled={!can} title={can ? '' : 'Managers and admins only'} onClick={() => setOpen('new')}>Add a supplier</Button></div>
      <div className="row wrap" style={{ gap: 12 }}><input className="input" placeholder="Search suppliers…" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search suppliers" style={{ maxWidth: 320 }} />
        <label className="row" style={{ gap: 6 }}><input type="checkbox" checked={off} onChange={(e) => setOff(e.target.checked)} /> Show suppliers that are switched off</label></div>
      {cards.loading ? <Skeleton h={160} /> : cards.error ? <div className="callout" role="alert">{cards.error} <Button size="sm" onClick={() => void cards.refresh()}>Try again</Button></div> : list.length === 0 ? <EmptyState icon="check" title="No suppliers here">{q ? 'No supplier matches that search.' : 'Add your first supplier.'}</EmptyState> :
        <div style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))' }}>{list.map((c) => { const opts = optionsFor(shipping.rows, c.id); const gaps = cardGaps(c, opts);
          return (
            <button key={c.id} type="button" className="panel stack" onClick={() => setOpen(c.id)} aria-label={`Supplier ${c.name}`} style={{ padding: 14, gap: 6, textAlign: 'left', cursor: 'pointer', opacity: c.is_active ? 1 : 0.6 }}>
              <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}><b>{c.name}</b><span className="chip">{orderMethodLabel(c.order_method)}</span></div>
              {!c.is_active && <Status tone="medium">Switched off</Status>}
              <span className="dim">{c.contact_name ?? 'No contact yet'}{c.email ? ` · ${c.email}` : ''}</span>
              <span className="dim">{c.lead_time_days} day{c.lead_time_days === 1 ? '' : 's'} to deliver{c.min_order_value ? ` · minimum order ${money(c.min_order_value)}` : ''}</span>
              <span className="dim">{shippingSummary(opts)}</span>
              <span className="dim">{c.catalogue_items} item{c.catalogue_items === 1 ? '' : 's'} in the catalogue{isAutomatic(c.order_method) ? ' · ordered automatically' : ''}</span>
              {gaps.length > 0 && <span className="warn">⚠ {gaps.join(' · ')}</span>}
            </button>); })}</div>}
      {open && (open === 'new' || current) && <SupplierCardDialog key={open} supplier={current} canEdit={can} onClose={() => setOpen(null)} onCreated={(id) => setOpen(id)} />}
    </div>
  );
}
