import data from '../data/howto.generated.json';

// The how-to videos. The list (titles, who each is for, the written steps) is generated from the video project (video/, `npm run catalogue`);
// the videos themselves live in a private Storage bucket and are opened with a short-lived link.
export interface HowTo { id: string; title: string; section: string; level: string; summary: string; page: string; pageLabel: string; seconds: number; steps: string[] }
export const HOWTO: HowTo[] = (data as { tutorials: HowTo[] }).tutorials;

// Videos on the list but not made yet. Shown plainly as "on the list", never as if they existed.
export const COMING_SOON: { section: string; titles: string[] }[] = [
  { section: 'Getting started', titles: ['Signing in and your role'] },
  { section: 'Orders', titles: ['Order rules', 'Overriding a production position (in-house, when it is switched on)'] },
  { section: 'Stock and buying', titles: ['Suppliers and the catalogue', 'Stock-takes'] },
  { section: 'Warehouse', titles: ['Bins and put-away', 'Scanning labels'] },
  { section: 'Production (when in-house is switched on)', titles: ['Production board and schedule', 'Machine downtime', 'Crew and floor', 'Embroidery designs', 'DTF prints'] },
  { section: 'Artwork and quality', titles: ['Waste and loss'] },
  { section: 'Third-party work', titles: ['Producers and rate cards', 'Sending work to a producer', 'Direct dispatch and discrepancies'] },
  { section: 'Decorator portal', titles: ['Signing in to the portal', 'Jobs, progress and uploads'] },
  { section: 'Admin', titles: ['Control and settings', 'The update log and suggestions'] },
];

export interface HowToFilter { q: string; section: string }
export function filterHowTo(list: HowTo[], f: HowToFilter): HowTo[] {
  const q = f.q.trim().toLowerCase();
  return list.filter((t) => (!f.section || t.section === f.section) && (!q || [t.title, t.summary, t.section, t.level, t.pageLabel, ...t.steps].join(' ').toLowerCase().includes(q)));
}
export const sectionsOf = (list: HowTo[]): string[] => [...new Set(list.map((t) => t.section))];
export const lengthText = (seconds: number): string => `${Math.floor(seconds / 60)}:${String(Math.max(0, Math.round(seconds % 60))).padStart(2, '0')}`;
export const videoPath = (id: string): string => `${id}.mp4`;
export const posterUrl = (id: string): string => `${import.meta.env.BASE_URL}howto/${id}.jpg`;
