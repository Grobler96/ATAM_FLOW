import { supabase } from './api';

// Quality-check photos from a device. They go into the existing private evidence bucket under qc/<order>/ (staff roles only, see migration 64) and the
// check keeps a reference: { bucket, path, name }. Pasted links are still accepted: { url, name }.
export const QC_BUCKET = 'producer-evidence';
export const QC_MAX_BYTES = 10 * 1024 * 1024;   // the bucket's own limit per file
export const QC_MAX_FILES = 6;                   // per check, to keep the form manageable
export const QC_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'];
export interface QcEvidence { url?: string; path?: string; bucket?: string; name?: string }

export function qcPhotoProblem(file: { name: string; type: string; size: number }): string | null {
  if (!QC_TYPES.includes(file.type)) return `${file.name}: only photos (JPEG, PNG, WebP, HEIC) and PDFs can be added.`;
  if (file.size <= 0) return `${file.name}: the file is empty.`;
  if (file.size > QC_MAX_BYTES) return `${file.name}: it is over ${QC_MAX_BYTES / 1024 / 1024} MB. Use a smaller photo.`;
  return null;
}

// qc/<order>/<time>-<name>, with anything odd in the order reference or file name made safe.
export function qcPhotoPath(orderRef: string, fileName: string, now = Date.now()): string {
  const order = orderRef.replace(/^#/, '').replace(/[^\w-]+/g, '_').replace(/^_+|_+$/g, '') || 'order';
  const name = fileName.replace(/[^\w.-]+/g, '_').replace(/^\.+/, '').slice(-80) || 'photo';
  return `qc/${order}/${now}-${name}`;
}

// A refused upload is explained in plain words (the database's own message means nothing to the person holding the phone).
export function qcUploadProblem(fileName: string, message: string | null | undefined): string {
  const m = (message ?? '').trim();
  if (/row-level security/i.test(m)) return `${fileName}: your login cannot add photos here yet. Paste a link instead, or ask an admin.`;
  return `${fileName}: ${m || 'the photo did not upload'}. Remove it and try again, or paste a link instead.`;
}

// What a person sees on a check: a link, or a file they can open.
export const evidenceLabel = (e: QcEvidence, i: number) => (e.name && e.name !== 'Quality evidence' ? e.name : `Photo ${i + 1}`);
export const isWebLink = (e: QcEvidence) => typeof e.url === 'string' && /^https?:\/\//i.test(e.url);

export async function uploadQcPhoto(file: File, orderRef: string): Promise<{ ok: true; evidence: QcEvidence } | { ok: false; error: string }> {
  const bad = qcPhotoProblem(file); if (bad) return { ok: false, error: bad };
  const path = qcPhotoPath(orderRef, file.name);
  const { error } = await supabase.storage.from(QC_BUCKET).upload(path, file, { contentType: file.type, upsert: false });
  if (error) return { ok: false, error: qcUploadProblem(file.name, error.message) };
  return { ok: true, evidence: { bucket: QC_BUCKET, path, name: file.name } };
}

export async function signedQcUrl(e: QcEvidence): Promise<string | null> {
  if (!e.path) return isWebLink(e) ? e.url ?? null : null;
  const { data, error } = await supabase.storage.from(e.bucket ?? QC_BUCKET).createSignedUrl(e.path, 300);
  return error || !data ? null : data.signedUrl;
}
