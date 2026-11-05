import { exceptionActionTo } from './api';
import type { ActionResult } from '../types';

// Every producer-movement change goes through the audited "Movement actions" n8n workflow.
export const mvAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => exceptionActionTo('movements', action, params);

export interface StepDef { event: string; label: string; help: string; producerSide?: boolean; fields?: { key: string; label: string; type?: 'text' | 'number' | 'date'; required?: boolean; placeholder?: string }[] }
const STEPS: Record<string, StepDef> = {
  picked: { event: 'picked', label: 'Mark picked', help: 'The garments have been picked from stock and are at the staging bin.' },
  packed: { event: 'packed', label: 'Mark packed', help: 'The goods are in cartons and ready to go.', fields: [{ key: 'cartons', label: 'Number of cartons', type: 'number' }, { key: 'weight_kg', label: 'Total weight (kg)', type: 'number' }] },
  dispatched: { event: 'dispatched', label: 'Dispatch to producer', help: 'The consignment has left the building. This starts the return clock.', fields: [{ key: 'carrier', label: 'Carrier' }, { key: 'tracking_ref', label: 'Tracking / consignment reference', required: true }, { key: 'date', label: 'Dispatch date (blank = today)', type: 'date' }] },
  received_by_producer: { event: 'received_by_producer', label: 'Producer received it', help: 'Record that the producer has confirmed receipt. The turnaround clock starts from here.', producerSide: true },
  production_started: { event: 'production_started', label: 'Production started', help: 'The producer has begun decorating.', producerSide: true },
  production_complete: { event: 'production_complete', label: 'Production complete', help: 'The producer has finished decorating.', producerSide: true },
  awaiting_return: { event: 'awaiting_return', label: 'Ready for return', help: 'Finished and waiting to be collected or sent back.', producerSide: true },
  return_dispatched: { event: 'return_dispatched', label: 'Producer shipped it back', help: 'The goods are on their way back to us.', producerSide: true, fields: [{ key: 'tracking_ref', label: 'Return tracking reference' }] }
};
const ret = (extra: StepDef[] = []) => extra;
// What can be done next, for an outbound consignment, depending on where it is.
export function nextSteps(status: string): StepDef[] {
  switch (status) {
    case 'draft': return ret([STEPS.picked]);
    case 'picked': return ret([STEPS.packed]);
    case 'packed': return ret([STEPS.dispatched]);
    case 'dispatched': return ret([STEPS.received_by_producer]);
    case 'received_by_producer': return ret([STEPS.production_started, STEPS.production_complete]);
    case 'in_production': return ret([STEPS.production_complete]);
    case 'production_complete': return ret([STEPS.awaiting_return, STEPS.return_dispatched]);
    case 'in_transit_back': return [];
    default: return [];
  }
}
export const canCancel = (status: string): boolean => ['draft', 'picked', 'packed'].includes(status);
export const canBookReturn = (status: string): boolean => ['dispatched', 'received_by_producer', 'in_production', 'production_complete', 'in_transit_back', 'partially_returned'].includes(status);
export const canCheck = (status: string): boolean => ['returned', 'partially_returned', 'exception'].includes(status);
export const LIFECYCLE = ['draft', 'picked', 'packed', 'dispatched', 'received_by_producer', 'in_production', 'production_complete', 'in_transit_back', 'returned', 'checked'];
export const EVENT_LABEL: Record<string, string> = { created: 'Created', picked: 'Picked', packed: 'Packed', dispatched: 'Dispatched', received_by_producer: 'Producer received', production_started: 'Production started', production_complete: 'Production complete', awaiting_return: 'Ready for return',
  return_dispatched: 'Producer shipped back', return_received: 'Return booked in', return_checked: 'Return checked', direct_dispatch: 'Dispatched to customer', cancelled: 'Cancelled', labels_generated: 'Labels generated' };
export const RESOLUTIONS: { id: string; label: string }[] = [{ id: 'received_later', label: 'Received later' }, { id: 'replaced', label: 'Replaced by the producer' }, { id: 'credited', label: 'Credited' }, { id: 'accepted', label: 'Accepted as is' }, { id: 'written_off', label: 'Written off' }];
