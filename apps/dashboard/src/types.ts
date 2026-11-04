export type Severity = 'critical' | 'high' | 'medium' | 'low';
export type Status = 'open' | 'investigating' | 'awaiting_supplier' | 'awaiting_producer' | 'awaiting_customer';

export interface ExceptionRow {
  id: string; exc_ref: string; type_code: string; type_label: string; category: string;
  severity: Severity; severity_rank: number; status: Status; blocks: string[]; is_blocking: boolean;
  description: string; detected_by: string; detected_at: string;
  owner: string | null; owner_role: string | null; needs_owner: boolean;
  response_deadline: string; is_overdue: boolean; age_hours: number; age_bucket: string; escalation_level: number;
  customer_impact: string | null; financial_impact: number | null; financial_breakdown: Record<string, number> | null;
  recommended_action: string | null; root_cause: string | null;
  order_refs: string[]; skus: string[]; po_refs: string[]; movement_refs: string[]; producers: string[]; communications: number;
}

export interface HistoryRow { exception_id: string; at: string; actor: string | null; action: string; from_status: string | null; to_status: string | null; note: string | null }
export interface StatusRow { last_detection_at: string | null; server_time: string }
export type Role = 'admin' | 'manager' | 'production' | 'warehouse' | 'viewer';

export interface ActionResult { ok: boolean; error?: string; note?: string; [k: string]: unknown }
