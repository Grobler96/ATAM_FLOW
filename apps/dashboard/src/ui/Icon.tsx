const P: Record<string, string> = {
  home: 'M3 11l9-8 9 8M5 10v10h5v-6h4v6h5V10',
  orders: 'M9 4h6M9 4a2 2 0 00-2 2v0H6a2 2 0 00-2 2v11a2 2 0 002 2h12a2 2 0 002-2V8a2 2 0 00-2-2h-1v0a2 2 0 00-2-2M8 12h8M8 16h5',
  production: 'M3 20V9l6 3V9l6 3V5h3a3 3 0 013 3v12H3zM7 20v-3M12 20v-3M17 20v-3',
  stock: 'M21 8l-9-5-9 5 9 5 9-5zM3 8v8l9 5 9-5V8M12 13v8',
  purchasing: 'M3 4h2l2.5 11h10L20 7H6M9 20a1 1 0 100-2 1 1 0 000 2zM17 20a1 1 0 100-2 1 1 0 000 2z',
  producers: 'M2 6h11v9H2zM13 9h4l3 3v3h-7M6 18a2 2 0 104 0M15 18a2 2 0 104 0',
  warehouse: 'M3 9l9-5 9 5v11H3zM8 20v-6h8v6M8 14h8',
  artwork: 'M12 3a9 9 0 100 18 2 2 0 002-2v-1a2 2 0 012-2h1a3 3 0 003-3 9 9 0 00-8-10zM7.5 11h.01M10.5 7.5h.01M15 8h.01',
  exceptions: 'M12 3l10 18H2L12 3zM12 10v5M12 18h.01',
  labels: 'M3 12V4h8l10 10-8 8L3 12zM7.5 8.5h.01',
  analytics: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
  settings: 'M12 15a3 3 0 100-6 3 3 0 000 6zM19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z',
  search: 'M11 19a8 8 0 100-16 8 8 0 000 16zM21 21l-4.3-4.3', bell: 'M18 8a6 6 0 10-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 01-3.4 0',
  bolt: 'M13 2L4 14h7l-1 8 9-12h-7l1-8z', chevL: 'M15 6l-6 6 6 6', chevR: 'M9 6l6 6-6 6', chevD: 'M6 9l6 6 6-6', x: 'M6 6l12 12M18 6L6 18', check: 'M5 12.5l4.5 4.5L19 7.5',
  refresh: 'M20 11a8 8 0 00-14.9-3M4 4v4h4M4 13a8 8 0 0014.9 3M20 20v-4h-4', filter: 'M3 5h18l-7 8v6l-4 2v-8L3 5z', download: 'M12 3v12M7 10l5 5 5-5M4 21h16', plus: 'M12 5v14M5 12h14',
  panel: 'M3 5h18v14H3zM9 5v14', calendar: 'M4 6h16v14H4zM4 10h16M8 3v4M16 3v4', user: 'M12 12a4 4 0 100-8 4 4 0 000 8zM4 21a8 8 0 0116 0', clock: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 7v5l3 2',
  arrow: 'M5 12h14M13 6l6 6-6 6', external: 'M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h5', info: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 11v5M12 8h.01',
  play: 'M7 4l13 8-13 8V4z', pin: 'M12 17v5M8 3h8l-1 7 3 3H6l3-3-1-7z', box: 'M3 7l9-4 9 4v10l-9 4-9-4V7zM3 7l9 4 9-4M12 11v10', truck: 'M2 6h11v9H2zM13 9h4l3 3v3h-7', save: 'M5 3h12l4 4v14H5zM8 3v6h8M8 21v-7h8v7',
  star: 'M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.5l6.1-.9L12 3z', trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3', link: 'M10 14a4 4 0 005.7 0l3-3a4 4 0 00-5.7-5.7l-1 1M14 10a4 4 0 00-5.7 0l-3 3a4 4 0 005.7 5.7l1-1'
};
export type IconName = keyof typeof P;
export function Icon({ name, size = 16, className = '', stroke = 1.8 }: { name: string; size?: number; className?: string; stroke?: number }) {
  return <svg className={`icon ${className}`} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={P[name] ?? P.info} /></svg>;
}
