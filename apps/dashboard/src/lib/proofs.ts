import { exceptionActionTo } from './api';
import { opsAction } from './orderChanges';
import type { ActionResult } from '../types';
import type { Tone } from '../ui/primitives';

export interface ArtworkFileRow {
  id: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; deco_line_id: string | null; area: string; process: string | null; version: number; is_current: boolean;
  source: string; approval_status: 'approved' | 'pending' | 'rejected' | 'unknown'; storage_status: string; storage_path: string | null; file_format: string | null; stitch_count: number | null;
  width_mm: number | null; height_mm: number | null; placement: string | null; readable: boolean | null; has_deconetwork_proof: boolean; proof_url: string | null; thumbnail_url?: string | null; note: string | null; created_by: string | null; created_at: string; stored_at: string | null;
}
export type ProofStatus = 'draft' | 'sent' | 'approved' | 'changes_requested' | 'rejected' | 'superseded' | 'withdrawn';
export interface ProofRow {
  id: string; proof_ref: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; artwork_ids: string[]; areas: string[]; storage_path: string; file_name: string; status: ProofStatus;
  note: string | null; created_by: string; created_at: string; sent_to: string | null; sent_via: string | null; sent_by: string | null; sent_at: string | null; answered_by: string | null; answer_note: string | null;
  answer_evidence_path: string | null; recorded_by: string | null; answered_at: string | null; closed_reason: string | null; closed_by: string | null; closed_at: string | null; is_out_of_date: boolean; days_waiting: number | null;
}

export const PROOF_LABEL: Record<ProofStatus, string> = { draft: 'Draft', sent: 'Sent, waiting for the customer', approved: 'Approved', changes_requested: 'Changes requested', rejected: 'Rejected', superseded: 'Replaced by a newer proof', withdrawn: 'Withdrawn' };
export const PROOF_TONE: Record<ProofStatus, Tone> = { draft: '', sent: 'medium', approved: 'good', changes_requested: 'high', rejected: 'critical', superseded: '', withdrawn: '' };
export const VIA_LABEL: Record<string, string> = { email: 'Email', phone: 'Phone', in_person: 'In person', portal: 'Customer portal', other: 'Other' };
export const APPROVAL_LABEL: Record<string, string> = { approved: 'Approved', pending: 'Waiting for the customer', rejected: 'Rejected', unknown: 'Not known' };
export const APPROVAL_TONE: Record<string, Tone> = { approved: 'good', pending: 'medium', rejected: 'critical', unknown: '' };

// Files: the artwork workflow's existing actions. Proofs: the Operations actions workflow. All audited and checked again in the database.
export const artworkReplace = (p: { order_id: string; deco_line_id: string | null; area: string; storage_path: string; note: string; meta: Record<string, unknown> }): Promise<ActionResult> => exceptionActionTo('artwork', 'manual_replace', p);
export const artworkSetApproval = (artwork_id: string, status: string, note: string): Promise<ActionResult> => exceptionActionTo('artwork', 'set_approval', { artwork_id, status, note });
export const proofCreate = (p: { order_id: string; artwork_ids: string[]; storage_path: string; file_name: string; note?: string }): Promise<ActionResult> => opsAction('proof_create', p);
export const proofSend = (proof_id: string, to: string, via: string, note?: string): Promise<ActionResult> => opsAction('proof_send', { proof_id, to, via, note });
export const proofRespond = (p: { proof_id: string; outcome: string; by: string; note?: string; evidence?: string | null }): Promise<ActionResult> => opsAction('proof_respond', p);
export const proofWithdraw = (proof_id: string, reason: string): Promise<ActionResult> => opsAction('proof_withdraw', { proof_id, reason });

// Job packs: the artwork workflow's build_pack and mark_pack_sent actions (already checked again in the database).
export const packBuild = (order_id: string, producer_id: string): Promise<ActionResult> => exceptionActionTo('artwork', 'build_pack', { order_id, producer_id });
export const packMarkSent = (pack_id: string): Promise<ActionResult> => exceptionActionTo('artwork', 'mark_pack_sent', { pack_id });
