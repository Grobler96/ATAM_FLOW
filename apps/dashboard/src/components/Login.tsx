import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/api';
import { Button, Field } from '../ui/primitives';
import { Icon } from '../ui/Icon';

export function Login() {
  const [email, setEmail] = useState(''); const [password, setPassword] = useState(''); const [error, setError] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  async function submit(e: FormEvent) {
    e.preventDefault(); setBusy(true); setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) setError(error.message === 'Invalid login credentials' ? 'That email and password do not match.' : error.message);
    setBusy(false);
  }
  return (
    <main style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 16 }}>
      <form className="panel stack" style={{ width: 'min(400px, 100%)', padding: 28, gap: 16 }} onSubmit={submit}>
        <div className="brand" style={{ fontSize: 22 }}><span className="logo"><Icon name="bolt" size={16} stroke={2.4} /></span>ATAM_FLOW</div>
        <p className="muted">Operations command centre. Sign in with your ATAM account.</p>
        <Field label="Email"><input className="input" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
        <Field label="Password"><input className="input" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
        {error && <div className="callout" role="alert" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }}>{error}</div>}
        <Button variant="primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</Button>
      </form>
    </main>
  );
}
