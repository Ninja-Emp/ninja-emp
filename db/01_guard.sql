-- ============================================================================
-- Ninja EMP — 01_guard.sql  (ONCE per database, applied right after 00_kernel.sql)
--
-- Hardens the append-only guarantees so they survive the three ways a session
-- could otherwise clear them and then rewrite history:
--
--   * session_replication_role = replica   (logical replication, pg_restore -D)
--   * ALTER TABLE ... DISABLE TRIGGER
--   * DROP TRIGGER
--
-- The row triggers themselves are set ENABLE ALWAYS by 98_append_only_guard.sql
-- (per tenant). The event triggers created here are ALSO ENABLE ALWAYS, so the
-- same session cannot disable or drop those row triggers.
--
-- Irreducible escape (documented, not hidden): PostgreSQL never fires an event
-- trigger for ALTER EVENT TRIGGER / DROP EVENT TRIGGER / CREATE EVENT TRIGGER,
-- and event_triggers=false is a superuser GUC. A superuser can therefore always
-- remove the guard itself. That is the last line, and it is deliberate.
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- forbid_truncate(): statement-level BEFORE TRUNCATE guard.
-- Row triggers never fire on TRUNCATE, so without this a single TRUNCATE wipes
-- the ledger (and CASCADEs through every table that references it).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION kernel.forbid_truncate() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Table % is append-only; TRUNCATE is not permitted.', TG_TABLE_NAME
    USING ERRCODE = '55000';
END; $$;
COMMENT ON FUNCTION kernel.forbid_truncate() IS
  'Statement-level BEFORE TRUNCATE guard for append-only tables.';

-- ----------------------------------------------------------------------------
-- reject_append_only_trigger_change(): event trigger.
-- Refuses DISABLE or DROP of any *_append_only / *_no_truncate trigger that
-- lives in a tenant schema.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION kernel.reject_append_only_trigger_change()
RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE
  command record;
  dropped record;
BEGIN
  IF TG_EVENT = 'sql_drop' THEN
    FOR dropped IN
      SELECT schema_name, object_identity
      FROM pg_event_trigger_dropped_objects()
      WHERE object_type = 'trigger'
    LOOP
      IF dropped.schema_name LIKE 'tenant_%'
         AND split_part(dropped.object_identity, ' ', 1) ~ '(_append_only|_no_truncate)$'
      THEN
        RAISE EXCEPTION 'append-only triggers cannot be dropped (%).', dropped.object_identity
          USING ERRCODE = '55000';
      END IF;
    END LOOP;
    RETURN;
  END IF;

  FOR command IN
    SELECT schema_name, command_tag, objid
    FROM pg_event_trigger_ddl_commands()
  LOOP
    IF command.command_tag <> 'ALTER TABLE' THEN CONTINUE; END IF;
    IF command.schema_name NOT LIKE 'tenant_%' THEN CONTINUE; END IF;
    IF EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = command.objid
        AND NOT tgisinternal
        AND tgname ~ '(_append_only|_no_truncate)$'
        AND tgenabled <> 'A'
    ) THEN
      RAISE EXCEPTION 'append-only triggers cannot be disabled'
        USING ERRCODE = '55000';
    END IF;
  END LOOP;
END; $$;
COMMENT ON FUNCTION kernel.reject_append_only_trigger_change() IS
  'Event trigger: refuses DISABLE/DROP of append-only triggers in tenant schemas.';

-- NOTE: the event triggers that USE this function are created at the very end of
-- provisioning (98_append_only_guard.sql), after every append-only trigger is
-- already ENABLE ALWAYS. Arming them earlier would refuse the setup-time
-- `ALTER TABLE ... DISABLE ROW LEVEL SECURITY` in 90_rls.sql, when the row
-- triggers are still in the default 'O' state.

-- ----------------------------------------------------------------------------
-- append_only_guards_set(p_enabled): lift / restore the guards for a controlled
-- bulk maintenance operation (used by scrub.sql on a restored, throwaway copy).
-- Lifting drops the event triggers FIRST (ALTER EVENT TRIGGER does not fire an
-- event trigger) so the subsequent ALTER TABLE ... DISABLE TRIGGER is allowed.
-- Restoring re-enables the row triggers first, then the event triggers.
-- Superuser-only in practice: ALTER TABLE requires table ownership.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION kernel.append_only_guards_set(p_enabled boolean)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  t record;
BEGIN
  IF p_enabled THEN
    FOR t IN
      SELECT n.nspname AS s, c.relname AS tb, tg.tgname AS tg
      FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE NOT tg.tgisinternal
        AND n.nspname LIKE 'tenant_%'
        AND tg.tgname ~ '(_append_only|_no_truncate)$'
    LOOP
      EXECUTE format('ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER %I', t.s, t.tb, t.tg);
    END LOOP;
    EXECUTE 'ALTER EVENT TRIGGER kernel_reject_append_only_trigger_change ENABLE ALWAYS';
    EXECUTE 'ALTER EVENT TRIGGER kernel_reject_append_only_trigger_drop     ENABLE ALWAYS';
  ELSE
    EXECUTE 'ALTER EVENT TRIGGER kernel_reject_append_only_trigger_change DISABLE';
    EXECUTE 'ALTER EVENT TRIGGER kernel_reject_append_only_trigger_drop     DISABLE';
    FOR t IN
      SELECT n.nspname AS s, c.relname AS tb, tg.tgname AS tg
      FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE NOT tg.tgisinternal
        AND n.nspname LIKE 'tenant_%'
        AND tg.tgname ~ '(_append_only|_no_truncate)$'
    LOOP
      EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER %I', t.s, t.tb, t.tg);
    END LOOP;
  END IF;
END; $$;
COMMENT ON FUNCTION kernel.append_only_guards_set(boolean) IS
  'Lift/restore append-only guards for a controlled maintenance op (scrub). Superuser-only.';
REVOKE EXECUTE ON FUNCTION kernel.append_only_guards_set(boolean) FROM PUBLIC;
