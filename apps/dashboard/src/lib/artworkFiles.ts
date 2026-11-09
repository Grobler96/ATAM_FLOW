import { supabase } from './api';

// Artwork and proof files live in the private `artwork` bucket. Staff (admin, manager, production) may upload; everyone on the team may read through a short-lived signed link.
export const ART_BUCKET = 'artwork';
export const MAX_BYTES = 100 * 1024 * 1024;                       // the bucket's own limit
export const ALLOWED_EXT = ['dst', 'pes', 'exp', 'jef', 'emb', 'ai', 'eps', 'pdf', 'svg', 'png', 'jpg', 'jpeg', 'webp', 'tif', 'tiff', 'psd', 'cdr', 'zip'];
export const PROOF_EXT = ['pdf', 'png', 'jpg', 'jpeg', 'webp'];     // what a customer can be shown

const lastPart = (name: string): string => name.split(/[\\/]/).pop() ?? '';          // never trust folders in a file name
export const extOf = (name: string): string => { const n = lastPart(name); const e = n.includes('.') ? n.split('.').pop()!.toLowerCase() : ''; return /^[a-z0-9]{1,8}$/.test(e) ? e : ''; };
export const safeName = (name: string): string => {
  const n = lastPart(name); const e = extOf(n); const base = (e ? n.slice(0, -(e.length + 1)) : n).normalize('NFKD').replace(/[^\w.-]+/g, '-').replace(/-+/g, '-').replace(/^[-.]+|[-.]+$/g, '').slice(0, 80) || 'file';
  return e ? `${base}.${e}` : base;
};
export const slug = (s: string): string => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'area';
export const orderKey = (ref: string): string => ref.replace(/^#/, '');
// Paths must match what the database accepts: proofs live under proofs/<order>/.
export const artworkPath = (orderRef: string, area: string, version: number, fileName: string, stamp = Date.now()): string => `orders/${orderKey(orderRef)}/${slug(area)}/v${version}-${stamp}-${safeName(fileName)}`;
export const proofPath = (orderRef: string, fileName: string, stamp = Date.now()): string => `proofs/${orderKey(orderRef)}/${stamp}-${safeName(fileName)}`;

// Returns a plain-English problem, or null if the file is fine.
export function checkFile(file: File, allowed: string[] = ALLOWED_EXT): string | null {
  if (file.size === 0) return 'That file is empty.';
  if (file.size > MAX_BYTES) return `That file is ${(file.size / 1048576).toFixed(0)} MB. The limit is ${MAX_BYTES / 1048576} MB.`;
  const e = extOf(file.name);
  if (!allowed.includes(e)) return `.${e || '?'} files are not accepted here. Use one of: ${allowed.join(', ')}.`;
  return null;
}
export const isImage = (name: string): boolean => ['png', 'jpg', 'jpeg', 'webp', 'svg'].includes(extOf(name));
export const isPdf = (name: string): boolean => extOf(name) === 'pdf';
export const fileNameOf = (path: string | null | undefined): string => (path ? path.replace(/^.*\//, '').replace(/^v\d+-\d+-/, '').replace(/^\d+-/, '') : '');

// Returns null on success or the problem.
export async function uploadFile(path: string, file: File): Promise<string | null> {
  const { error } = await supabase.storage.from(ART_BUCKET).upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false });
  return error ? error.message : null;
}
// The bucket has no delete rule for staff on purpose (history is never lost), so this is only a best-effort attempt: a leftover unused file is harmless.
export async function removeFile(path: string): Promise<void> { try { await supabase.storage.from(ART_BUCKET).remove([path]); } catch { /* not allowed or failed: leave it */ } }
export async function signedUrl(path: string, downloadAs?: string): Promise<string | null> {
  const { data, error } = await supabase.storage.from(ART_BUCKET).createSignedUrl(path, 300, downloadAs ? { download: downloadAs } : undefined);
  return error || !data?.signedUrl ? null : data.signedUrl;
}
export async function downloadFile(path: string, name: string): Promise<boolean> {
  const url = await signedUrl(path, name); if (!url) return false;
  const a = document.createElement('a'); a.href = url; a.download = name; a.rel = 'noreferrer'; document.body.appendChild(a); a.click(); a.remove(); return true;
}
