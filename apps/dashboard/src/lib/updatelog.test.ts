import { describe, expect, it } from 'vitest';
import { UPDATES, PLANNED } from '../data/updatelog';
import { areasOf, dayWords, filterUpdates, isSuspect, newestFirst, rankSuggestions, suggestionsCsv, versionNumber, type SuggestionRow } from './updatelog';

const u = (v: string, date: string, status: 'live' | 'built' | 'in_progress' = 'live') => ({ v, date, status, areas: ['A'], title: 'T ' + v, summary: 's', changes: ['c'] });
const sg = (o: Partial<SuggestionRow>): SuggestionRow => ({ id: 'x', title: 'T', detail: null, area: null, suggested_by_name: 'Dan', status: 'open', status_at: null, created_at: '2026-11-20T10:00:00Z', mine: false, votes: 1, points: 3, avg_importance: 3, my_rating: null, ...o });

describe('the update log data', () => {
  it('has every version once, newest first, with plain content', () => {
    const vs = UPDATES.map((x) => x.v); expect(new Set(vs).size).toBe(vs.length);
    expect(UPDATES.every((x) => x.title && x.summary && x.changes.length > 0 && /^\d{4}-\d{2}-\d{2}$/.test(x.date))).toBe(true);
    const n = UPDATES.map(versionNumber); expect(n).toEqual([...n].sort((a, b) => b - a));
    expect(PLANNED.length).toBeGreaterThan(0);
  });
  it('never mentions the assistant that helped build it', () => { expect(JSON.stringify([UPDATES, PLANNED]).toLowerCase()).not.toMatch(/claude|anthropic|\bai\b/); });
});
describe('filters and the date finder', () => {
  const list = [u('v3', '2026-11-20'), u('v2', '2026-11-19'), u('v1', '2026-11-10')];
  it('says a change from the 3 days before is a suspect, and nothing later or older', () => {
    expect(isSuspect(list[0], '2026-11-21')).toBe(true); expect(isSuspect(list[1], '2026-11-21')).toBe(true);
    expect(isSuspect(list[2], '2026-11-21')).toBe(false); expect(isSuspect(list[0], '2026-11-19')).toBe(false);
    expect(isSuspect(u('v4', '2026-11-20', 'built'), '2026-11-21')).toBe(false); expect(isSuspect(u('v4', '2026-11-20', 'in_progress'), '2026-11-21')).toBe(false);
  });
  it('filters by search, status, area and date', () => {
    expect(filterUpdates(list, { q: 'v2', status: '', area: '', around: '' }).map((x) => x.v)).toEqual(['v2']);
    expect(filterUpdates(list, { q: '', status: 'built', area: '', around: '' })).toEqual([]);
    expect(filterUpdates(list, { q: '', status: '', area: 'A', around: '2026-11-21' }).map((x) => x.v)).toEqual(['v3', 'v2']);
    expect(filterUpdates(list, { q: '', status: '', area: 'B', around: '' })).toEqual([]);
  });
  it('sorts newest first and lists areas once', () => { expect(newestFirst([list[2], list[0], list[1]]).map((x) => x.v)).toEqual(['v3', 'v2', 'v1']); expect(areasOf(list, ['Z'])).toEqual(['A', 'Z']); expect(dayWords('2026-11-04')).toBe('4 Nov 2026'); });
});
describe('suggestions', () => {
  it('ranks by points, then newest', () => { expect(rankSuggestions([sg({ id: 'a', points: 3 }), sg({ id: 'b', points: 9 }), sg({ id: 'c', points: 3, created_at: '2026-11-22T10:00:00Z' })]).map((s) => s.id)).toEqual(['b', 'c', 'a']); });
  it('makes a CSV that survives commas, quotes and new lines', () => {
    const c = suggestionsCsv([sg({ title: 'Say "hi", please', detail: 'line one\nline two', points: 5 })]).split('\n');
    expect(c[0]).toBe('Rank,Title,Details,Area,Status,Points,Ratings,Average,Suggested by,Date'); expect(c.slice(1).join('\n')).toContain('"Say ""hi"", please","line one\nline two"');
  });
});
