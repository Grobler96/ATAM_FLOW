#!/usr/bin/env bash
# Runs all supabase/migrations against a throwaway local Postgres (stand-in for Supabase) and executes the tests.
# Usage: scripts/test-db.sh        (needs postgresql-16 binaries; runs as the `postgres` OS user if invoked as root)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PORT="${FLOW_TEST_PGPORT:-54329}"
WORK="$(mktemp -d /tmp/flowpg.XXXXXX)"
chmod 755 "$WORK"
run() { if [ "$(id -u)" = 0 ]; then su postgres -c "$*"; else bash -c "$*"; fi; }
[ "$(id -u)" = 0 ] && chown postgres "$WORK"
trap 'run "$PGBIN/pg_ctl -D $WORK/data stop -m immediate >/dev/null 2>&1 || true"; rm -rf "$WORK"' EXIT

run "$PGBIN/initdb -D $WORK/data -A trust -U postgres >/dev/null"
run "$PGBIN/pg_ctl -D $WORK/data -o '-p $PORT -k $WORK -c listen_addresses=' -l $WORK/log -w start >/dev/null"
PSQL="$PGBIN/psql -h $WORK -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
run "$PSQL -d postgres -c 'create database flowtest'"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/bootstrap_local.sql"
# applied migrations first, then supabase/pending (written + tested but not yet applied to the live project)
shopt -s nullglob
for f in "$ROOT"/supabase/migrations/*.sql "$ROOT"/supabase/pending/*.sql; do echo "applying $(basename "$f")"; run "$PSQL -d flowtest -f $f"; done
run "$PSQL -d flowtest -f $ROOT/supabase/tests/sync_test.sql" || { run "$PSQL -d flowtest -c \"select workflow,status,error from flow.flow_runs order by started_at desc limit 3\"" || true; exit 1; }

NODE="$(command -v node)"
run "env PSQL='$PSQL -d flowtest' ROOT='$ROOT' WORK='$WORK' NODE='$NODE' FIXED_NOW=2026-11-09T08:00:00Z bash $ROOT/scripts/scheduler-roundtrip.sh"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/third_party_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/purchasing_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/artwork_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/exceptions_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/warehouse_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/movement_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/downtime_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/supplier_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/qc_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/metrics_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/producer_risk_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/order_changes_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/courier_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/waste_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/assignment_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/pen_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/scope_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/priority_flag_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/portal_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/portal_spoilage_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/portal_packs_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/dispatch_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/proofs_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/stocktake_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/exception_digest_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/purchasing_controls_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/streamline_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/portal_security_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/portal_guard_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/portal_direct_test.sql"
run "env ROOT='$ROOT' $PSQL -d flowtest -f $ROOT/supabase/tests/portal_upload_cap_test.sql"   # reads the migration file itself, to run its storage rule against a stand-in table
run "$PSQL -d flowtest -f $ROOT/supabase/tests/config_audit_test.sql"
run "env ROOT='$ROOT' $PSQL -d flowtest -f $ROOT/supabase/tests/qc_evidence_storage_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/qc_checklist_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/crew_test.sql"
run "$PSQL -d flowtest -f $ROOT/supabase/tests/permissions_test.sql"
run "env PSQL='$PSQL -d flowtest' ROOT='$ROOT' WORK='$WORK' NODE='$NODE' FIXED_NOW=2026-11-09T09:00:00Z FIXED_TODAY=2026-11-09 bash $ROOT/scripts/allocation-roundtrip.sh"
run "env PSQL='$PSQL -d flowtest' ROOT='$ROOT' WORK='$WORK' NODE='$NODE' FIXED_TODAY=2026-11-09 bash $ROOT/scripts/selection-roundtrip.sh"
