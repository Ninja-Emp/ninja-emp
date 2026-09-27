-- ============================================================================
-- Ninja EMP — 98_append_only_guard.sql  (PER-TENANT, applied LAST)
--
-- 1. Adds a statement-level BEFORE TRUNCATE guard to every table that carries an
--    append-only row trigger (row triggers never fire on TRUNCATE).
-- 2. Sets every *_append_only / *_no_truncate trigger to ENABLE ALWAYS, so that
--    session_replication_role = replica cannot silently bypass them.
--
-- Depends on kernel.forbid_truncate() from 01_guard.sql.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- (1) One BEFORE TRUNCATE statement trigger per append-only table.
DO $$
DECLARE
  t record;
  v_guard text;
BEGIN
  FOR t IN
    SELECT n.nspname AS s, c.relname AS tb, c.oid AS toid
    FROM pg_trigger tg
    JOIN pg_class c ON c.oid = tg.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT tg.tgisinternal
      AND tg.tgname ~ '_append_only$'
      AND n.nspname = current_schema()
    GROUP BY n.nspname, c.relname, c.oid
  LOOP
    v_guard := 'trg_' || t.tb || '_no_truncate';
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgname = v_guard AND tgrelid = t.toid
    ) THEN
      EXECUTE format(
        'CREATE TRIGGER %I BEFORE TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION kernel.forbid_truncate()',
        v_guard, t.s, t.tb);
    END IF;
  END LOOP;
END $$;

-- (2) ENABLE ALWAYS on every append-only / no-truncate trigger in this schema.
--     Grouped per table into a single ALTER TABLE so the event trigger (which
--     inspects the whole table at ddl_command_end) sees them all already 'A'.
DO $$
DECLARE
  t record;
  actions text;
BEGIN
  FOR t IN
    SELECT n.nspname AS s, c.relname AS tb, c.oid AS toid
    FROM pg_trigger tg
    JOIN pg_class c ON c.oid = tg.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT tg.tgisinternal
      AND n.nspname = current_schema()
      AND tg.tgname ~ '(_append_only|_no_truncate)$'
      AND tg.tgenabled IS DISTINCT FROM 'A'
    GROUP BY n.nspname, c.relname, c.oid
  LOOP
    SELECT string_agg(format('ENABLE ALWAYS TRIGGER %I', tg.tgname), ', ' ORDER BY tg.tgname)
      INTO actions
      FROM pg_trigger tg
      WHERE tg.tgrelid = t.toid
        AND NOT tg.tgisinternal
        AND tg.tgname ~ '(_append_only|_no_truncate)$'
        AND tg.tgenabled IS DISTINCT FROM 'A';
    IF actions IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I.%I %s', t.s, t.tb, actions);
    END IF;
  END LOOP;
END $$;

-- (3) Arm the event triggers. Created here (not in 01_guard.sql) so they are
--     active only once every append-only trigger is already ENABLE ALWAYS.
--     Idempotent; DB-level, so it covers every tenant schema.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger
                 WHERE evtname = 'kernel_reject_append_only_trigger_change') THEN
    CREATE EVENT TRIGGER kernel_reject_append_only_trigger_change
      ON ddl_command_end WHEN TAG IN ('ALTER TABLE')
      EXECUTE FUNCTION kernel.reject_append_only_trigger_change();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger
                 WHERE evtname = 'kernel_reject_append_only_trigger_drop') THEN
    CREATE EVENT TRIGGER kernel_reject_append_only_trigger_drop
      ON sql_drop WHEN TAG IN ('DROP TRIGGER')
      EXECUTE FUNCTION kernel.reject_append_only_trigger_change();
  END IF;
END $$;

ALTER EVENT TRIGGER kernel_reject_append_only_trigger_change ENABLE ALWAYS;
ALTER EVENT TRIGGER kernel_reject_append_only_trigger_drop     ENABLE ALWAYS;

-- (4) Fail loudly if anything was missed.
DO $$
DECLARE
  v_bad int;
BEGIN
  SELECT count(*) INTO v_bad
  FROM pg_trigger tg
  JOIN pg_namespace n ON n.oid = (SELECT relnamespace FROM pg_class WHERE oid = tg.tgrelid)
  WHERE NOT tg.tgisinternal
    AND n.nspname = current_schema()
    AND tg.tgname ~ '(_append_only|_no_truncate)$'
    AND tg.tgenabled <> 'A';
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'append-only guard incomplete: % trigger(s) not ENABLE ALWAYS', v_bad;
  END IF;
END $$;
