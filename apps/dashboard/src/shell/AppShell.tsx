import { useCallback, useEffect, useRef, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { ToastProvider, Modal } from '../ui/overlay';
import { ContextProvider, useCtx } from '../data/context';
import { rpc } from '../data/store';
import { navigate, NAV, useRoute } from '../router';
import type { Role } from '../types';
import { Sidebar } from './Sidebar';
import { TopBar } from './TopBar';
import { StatusBar } from './StatusBar';
import { CommandPalette } from './CommandPalette';
import { useRunner } from './useRunner';
import { CreatePoDialog } from '../components/CreatePoDialog';
import { ScanHost } from '../components/ScanHost';
import { DispatchPage } from '../pages/Dispatch';
import { PenPage } from '../pages/Pen';
import { CutOffBanner } from '../components/CutOffBanner';
import { StockTakesPage } from '../pages/StockTakes';
import { Home } from '../pages/Home';
import { OrdersPage } from '../pages/Orders';
import { ProductionPage } from '../pages/Production';
import { StockPage } from '../pages/Stock';
import { PurchasingPage } from '../pages/Purchasing';
import { ProducersPage } from '../pages/Producers';
import { WarehousePage } from '../pages/Warehouse';
import { ArtworkPage } from '../pages/Artwork';
import { ExceptionsPage } from '../pages/Exceptions';
import { CreateMovementDialog } from '../components/MovementDialogs';
import { QualityPage } from '../pages/Quality';
import { RecordCheckDialog } from '../components/QualityDialogs';
import { GoodsInPage } from '../pages/GoodsIn';
import { GenerateLabelsDialog } from '../components/GenerateLabelsDialog';
import { LabelsPage } from '../pages/Labels';
import { AnalyticsPage } from '../pages/Analytics';
import { SettingsPage } from '../pages/Settings';
import { ControlPage } from '../pages/Control';
import { WastePage } from '../pages/Waste';
import { CrewPage } from '../pages/Crew';
import { FloorPage } from '../pages/Floor';
import '../shell/shell.css';

export function AppShell({ session }: { session: Session }) {
  const [role, setRole] = useState<Role | null>(null);
  useEffect(() => { rpc<Role | null>('ui_my_role').then(setRole).catch(() => setRole(null)); }, []);
  return <ToastProvider><ContextProvider role={role} email={session.user.email ?? null}><Frame /></ContextProvider></ToastProvider>;
}

function Frame() {
  const route = useRoute(); const { email } = useCtx(); const runner = useRunner();
  const [collapsed, setCollapsed] = useState(() => { try { return localStorage.getItem('atamflow.collapsed') === '1'; } catch { return false; } });
  const [mobileOpen, setMobileOpen] = useState(false); const [palette, setPalette] = useState(false); const [poOpen, setPoOpen] = useState(false); const [help, setHelp] = useState(false); const [poPreset, setPoPreset] = useState<string[]>([]); const [qcDlg, setQcDlg] = useState<{ orderId?: string } | null>(null); const [moveDlg, setMoveDlg] = useState<{ orders?: string[] } | null>(null); const [labelDlg, setLabelDlg] = useState<{ type?: string; refs?: string[] } | null>(null);
  const chord = useRef(0);
  useEffect(() => { try { localStorage.setItem('atamflow.collapsed', collapsed ? '1' : '0'); } catch { /* storage unavailable */ } }, [collapsed]);
  useEffect(() => setMobileOpen(false), [route.raw]);

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement; const typing = t.matches('input, textarea, select, [contenteditable]');
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); setPalette((p) => !p); return; }
      if (typing || e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key === '/') { e.preventDefault(); setPalette(true); return; }
      if (e.key === '?') { setHelp(true); return; }
      if (e.key === 'g') { chord.current = Date.now(); return; }
      if (Date.now() - chord.current < 900) { const n = NAV.find((x) => x.chord === e.key); if (n) { e.preventDefault(); navigate(n.id === 'home' ? '' : n.id); } chord.current = 0; }
    };
    window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k);
  }, []);

  useEffect(() => { const h = (e: Event) => { setPoPreset((e as CustomEvent<string[]>).detail ?? []); setPoOpen(true); }; window.addEventListener('atamflow:create-po', h); return () => window.removeEventListener('atamflow:create-po', h); }, []);
  useEffect(() => { const h = (e: Event) => setLabelDlg((e as CustomEvent<{ type?: string; refs?: string[] }>).detail ?? {}); window.addEventListener('atamflow:generate-labels', h); return () => window.removeEventListener('atamflow:generate-labels', h); }, []);
  useEffect(() => { const h = (e: Event) => setMoveDlg((e as CustomEvent<{ orders?: string[] }>).detail ?? {}); window.addEventListener('atamflow:send-to-producer', h); return () => window.removeEventListener('atamflow:send-to-producer', h); }, []);
  useEffect(() => { const h = (e: Event) => setQcDlg((e as CustomEvent<{ orderId?: string }>).detail ?? {}); window.addEventListener('atamflow:record-qc', h); return () => window.removeEventListener('atamflow:record-qc', h); }, []);
  const closePalette = useCallback(() => setPalette(false), []);
  const page = route.path[0] ?? 'home';
  return (
    <div className={`app ${collapsed ? 'collapsed' : ''} ${mobileOpen ? 'open' : ''}`}>
      <Sidebar route={route} collapsed={collapsed} onToggle={() => setCollapsed((c) => !c)} />
      <div className="main">
        <TopBar onMenu={() => setMobileOpen((o) => !o)} onCollapse={() => setCollapsed((c) => !c)} onSearch={() => setPalette(true)} onCreatePo={() => { setPoPreset([]); setPoOpen(true); }} onGenerateLabels={() => setLabelDlg({})} onNewMovement={() => setMoveDlg({})} onRun={(d) => void runner.run(d)} running={runner.running} canRun={runner.can} email={email} />
        <main className="content" id="main">
          <CutOffBanner />
          {page === 'home' && <Home />}{page === 'orders' && <OrdersPage route={route} />}{page === 'pen' && <PenPage route={route} />}{page === 'production' && <ProductionPage route={route} />}{page === 'stock' && <StockPage route={route} />}
          {page === 'purchasing' && <PurchasingPage route={route} onCreatePo={() => setPoOpen(true)} />}{page === 'producers' && <ProducersPage route={route} />}{page === 'warehouse' && <WarehousePage route={route} />}{page === 'dispatch' && <DispatchPage route={route} />}{page === 'stocktake' && <StockTakesPage route={route} />}{page === 'goods-in' && <GoodsInPage />}{page === 'quality' && <QualityPage route={route} />}
          {page === 'artwork' && <ArtworkPage route={route} />}{page === 'exceptions' && <ExceptionsPage route={route} />}{page === 'labels' && <LabelsPage route={route} />}{page === 'analytics' && <AnalyticsPage />}{page === 'control' && <ControlPage />}{page === 'waste' && <WastePage />}{page === 'crew' && <CrewPage />}{page === 'floor' && <FloorPage />}{page === 'settings' && <SettingsPage />}
          {!NAV.some((n) => n.id === page) && <div className="state"><h3>Page not found</h3><a href="#/">Back to the Command Centre</a></div>}
        </main>
        <StatusBar />
      </div>
      {palette && <CommandPalette onClose={closePalette} onRun={(d) => void runner.run(d)} canRun={runner.can} onCreatePo={() => setPoOpen(true)} />}
      <ScanHost />
      {poOpen && <CreatePoDialog open onClose={() => { setPoOpen(false); setPoPreset([]); }} presetOrders={poPreset} />}
      {qcDlg && <RecordCheckDialog orderId={qcDlg.orderId} onClose={() => setQcDlg(null)} />}
      {moveDlg && <CreateMovementDialog onClose={() => setMoveDlg(null)} presetOrders={moveDlg.orders} />}
      {labelDlg && <GenerateLabelsDialog open onClose={() => setLabelDlg(null)} presetType={labelDlg.type} presetRefs={labelDlg.refs} />}
      <Modal open={help} onClose={() => setHelp(false)} title="Keyboard shortcuts">
        <div className="facts" style={{ gridTemplateColumns: '1fr 1fr' }}>
          <div><dt>Search / command palette</dt><dd><kbd>/</kbd> or <kbd>Ctrl/⌘</kbd> <kbd>K</kbd></dd></div><div><dt>Close panel</dt><dd><kbd>Esc</kbd></dd></div>
          {NAV.map((n) => <div key={n.id}><dt>Go to {n.label}</dt><dd><kbd>g</kbd> <kbd>{n.chord}</kbd></dd></div>)}
        </div>
      </Modal>
    </div>
  );
}
