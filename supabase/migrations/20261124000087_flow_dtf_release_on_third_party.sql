-- 24 Nov 2026: an order switched to third party lets go of its DTF placements (APPLIED to the live project 24 Nov 2026 as "flow_dtf_release_on_third_party").
-- The problem: an in-house DTF order to Super Print was built for order 636846, then the order was switched to third party. Its placements stayed
-- locked to the in-house DTF order, so the 3PD DTF prints page and the decorator portal never showed them, and the Super Print email (still waiting for
-- approval) would have ordered prints for a third-party order.
-- The fix: when an order's scope changes TO third party, every in-house DTF order that is still a draft (its email not yet sent) and holds one of its
-- placements is cancelled, with its email, and the placements are freed (the same thing as cancelling the email by hand). A DTF order that has
-- already been sent or received is left alone: those prints were really ordered. The other orders on a cancelled DTF order are freed too and can be
-- put on a new one. Every cancellation is written to the audit log with the reason.
create or replace function flow.dtf_release_third_party() returns trigger language plpgsql security definer set search_path = flow, public as $$
declare b record; r jsonb; v_n int;
begin
  if flow.order_scope(new) <> 'third_party' or flow.order_scope(old) = 'third_party' then return new; end if;
  for b in select distinct db.id, db.batch_ref, db.comm_id from flow.dtf_batches db join flow.dtf_items i on i.batch_id = db.id where i.order_id = new.id and db.status = 'draft' loop
    if b.comm_id is not null then
      r := flow.comm_cancel(b.comm_id, 'system:order_became_third_party');
      -- the email is already on its way out (sending or sent): leave it, the DTF order becomes "ordered" when it is sent
      if not coalesce((r->>'ok')::boolean, false) and coalesce((select status from flow.communications where id = b.comm_id), '') <> 'cancelled' then continue; end if;
    end if;
    update flow.dtf_batches set status = 'cancelled' where id = b.id and status = 'draft';
    update flow.dtf_items set batch_id = null, updated_at = now() where batch_id = b.id;
    get diagnostics v_n = row_count;
    insert into flow.audit_log (actor, action, entity, entity_id, reason, after)
    values ('system:order_became_third_party', 'dtf_order_cancelled', 'dtf_batches', b.id::text, 'Order ' || new.order_ref || ' was switched to third party, so its DTF order to Super Print was cancelled and its placements freed',
            jsonb_build_object('batch_ref', b.batch_ref, 'order_ref', new.order_ref, 'placements_freed', v_n));
  end loop;
  return new;
end $$;

drop trigger if exists dtf_release_third_party on flow.orders;
create trigger dtf_release_third_party after update of scope_override, third_party_flag on flow.orders
  for each row when (old.scope_override is distinct from new.scope_override or old.third_party_flag is distinct from new.third_party_flag)
  execute function flow.dtf_release_third_party();

do $$
begin
  revoke all on function flow.dtf_release_third_party() from public, anon, authenticated;
end $$;
