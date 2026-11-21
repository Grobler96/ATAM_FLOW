import { Panel, Skeleton, Status, EmptyState } from '../ui/primitives';
import { DataTable, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { dateTime } from '../lib/format';
import { shortDate } from '../lib/domain';
import { conditionText, decisionCounts, outcomeLabel, outcomeTone, OUTCOME_HELP, resultText, rulesInOrder, scopeLabel, type DecisionRow, type RoutingRuleRow, type TagRow, type TagRuleRow } from '../lib/orderRules';

// Order rules: what the tag rules and routing rules found, and what WOULD happen to each order. Shadow mode: nothing here, and nothing the rules do,
// changes an order. Adding or changing a rule is done in the database for now; there is no button for it yet.
const orderPath = (ref: string) => 'orders/' + ref.replace('#', '');

export function OrderRulesPage({ route }: { route: Route }) {
  const dec = useView<DecisionRow>('ui_routing_decisions'), rules = useView<RoutingRuleRow>('ui_routing_rules'), tagRules = useView<TagRuleRow>('ui_tag_rules'), tags = useView<TagRow>('ui_order_tags');
  const c = decisionCounts(dec.rows); const mode = rules.rows[0]?.mode ?? 'shadow';
  const tagCounts = [...tags.rows.reduce((m, t) => m.set(t.tag_code, { label: t.label, n: (m.get(t.tag_code)?.n ?? 0) + 1 }), new Map<string, { label: string; n: number }>()).values()];
  const views: ViewDef<DecisionRow>[] = [
    { id: 'move', label: 'Would move', test: (r) => r.outcome === 'would_change' }, { id: 'left', label: 'Left alone', test: (r) => r.outcome === 'protected' }, { id: 'right', label: 'Already right', test: (r) => r.outcome === 'already_matches' },
    { id: 'hand', label: 'Set by hand', test: (r) => r.outcome === 'manual_wins' }, { id: 'none', label: 'No rule applies', test: (r) => r.outcome === 'no_rule_matched' }, { id: 'all', label: 'All', test: () => true }
  ];
  const ruleNames = [...new Set(dec.rows.map((r) => r.rule_name).filter((v): v is string => !!v))].sort();
  const filters: FilterDef<DecisionRow>[] = [{ id: 'rule', label: 'Rule', options: ruleNames.map((v) => ({ value: v, label: v })), test: (r, v) => r.rule_name === v }];
  const cols: Column<DecisionRow>[] = [
    { id: 'order', header: 'Order', width: '110px', render: (r) => <b className="mono">{r.order_ref}</b>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'cust', header: 'Customer', width: '170px', render: (r) => r.customer_name ?? <span className="dim">—</span>, sort: (r) => r.customer_name, csv: (r) => r.customer_name },
    { id: 'out', header: 'What would happen', width: '150px', render: (r) => <Status tone={outcomeTone(r.outcome)}>{outcomeLabel(r.outcome)}</Status>, sort: (r) => r.outcome, csv: (r) => outcomeLabel(r.outcome) },
    { id: 'rule', header: 'Rule', width: '200px', render: (r) => r.rule_name ?? <span className="dim">None</span>, sort: (r) => r.rule_name, csv: (r) => r.rule_name },
    { id: 'now', header: 'Today', width: '130px', render: (r) => scopeLabel(r.current_scope), sort: (r) => r.current_scope, csv: (r) => scopeLabel(r.current_scope) },
    { id: 'would', header: 'A rule says', width: '170px', render: (r) => (r.would_scope ? <span>{scopeLabel(r.would_scope)}{r.would_producer_name ? ` · ${r.would_producer_name}` : ''}</span> : <span className="dim">—</span>), sort: (r) => r.would_scope, csv: (r) => (r.would_scope ? scopeLabel(r.would_scope) + (r.would_producer_name ? ' · ' + r.would_producer_name : '') : '') },
    { id: 'dec', header: 'Decorations', width: '110px', align: 'r', render: (r) => (r.decoration_count == null ? '—' : r.decoration_count.toLocaleString('en-GB')), sort: (r) => r.decoration_count, csv: (r) => r.decoration_count, hide: 'mobile' },
    { id: 'due', header: 'Due', width: '110px', render: (r) => <span className="dim">{r.due_date ? shortDate(r.due_date) : '—'}</span>, sort: (r) => r.due_date, csv: (r) => r.due_date, hide: 'mobile' }
  ];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Order rules</h1>
        <p>{c.total === 0 ? 'No orders have been checked yet.' : `${c.total} orders checked · ${c.would_change} would move · ${c.protected} left alone · ${c.already_matches} already right`}</p></div></div>
      <div className="callout soft" role="status"><b>{mode === 'shadow' ? 'Shadow mode: nothing is being changed.' : 'Rules are switched on.'}</b> Each order is checked against the rules below and this page shows what would happen. No order is moved, and no purchase order or producer is changed, by anything on this screen. A person's own setting on an order always wins over a rule. To add or change a rule, ask an admin for now: there is no button for it yet.</div>

      <Panel title="Orders: what would happen" icon="orders" flush>
        <DataTable<DecisionRow> rows={dec.rows} columns={cols} rowKey={(r) => r.order_id} loading={dec.loading} error={dec.error} onRetry={() => void dec.refresh()} views={views} filters={filters} storageKey="order-rules" exportName="order-rules" defaultTab="move"
          searchText={(r) => [r.order_ref, r.customer_name, r.rule_name, outcomeLabel(r.outcome)].join(' ')} searchPlaceholder="Search order, customer, rule…"
          onRowClick={(r) => navigate(orderPath(r.order_ref))} defaultSort={{ col: 'dec', dir: -1 }} initial={tableStateFromQuery(route)}
          rowTone={(r) => (r.outcome === 'would_change' ? 'high' : '')}
          empty={<EmptyState icon="check" title="Nothing here">No order matches this view.</EmptyState>} />
      </Panel>
      <div className="dim" style={{ fontSize: 12 }}>{Object.keys(OUTCOME_HELP).map((k) => <div key={k}><b>{outcomeLabel(k)}:</b> {OUTCOME_HELP[k]}</div>)}</div>

      <Panel title="Routing rules" icon="settings" flush>
        {rules.loading ? <div style={{ padding: 16 }}><Skeleton h={60} /></div> : rules.rows.length === 0 ? <p className="dim" style={{ padding: 16, margin: 0 }}>There are no routing rules.</p>
          : <div>{rulesInOrder(rules.rows).map((r, i) => <div key={r.id} className="row wrap" style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)', gap: 12 }}>
            <span className="dim num" style={{ minWidth: 70 }}>{i === 0 ? 'Checked first' : `Then #${i + 1}`}</span><b style={{ minWidth: 200 }}>{r.name}</b>
            <span className="grow">{conditionText(r.kind, r.params)}: <b>{resultText(r.outcome_scope, r.producer_name)}</b></span>{r.is_active ? <Status tone="good">On</Status> : <Status>Off</Status>}</div>)}
            <p className="dim" style={{ padding: '8px 16px', margin: 0 }}>Rules are checked from the top. The first one that matches decides.</p></div>}
      </Panel>

      <Panel title="Tags" icon="info" flush>
        {tagRules.loading ? <div style={{ padding: 16 }}><Skeleton h={60} /></div> : tagRules.rows.length === 0 ? <p className="dim" style={{ padding: 16, margin: 0 }}>There are no tag rules.</p>
          : <div>{tagRules.rows.map((r) => <div key={r.id} className="row wrap" style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)', gap: 12 }}>
            <b style={{ minWidth: 200 }}>{r.tag_label}</b><span className="grow">{conditionText(r.kind, r.params)}</span>
            <span className="dim">{(() => { const n = tagCounts.find((t) => t.label === r.tag_label)?.n ?? 0; return `${n} order${n === 1 ? '' : 's'}`; })()}</span>{r.is_active ? <Status tone="good">On</Status> : <Status>Off</Status>}</div>)}
            <p className="dim" style={{ padding: '8px 16px', margin: 0 }}>A tag says what an order needs, for example person packing. The number on the tag is how many names, or how many decorations, were found. {tags.rows.length === 0 ? '' : `Last checked ${dateTime(tags.rows.reduce((m, t) => (t.set_at > m ? t.set_at : m), ''))}.`}</p></div>}
      </Panel>
      <p className="dim" style={{ margin: 0 }}>"Today" is the order's setting right now: set by hand, from DecoNetwork's Priority flag, or not decided. The rules look at the whole order, not one garment.</p>
    </div>
  );
}
