import { Icon } from '../ui/Icon';
import { href, NAV, type Route } from '../router';
import { useView } from '../data/store';
import type { ExceptionRow } from '../types';

export function Sidebar({ route, collapsed, onToggle }: { route: Route; collapsed: boolean; onToggle: () => void }) {
  const ex = useView<ExceptionRow>('ui_exceptions');
  const critical = ex.rows.filter((e) => e.severity === 'critical').length;
  const current = route.path[0] ?? 'home';
  const groups: [string, string[]][] = [['Operate', ['home', 'orders', 'production', 'crew', 'floor', 'quality', 'stock', 'purchasing']], ['Third parties & floor', ['producers', 'goods-in', 'warehouse', 'artwork', 'labels']], ['Control', ['exceptions', 'waste', 'analytics', 'control', 'settings']]];
  return (
    <aside className="sidebar" aria-label="Main navigation">
      <div className="brand"><span className="logo"><Icon name="bolt" size={16} stroke={2.4} /></span><span className="name">ATAM_FLOW</span></div>
      <nav className="nav">
        {groups.map(([label, ids]) => (<div key={label} style={{ display: 'contents' }}><div className="nav-label">{label}</div>
          {ids.map((id) => { const n = NAV.find((x) => x.id === id)!; return (
            <a key={id} href={href(id === 'home' ? '' : id)} aria-current={current === id ? 'page' : undefined} title={n.label}><Icon name={n.icon} size={18} /><span className="lbl">{n.label}</span>{id === 'exceptions' && critical > 0 && <span className="badge num" aria-label={`${critical} critical`}>{critical}</span>}</a>); })}</div>))}
      </nav>
      <div className="side-foot"><button className="btn ghost" onClick={onToggle} aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'} title="Collapse sidebar"><Icon name="panel" /><span className="lbl">Collapse</span></button></div>
    </aside>
  );
}
