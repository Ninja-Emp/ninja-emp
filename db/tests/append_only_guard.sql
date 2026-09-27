-- ============================================================================
-- Ninja EMP — tests/append_only_guard.sql
-- Proves the append-only guarantees survive the three ways a session could
-- otherwise clear them and rewrite history:
--   (a) session_replication_role = replica
--   (b) ALTER TABLE ... DISABLE TRIGGER / ENABLE REPLICA TRIGGER
--   (c) DROP TRIGGER
-- plus: a non-superuser role cannot flip the switch at all.
-- Assumes db/provision.sh has run (01_guard.sql + 98_append_only_guard.sql).
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/append_only_guard.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';

\echo '=== T0: seed one posted entry so the row triggers have a row to fire on ==='
SELECT post_journal_entry(
  current_date, 'guard-test memo', 'manual', 'guard-test', 'guard-test-key',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',1,'currency','USD'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1010'),'credit',1,'currency','USD')
  )
);

\echo '=== T1: both guard event triggers exist and are ENABLE ALWAYS ==='
DO $$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM pg_event_trigger
   WHERE evtname IN ('kernel_reject_append_only_trigger_change',
                     'kernel_reject_append_only_trigger_drop')
     AND evtenabled = 'A';
  IF v_n = 2 THEN RAISE NOTICE 'PASS: 2/2 guard event triggers ENABLE ALWAYS';
  ELSE RAISE EXCEPTION 'FAIL: only %/2 guard event triggers armed', v_n; END IF;
END $$;

\echo '=== T2: every append-only / no-truncate trigger is ENABLE ALWAYS ==='
DO $$
DECLARE v_bad int; v_all int;
BEGIN
  SELECT count(*) INTO v_all FROM pg_trigger t
    JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = t.tgrelid)
   WHERE NOT t.tgisinternal AND n.nspname = current_schema()
     AND t.tgname ~ '(_append_only|_no_truncate)$';
  SELECT count(*) INTO v_bad FROM pg_trigger t
    JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = t.tgrelid)
   WHERE NOT t.tgisinternal AND n.nspname = current_schema()
     AND t.tgname ~ '(_append_only|_no_truncate)$' AND t.tgenabled <> 'A';
  IF v_bad = 0 AND v_all >= 14 THEN
    RAISE NOTICE 'PASS: %/% triggers ENABLE ALWAYS', v_all, v_all;
  ELSE RAISE EXCEPTION 'FAIL: % of % triggers not ENABLE ALWAYS', v_bad, v_all; END IF;
END $$;

\echo '=== T3: replica-mode UPDATE of a posted entry is REJECTED ==='
DO $$
DECLARE v_bypass boolean := false;
BEGIN
  PERFORM set_config('session_replication_role','replica',true);
  BEGIN
    UPDATE journal_entry SET memo = 'TAMPERED';
    v_bypass := true;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  PERFORM set_config('session_replication_role','origin',true);
  IF v_bypass THEN RAISE EXCEPTION 'FAIL: replica-mode UPDATE was allowed';
  ELSE RAISE NOTICE 'PASS: replica-mode UPDATE refused'; END IF;
END $$;

\echo '=== T4: replica-mode DELETE of a posted entry is REJECTED ==='
DO $$
DECLARE v_bypass boolean := false;
BEGIN
  PERFORM set_config('session_replication_role','replica',true);
  BEGIN
    DELETE FROM journal_entry;
    v_bypass := true;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  PERFORM set_config('session_replication_role','origin',true);
  IF v_bypass THEN RAISE EXCEPTION 'FAIL: replica-mode DELETE was allowed';
  ELSE RAISE NOTICE 'PASS: replica-mode DELETE refused'; END IF;
END $$;

\echo '=== T5: TRUNCATE of the ledger is REJECTED ==='
DO $$
DECLARE v_bypass boolean := false;
BEGIN
  BEGIN
    EXECUTE 'TRUNCATE journal_line, journal_entry CASCADE';
    v_bypass := true;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  IF v_bypass THEN RAISE EXCEPTION 'FAIL: TRUNCATE was allowed';
  ELSE RAISE NOTICE 'PASS: TRUNCATE refused'; END IF;
END $$;

\echo '=== T6: ALTER TABLE ... DISABLE TRIGGER is REJECTED ==='
DO $$
DECLARE v_bypass boolean := false;
BEGIN
  BEGIN
    EXECUTE 'ALTER TABLE journal_entry DISABLE TRIGGER trg_journal_entry_append_only';
    v_bypass := true;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  IF v_bypass THEN RAISE EXCEPTION 'FAIL: DISABLE TRIGGER was allowed';
  ELSE RAISE NOTICE 'PASS: DISABLE TRIGGER refused'; END IF;
END $$;

\echo '=== T7: ALTER TABLE ... ENABLE REPLICA TRIGGER is REJECTED ==='
DO $$
DECLARE v_bypass boolean := false;
BEGIN
  BEGIN
    EXECUTE 'ALTER TABLE journal_entry ENABLE REPLICA TRIGGER trg_journal_entry_append_only';
    v_bypass := true;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  IF v_bypass THEN RAISE EXCEPTION 'FAIL: ENABLE REPLICA TRIGGER was allowed';
  ELSE RAISE NOTICE 'PASS: ENABLE REPLICA TRIGGER refused'; END IF;
END $$;

\echo '=== T8: DROP TRIGGER on the append-only guard is REJECTED ==='
DO $$
DECLARE v_bypass boolean := false;
BEGIN
  BEGIN
    EXECUTE 'DROP TRIGGER trg_journal_entry_append_only ON journal_entry';
    v_bypass := true;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  IF v_bypass THEN RAISE EXCEPTION 'FAIL: DROP TRIGGER was allowed';
  ELSE RAISE NOTICE 'PASS: DROP TRIGGER refused'; END IF;
END $$;

\echo '=== T9: a non-superuser role cannot set session_replication_role ==='
DO $$
DECLARE v_bypass boolean := false;
BEGIN
  BEGIN
    SET LOCAL ROLE ninja_app;
    SET LOCAL session_replication_role = replica;
    v_bypass := true;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  RESET ROLE;
  IF v_bypass THEN RAISE EXCEPTION 'FAIL: ninja_app set session_replication_role';
  ELSE RAISE NOTICE 'PASS: ninja_app denied session_replication_role'; END IF;
END $$;

\echo '=== T10: the maintenance helper lifts and restores every guard ==='
DO $$
DECLARE v_down int; v_up int;
BEGIN
  PERFORM kernel.append_only_guards_set(false);
  SELECT count(*) INTO v_down FROM pg_trigger t
    JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = t.tgrelid)
   WHERE NOT t.tgisinternal AND n.nspname LIKE 'tenant_%'
     AND t.tgname ~ '(_append_only|_no_truncate)$' AND t.tgenabled = 'D';
  PERFORM kernel.append_only_guards_set(true);
  SELECT count(*) INTO v_up FROM pg_trigger t
    JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = t.tgrelid)
   WHERE NOT t.tgisinternal AND n.nspname LIKE 'tenant_%'
     AND t.tgname ~ '(_append_only|_no_truncate)$' AND t.tgenabled = 'A';
  IF v_down >= 14 AND v_up = v_down THEN
    RAISE NOTICE 'PASS: helper lifted % and restored % guards', v_down, v_up;
  ELSE RAISE EXCEPTION 'FAIL: helper lift=% restore=%', v_down, v_up; END IF;
END $$;

\echo '=== append-only guard: all checks complete ==='
