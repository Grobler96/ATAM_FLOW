import { useState } from 'react';
import { useToast } from '../ui/overlay';
import { useCtx } from '../data/context';
import { refreshAll } from '../data/store';
import { href } from '../router';
import { runWorkflow, type WorkflowDef } from '../lib/workflows';

// Every n8n trigger goes through here: press -> progress toast -> result toast (with a link to what changed) -> data refreshed.
export function useRunner() {
  const toast = useToast(); const { role } = useCtx();
  const [running, setRunning] = useState<string | null>(null);
  const can = (d: WorkflowDef) => !!role && d.roles.includes(role);
  async function run(def: WorkflowDef, body: Record<string, unknown> = {}) {
    if (running) return;
    setRunning(def.id);
    const id = toast.push({ tone: 'info', title: `Running: ${def.label}`, body: 'This usually takes a few seconds.', running: true });
    const r = await runWorkflow(def, body);
    toast.update(id, { tone: r.ok ? 'good' : 'bad', title: r.ok ? `${def.label}: done` : `${def.label}: did not run`, body: r.message, running: false, href: r.ok && def.resultLink ? href(def.resultLink) : undefined, linkLabel: 'See the result' }, r.ok ? 8000 : 12000);
    setRunning(null);
    if (r.ok) await refreshAll();
    return r;
  }
  return { run, running, can };
}
