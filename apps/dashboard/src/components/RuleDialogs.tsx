import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { refreshAll, useView } from '../data/store';
import { exceptionActionTo } from '../lib/api';
import type { ProducerRow } from '../data/types';
import type { RoutingRuleRow, TagRuleRow } from '../lib/orderRules';
import { ROUTING_KINDS, TAG_KINDS, kindDef, nextPosition, routingParams, tagParams, validateRouting, validateTag, valueFromParams, type RoutingForm, type TagForm } from '../lib/orderRulesEdit';

// Add or change a routing rule or a tag rule. Everything goes through the audited order-rules action (manager or admin, a reason is required), and every order is
// checked again straight after. Shadow mode: saving a rule never moves an order.
const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const REASONS = ['Daniel asked for this rule', 'Trying it in shadow mode first', 'Rule no longer needed'];

function ValueField({ kind, value, onChange, tags }: { kind: string; value: { n: string; field: string; tag: string; method?: string }; onChange: (v: { n: string; field: string; tag: string; method?: string }) => void; tags: { code: string; label: string }[] }) {
  const k = kindDef(kind);
  if (!k) return null;
  if (k.needs === 'n') return <Field label={`How many (${k.unit})`}><input className="input" inputMode="numeric" value={value.n} onChange={(e) => onChange({ ...value, n: e.target.value })} placeholder="For example 20" /></Field>;
  if (k.needs === 'field') return <Field label="Custom field name, exactly as DecoNetwork spells it"><input className="input" value={value.field} onChange={(e) => onChange({ ...value, field: e.target.value })} placeholder="For example Uniform For" /></Field>;
  if (k.needs === 'method') return <Field label="Process (as in the order list, for example dtf or embroidery)"><input className="input" list="rule-methods" value={value.method ?? ''} onChange={(e) => onChange({ ...value, method: e.target.value })} placeholder="For example dtf" /><datalist id="rule-methods"><option value="dtf" /><option value="embroidery" /><option value="uv" /><option value="dtg" /></datalist></Field>;
  return <Field label="Tag"><select className="input" value={value.tag} onChange={(e) => onChange({ ...value, tag: e.target.value })}><option value="">Choose a tag…</option>{tags.map((t) => <option key={t.code} value={t.code}>{t.label}</option>)}</select></Field>;
}

export function RoutingRuleDialog({ rule, onClose }: { rule: RoutingRuleRow | null; onClose: () => void }) {
  const rules = useView<RoutingRuleRow>('ui_routing_rules'), tagRules = useView<TagRuleRow>('ui_tag_rules'), producers = useView<ProducerRow>('ui_producers'); const toast = useToast();
  const tags = [...new Map(tagRules.rows.map((t) => [t.tag_code, { code: t.tag_code, label: t.tag_label }])).values()];
  const [f, setF] = useState<RoutingForm>(() => rule
    ? { name: rule.name, kind: rule.kind, value: valueFromParams(rule.kind, rule.params), scope: rule.outcome_scope, producerId: rule.producer_id ?? '', position: String(rule.position), active: rule.is_active, reason: '' }
    : { name: '', kind: 'decorations_over', value: { n: '', field: '', tag: '' }, scope: 'third_party', producerId: '', position: String(nextPosition(rules.rows)), active: true, reason: '' });
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const problem = validateRouting(f);
  async function save() {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('order-rules', 'save_routing_rule', routingParams(f, rule?.id ?? null));
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: rule ? 'Routing rule changed' : 'Routing rule added', body: String(r.note ?? 'Every order has been checked again. Nothing was moved.') }); void refreshAll(); onClose();
  }
  return (
    <Modal open onClose={onClose} title={rule ? 'Change routing rule' : 'Add a routing rule'}>
      <div className="stack">
        <p className="dim">Rules are checked from the lowest position up. The first one that matches decides where the order should be made. This only records what would happen: no order is moved.</p>
        <Field label="Name"><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder="For example Big orders go to DPS" /></Field>
        <Field label="When"><select className="input" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value, value: { n: '', field: '', tag: '', method: '' } })}>{ROUTING_KINDS.map((k) => <option key={k.id} value={k.id}>{k.label}</option>)}</select></Field>
        <ValueField kind={f.kind} value={f.value} onChange={(value) => setF({ ...f, value })} tags={tags} />
        <Field label="Then"><select className="input" value={f.scope} onChange={(e) => setF({ ...f, scope: e.target.value, producerId: e.target.value === 'in_house' ? '' : f.producerId })}><option value="third_party">Send it to a third party</option><option value="in_house">Make it in house</option></select></Field>
        {f.scope === 'third_party' && <Field label="Which producer"><select className="input" value={f.producerId} onChange={(e) => setF({ ...f, producerId: e.target.value })}><option value="">Not chosen (use the order's decorator)</option>{producers.rows.filter((p) => p.is_active).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>}
        <Field label="Position (lowest is checked first)"><input className="input" inputMode="numeric" value={f.position} onChange={(e) => setF({ ...f, position: e.target.value })} /></Field>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} /> This rule is on</label>
        <Field label="Why? (recorded in the audit trail)"><input className="input" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} list="rule-reasons" placeholder="At least 5 characters" /><datalist id="rule-reasons">{REASONS.map((p) => <option key={p} value={p} />)}</datalist></Field>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || !!problem} title={problem ?? ''} onClick={() => void save()}>{busy ? 'Saving…' : rule ? 'Save changes' : 'Add rule'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button>{problem && f.name && <span className="dim">{problem}</span>}</div>
      </div>
    </Modal>
  );
}

export function TagRuleDialog({ rule, onClose }: { rule: TagRuleRow | null; onClose: () => void }) {
  const tagRules = useView<TagRuleRow>('ui_tag_rules'); const toast = useToast();
  const tags = [...new Map(tagRules.rows.map((t) => [t.tag_code, { code: t.tag_code, label: t.tag_label }])).values()];
  const [f, setF] = useState<TagForm>(() => rule
    ? { tagCode: rule.tag_code, tagLabel: '', isNew: false, name: rule.name, kind: rule.kind, value: valueFromParams(rule.kind, rule.params), active: rule.is_active, reason: '' }
    : { tagCode: tags[0]?.code ?? '', tagLabel: '', isNew: tags.length === 0, name: '', kind: 'custom_field_filled', value: { n: '', field: '', tag: '' }, active: true, reason: '' });
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const problem = validateTag(f);
  async function save() {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('order-rules', 'save_tag_rule', tagParams(f, rule?.id ?? null));
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: rule ? 'Tag rule changed' : 'Tag rule added', body: String(r.note ?? 'Every order has been checked again. Nothing was moved.') }); void refreshAll(); onClose();
  }
  return (
    <Modal open onClose={onClose} title={rule ? 'Change tag rule' : 'Add a tag rule'}>
      <div className="stack">
        <p className="dim">A tag rule puts a tag on an order, for example Requires person packing. Tags later decide things like which section an order goes to, or an extra charge on a third-party purchase order.</p>
        {rule ? <p><b>Tag:</b> {rule.tag_label}</p> : <>
          <Field label="Tag"><select className="input" value={f.isNew ? '__new' : f.tagCode} onChange={(e) => setF(e.target.value === '__new' ? { ...f, isNew: true, tagCode: '' } : { ...f, isNew: false, tagCode: e.target.value })}>{tags.map((t) => <option key={t.code} value={t.code}>{t.label}</option>)}<option value="__new">A new tag…</option></select></Field>
          {f.isNew && <Field label="New tag label"><input className="input" value={f.tagLabel} onChange={(e) => setF({ ...f, tagLabel: e.target.value })} placeholder="For example Needs folding" /></Field>}
        </>}
        <Field label="Rule name"><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder="For example More than 10 units" /></Field>
        <Field label="Tag the order when"><select className="input" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value, value: { n: '', field: '', tag: '', method: '' } })}>{TAG_KINDS.map((k) => <option key={k.id} value={k.id}>{k.label}</option>)}</select></Field>
        <ValueField kind={f.kind} value={f.value} onChange={(value) => setF({ ...f, value })} tags={[]} />
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} /> This rule is on</label>
        <Field label="Why? (recorded in the audit trail)"><input className="input" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} list="rule-reasons" placeholder="At least 5 characters" /><datalist id="rule-reasons">{REASONS.map((p) => <option key={p} value={p} />)}</datalist></Field>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || !!problem} title={problem ?? ''} onClick={() => void save()}>{busy ? 'Saving…' : rule ? 'Save changes' : 'Add tag rule'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button>{problem && f.name && <span className="dim">{problem}</span>}</div>
      </div>
    </Modal>
  );
}
