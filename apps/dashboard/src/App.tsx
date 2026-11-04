import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './lib/api';
import { clearCache } from './data/store';
import { Login } from './components/Login';
import { AppShell } from './shell/AppShell';

export function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); setReady(true); });
    const { data: sub } = supabase.auth.onAuthStateChange((e, s) => { if (e === 'SIGNED_OUT') clearCache(); setSession(s); });
    return () => sub.subscription.unsubscribe();
  }, []);
  if (!ready) return <div className="state" role="status" style={{ minHeight: '100vh' }}>Loading…</div>;
  if (!session) return <Login />;
  return <AppShell session={session} />;
}
