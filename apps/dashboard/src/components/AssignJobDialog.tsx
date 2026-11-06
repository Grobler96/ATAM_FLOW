import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { useView } from '../data/store';
import { opsAction } from '../lib/orderChanges';
import { METHOD_LABEL } from '../lib/domain';
import type { MachineRow, QueueRow } from '../data/types';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

// Choose who does a job and which machine it goes on. The operator is a record for the floor; the machine is an instruction the planner follows.
export function AssignJobDialog({ step, onClose }: { step: QueueRow; onClose: () => void }) {
  const machines = useView<MachineRow>('ui_machines'); const ops = useView<{ id: string; name: string; is_active: boolean }>('ui_operators'); const toast = useToast();
  const mine = machines.rows.filter((m) => m.method_code === step.method_code && m.is_active);
  const [machine, setMachine] = useState(step.assigned_machine_id ?? ''); const [reason, setReason] = useState(step.assignment_reason ?? ''); const [op, setOp] = useState(step.operator_id ?? '');
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const running = step.status === 'in_progress'; const machineChanged = machine !== (step.assigned_machine_id ?? ''); const opChanged = op !== (step.operator_id ?? '');
  async function save() {
    setBusy(true); setErr(null);
    if (opChanged) { const r = await opsAction('assign_operator', { order_id: step.order_id, method: step.method_code, operator_id: op || null }); if (r.ok === false) { setBusy(false); setErr(String(r.error ?? 'That did not work.')); return; } }
    if (machineChanged && !running) { const r = await opsAction('assign_machine', { order_id: step.order_id, method: step.method_code, machine_id: machine || null, reason }); if (r.ok === false) { setBusy(false); setErr(String(r.error ?? 'That did not work.')); return; } }
    setBusy(false); toast.push({ tone: 'good', title: 'Job assignment saved', body: machineChanged ? 'Re-plan production to apply the machine choice.' : 'Saved.' }); onClose();
  }
  return (
    <Modal open onClose={onClose} title={`${step.order_ref} · ${METHOD_LABEL[step.method_code] ?? step.method_code}`}>
      <div className="stack">
        <Field label="Operator"><select className="select" value={op} onChange={(e) => setOp(e.target.value)}><option value="">Nobody assigned</option>{ops.rows.filter((o) => o.is_active).map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}</select></Field>
        <Field label="Machine"><select className="select" disabled={running} value={machine} onChange={(e) => setMachine(e.target.value)}><option value="">Let the planner choose{step.machine_code ? ` (now ${step.machine_code})` : ''}</option>{mine.map((m) => <option key={m.id} value={m.id}>{m.name} ({m.code})</option>)}</select></Field>
        {running && <p className="dim">The job is running, so its machine is fixed. You can still change the operator.</p>}
        {machine && machineChanged && !running && <Field label="Why this machine? (recorded in the audit trail)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>}
        <p className="dim">Choosing a machine tells the planner to keep this job on it. Re-plan production afterwards to see the new times. If that machine is switched off, the job shows as blocked rather than moving silently.</p>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || (!opChanged && !machineChanged) || (machineChanged && !!machine && !running && reason.trim().length < 5)} onClick={() => void save()}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
