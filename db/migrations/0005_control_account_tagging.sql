-- ============================================================================
-- 0005_control_account_tagging.sql
--
-- Closes an integrity hole in the ledger core, and promotes the layaway
-- deposit account to a proper control account.
--
-- ---------------------------------------------------------------------------
-- PART A — THE HOLE
--
-- assert_subledger_control() guarded only one direction: it stopped a TAGGED
-- line from landing on the wrong account. Nothing stopped an UNTAGGED line
-- from landing on a CONTROL account.
--
-- So this was legal:
--
--   debit  1100 Accounts Receivable   500.00     <-- no party
--   credit 4000 Sales Revenue         500.00
--
-- The entry balances. The trial balance stays at zero. Every existing
-- assertion passes. And 500.00 of receivable is now owed by NOBODY: it is on
-- no customer statement, it can never be invoiced, and it will never be
-- collected. It surfaces only later as an unexplained difference in
-- subledger_control_check(), long after the originating transaction is
-- findable.
--
-- Balanced is not the same as correct. This migration adds the preventive
-- control so the detective one stays boring.
--
-- BEARER EXCEPTION: an anonymous gift certificate genuinely has no party.
-- That is whitelisted per subledger type via subledger_type.allows_untagged
-- rather than by weakening the rule.
--
-- ---------------------------------------------------------------------------
-- PART B — LAYAWAY DEPOSITS
--
-- 2450 Layaway Deposits shipped as a plain liability. It is customer money
-- held on trust, which makes it exactly the same shape as a security deposit,
-- and "whose money is this" is the first question in any layaway dispute.
-- Promoted to a control account behind a new 'layaway_deposit' subledger type.
--
-- Idempotent and re-runnable. Refuses to proceed if existing data would be
-- made non-compliant, rather than installing a constraint the live books
-- already violate.
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- A1. subledger_type gains allows_untagged, and the new layaway type.
-- ----------------------------------------------------------------------------
ALTER TABLE kernel.subledger_type
  ADD COLUMN IF NOT EXISTS allows_untagged boolean NOT NULL DEFAULT false;
ALTER TABLE kernel.subledger_type
  ADD COLUMN IF NOT EXISTS uses_open_items boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN kernel.subledger_type.allows_untagged IS
  'True only for genuine BEARER instruments, where there is no party to record.';
COMMENT ON COLUMN kernel.subledger_type.uses_open_items IS
  'True when this subledger''s detail lives in open_item; drives open_item_control_check scoping.';

-- Which subledgers are open-item backed. The rest keep their detail in their
-- own tables (lease_deposit, layaway_payment, stored_value) or are accrued
-- straight to the control account, and must NOT be reported as imbalances.
UPDATE kernel.subledger_type
   SET uses_open_items = (code IN ('ar','ap','consignor_payable'));

-- A bearer gift certificate has no holder by design.
UPDATE kernel.subledger_type SET allows_untagged = true  WHERE code = 'gift_certificate';
UPDATE kernel.subledger_type SET allows_untagged = false WHERE code <> 'gift_certificate';

INSERT INTO kernel.subledger_type (code, name, description, allows_untagged) VALUES
  ('layaway_deposit', 'Layaway Deposit',
   'Customer money held on trust against an open layaway.', false)
ON CONFLICT (code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- A2. Refuse to install the guard over books that already violate it.
--
-- Installing a constraint that existing data breaks is how a migration turns
-- into an outage. Report the offending lines and stop.
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_schema text;
  v_bad    bigint;
  v_total  bigint := 0;
BEGIN
  FOR v_schema IN
    SELECT nspname FROM pg_namespace WHERE nspname LIKE 'tenant_%' ORDER BY nspname
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = v_schema AND c.relname = 'journal_line'
    ) THEN CONTINUE; END IF;

    EXECUTE format($q$
      SELECT count(*) FROM %I.journal_line jl
        JOIN %I.account a ON a.id = jl.account_id
        JOIN kernel.subledger_type st ON st.code = a.control_subledger_type_code
       WHERE jl.subledger_type_code IS NULL
         AND a.is_control
         AND NOT st.allows_untagged
    $q$, v_schema, v_schema) INTO v_bad;

    IF v_bad > 0 THEN
      RAISE WARNING '0005: % has % untagged line(s) on control accounts', v_schema, v_bad;
      v_total := v_total + v_bad;
    END IF;
  END LOOP;

  IF v_total > 0 THEN
    RAISE EXCEPTION
      '0005 ABORTED: % existing journal line(s) post to a control account with no party. These are orphaned balances that must be investigated and reversed before the guard can be installed. Query them with: SELECT jl.* FROM journal_line jl JOIN account a ON a.id=jl.account_id WHERE jl.subledger_type_code IS NULL AND a.is_control;',
      v_total;
  END IF;
END $precheck$;

-- ----------------------------------------------------------------------------
-- A3. Install the guard on every tenant schema.
-- ----------------------------------------------------------------------------
DO $install$
DECLARE v_schema text;
BEGIN
  FOR v_schema IN
    SELECT nspname FROM pg_namespace WHERE nspname LIKE 'tenant_%' ORDER BY nspname
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = v_schema AND c.relname = 'journal_line'
    ) THEN CONTINUE; END IF;

    EXECUTE format($fn$
      CREATE OR REPLACE FUNCTION %I.assert_control_account_tagged() RETURNS trigger
      LANGUAGE plpgsql AS $body$
      DECLARE
        v_sub      text;
        v_untagged boolean;
        v_code     text;
        v_name     text;
      BEGIN
        IF NEW.subledger_type_code IS NOT NULL THEN RETURN NEW; END IF;

        SELECT a.control_subledger_type_code, a.code, a.name
          INTO v_sub, v_code, v_name
          FROM %I.account a
         WHERE a.id = NEW.account_id AND a.is_control;

        IF v_sub IS NULL THEN RETURN NEW; END IF;

        SELECT st.allows_untagged INTO v_untagged
          FROM kernel.subledger_type st WHERE st.code = v_sub;

        IF COALESCE(v_untagged, false) THEN RETURN NEW; END IF;

        RAISE EXCEPTION
          'Account %% (%%) is the %% control account; a posting to it must name the party (party_id + subledger_type_code). Untagged money here is owed to nobody and will never be collected or paid.',
          v_code, v_name, v_sub
          USING ERRCODE = '23514';
      END; $body$
    $fn$, v_schema, v_schema);

    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_journal_line_control_tagged ON %I.journal_line', v_schema);
    EXECUTE format($t$
      CREATE TRIGGER trg_journal_line_control_tagged
        BEFORE INSERT ON %I.journal_line
        FOR EACH ROW EXECUTE FUNCTION %I.assert_control_account_tagged()
    $t$, v_schema, v_schema);

    RAISE NOTICE '0005: control-account tagging guard installed on %', v_schema;
  END LOOP;
END $install$;

-- ----------------------------------------------------------------------------
-- B. Promote 2450 Layaway Deposits to a control account.
--
-- Only safe where the account carries no untagged history; if it does, the
-- precheck above has already aborted the migration.
-- ----------------------------------------------------------------------------
DO $layaway$
DECLARE v_schema text;
BEGIN
  FOR v_schema IN
    SELECT nspname FROM pg_namespace WHERE nspname LIKE 'tenant_%' ORDER BY nspname
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = v_schema AND c.relname = 'account'
    ) THEN CONTINUE; END IF;

    EXECUTE format($q$
      UPDATE %I.account
         SET is_control = true,
             control_subledger_type_code = 'layaway_deposit'
       WHERE code = '2450' AND NOT is_control
    $q$, v_schema);
  END LOOP;
END $layaway$;

-- ----------------------------------------------------------------------------
-- VERIFY, in-transaction, that the guard actually bites and that the bearer
-- exemption still works. A migration that logs success without proving the
-- behaviour changed is just a log line.
-- ----------------------------------------------------------------------------
--
-- HISTORY / WHY THIS LOOKS THE WAY IT DOES
--
-- The first version of this block probed with:
--
--     INSERT INTO journal_line (...)
--     SELECT id, 999, $1, 1.00, ... FROM journal_entry LIMIT 1;
--
-- That is a VACUOUS TEST. On a freshly provisioned tenant there are no
-- journal_entry rows, so the SELECT feeds zero rows, the INSERT trivially
-- succeeds having inserted nothing, no exception is raised, v_ok stays false
-- and the migration aborts claiming "an untagged line was accepted" -- which
-- never happened. It fails clean-room but passes on a database that already
-- has history, i.e. it passes exactly where it is least able to tell you
-- anything and fails exactly where the schema is most provably correct.
--
-- The symmetric danger is worse: because the probe depended on outside state,
-- a build with NO journal history and a BROKEN guard would insert zero rows
-- and be indistinguishable from a build with a working guard. A test that
-- cannot fail is not a test.
--
-- So the probe below manufactures its OWN fixture (tenant, party, period-valid
-- entry), asserts BOTH directions, and then unwinds itself:
--
--   negative control : untagged line on a control account MUST be refused
--   positive control : the same line WITH party_id + subledger_type_code
--                      MUST be accepted -- otherwise a guard that rejected
--                      everything unconditionally would "pass" the negative
--                      control while making the ledger unusable.
--
-- Cleanup is by deliberate exception, not DELETE: journal_entry/journal_line
-- are append-only (trg_journal_entry_append_only) and refuse DELETE by design.
-- Raising inside a PL/pgSQL block rolls that block's implicit subtransaction
-- back, discarding the probe rows while leaving the migration's own DDL
-- intact. PL/pgSQL variables are ordinary memory and are NOT rolled back with
-- the subtransaction, so the assertions recorded in v_untagged_refused /
-- v_tagged_accepted survive to be evaluated afterwards.
-- ----------------------------------------------------------------------------
DO $verify$
DECLARE
  v_schema            text;
  v_ar                uuid;
  v_tenant            uuid;
  v_date              date;
  v_party             uuid;
  v_entry             uuid;
  v_untagged_refused  boolean := false;
  v_tagged_accepted   boolean := false;
  v_reason            text;
BEGIN
  SELECT nspname INTO v_schema FROM pg_namespace
   WHERE nspname LIKE 'tenant_%'
     AND EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n2 ON n2.oid = c.relnamespace
                  WHERE n2.nspname = pg_namespace.nspname AND c.relname = 'journal_line')
   ORDER BY nspname LIMIT 1;

  IF v_schema IS NULL THEN
    RAISE NOTICE '0005: no tenant schema to verify against';
    RETURN;
  END IF;

  -- The AR control account is the canonical non-bearer control account.
  EXECUTE format(
    'SELECT id, tenant_id FROM %I.account WHERE code = ''1100'' AND is_control', v_schema)
    INTO v_ar, v_tenant;

  IF v_ar IS NULL THEN
    RAISE NOTICE '0005: verification skipped (no control account 1100 on %)', v_schema;
    RETURN;
  END IF;

  -- Postings are refused outside an open fiscal period, so anchor the probe
  -- inside one rather than on now()::date, which may fall in a closed or
  -- not-yet-created period.
  EXECUTE format(
    'SELECT min(start_date) FROM %I.fiscal_period WHERE status = ''open''', v_schema)
    INTO v_date;

  IF v_date IS NULL THEN
    RAISE NOTICE '0005: verification skipped (no open fiscal period on %)', v_schema;
    RETURN;
  END IF;

  -- The migration runner does not SET app.tenant_id, so kernel.current_tenant()
  -- is NULL here. Passing tenant_id explicitly on our own INSERTs is not enough:
  -- the audit triggers (kernel.audit_row) resolve the tenant from the GUC
  -- independently, and audit_log.tenant_id is NOT NULL -- so an explicit-only
  -- approach dies inside a trigger we do not control. Establish real tenant
  -- context for the duration of the probe instead, exactly as the application
  -- does. set_config(..., true) makes it LOCAL to this transaction, so it
  -- cannot leak into later migrations in the same run.
  PERFORM set_config('app.tenant_id', v_tenant::text, true);

  BEGIN
    EXECUTE format(
      'INSERT INTO %I.party (tenant_id, party_type, display_name)
       VALUES ($1, ''organization'', ''_m0005 verification probe'') RETURNING id', v_schema)
      INTO v_party USING v_tenant;

    EXECUTE format(
      'INSERT INTO %I.journal_entry (tenant_id, entry_date, memo, source)
       VALUES ($1, $2, ''_m0005 verification probe'', ''migration'') RETURNING id', v_schema)
      INTO v_entry USING v_tenant, v_date;

    -- ---- negative control: untagged line on a control account -------------
    BEGIN
      EXECUTE format(
        'INSERT INTO %I.journal_line (tenant_id, journal_entry_id, line_no, account_id,
                                      debit, credit, currency, fx_rate, base_debit, base_credit)
         VALUES ($1, $2, 1, $3, 1.00, 0, ''USD'', 1, 1.00, 0)', v_schema)
        USING v_tenant, v_entry, v_ar;
    EXCEPTION WHEN check_violation THEN
      v_untagged_refused := true;
    END;

    -- ---- positive control: the SAME line, correctly tagged -----------------
    BEGIN
      EXECUTE format(
        'INSERT INTO %I.journal_line (tenant_id, journal_entry_id, line_no, account_id,
                                      debit, credit, currency, fx_rate, base_debit, base_credit,
                                      party_id, subledger_type_code)
         VALUES ($1, $2, 2, $3, 1.00, 0, ''USD'', 1, 1.00, 0, $4, ''ar'')', v_schema)
        USING v_tenant, v_entry, v_ar, v_party;
      v_tagged_accepted := true;
    EXCEPTION WHEN others THEN
      v_reason := SQLERRM;
    END;

    -- Unwind the probe. journal_entry/journal_line are append-only, so the
    -- only way to remove these rows is to roll the subtransaction back.
    RAISE EXCEPTION '_m0005_unwind';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> '_m0005_unwind' THEN RAISE; END IF;
  END;

  -- Drop the borrowed tenant context so nothing downstream inherits it.
  PERFORM set_config('app.tenant_id', '', true);

  IF NOT v_untagged_refused THEN
    RAISE EXCEPTION
      '0005 VERIFY FAILED on %: an UNTAGGED line was accepted on control account 1100. '
      'The guard is not biting and money can still be orphaned.', v_schema;
  END IF;

  IF NOT v_tagged_accepted THEN
    RAISE EXCEPTION
      '0005 VERIFY FAILED on %: a correctly TAGGED line was REJECTED on control account 1100 (%). '
      'The guard is over-broad and would block legitimate posting.', v_schema, v_reason;
  END IF;

  RAISE NOTICE
    '0005: verified on % -- untagged control-account postings refused, tagged postings accepted',
    v_schema;
END $verify$;
