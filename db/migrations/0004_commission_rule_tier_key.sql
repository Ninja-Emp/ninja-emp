-- ============================================================================
-- 0004_commission_rule_tier_key.sql
--
-- Widens the commission_rule no-overlap exclusion key so a TIERED commission
-- schedule can actually be stored.
--
-- THE BUG
-- The original constraint keyed on (agreement_id, daterange) only. A tiered
-- schedule is, by definition, several rows effective at the same time -- one
-- per band. Under the old key the second band collided with the first, so
-- tiered commissions were impossible to insert and every tiered code path
-- (tiered_commission, compute_commission_trueup, post_commission_trueup,
-- v_commission_trueup_pending) was unreachable dead code.
--
-- Nothing failed loudly. The feature simply did not exist.
--
-- THE FIX
-- Key on the band identity as well: (agreement_id, rule_type, breakpoint,
-- daterange). Flat rules carry a NULL breakpoint, folded to -1 so that two
-- flat rates overlapping in time STILL collide -- which is the genuine error
-- this constraint was written to catch.
--
-- Safe on live data: the new key is strictly weaker than the old one, so any
-- row set that satisfied the old constraint satisfies the new one. No data
-- can be rejected by applying this.
--
-- Idempotent and re-runnable.
-- ============================================================================
\set ON_ERROR_STOP on

DO $mig$
DECLARE
  v_schema text;
  v_def    text;
BEGIN
  FOR v_schema IN
    SELECT nspname FROM pg_namespace
     WHERE nspname LIKE 'tenant_%'
       AND nspname NOT IN ('tenant_template_reserved')
     ORDER BY nspname
  LOOP
    -- Skip schemas that predate the table entirely.
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = v_schema AND c.relname = 'commission_rule'
    ) THEN
      CONTINUE;
    END IF;

    SELECT pg_get_constraintdef(con.oid) INTO v_def
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = v_schema
       AND c.relname = 'commission_rule'
       AND con.conname = 'ex_commission_rule_no_overlap';

    -- Already widened (definition mentions rule_type): nothing to do.
    IF v_def IS NOT NULL AND v_def LIKE '%rule_type%' THEN
      RAISE NOTICE '0004: % already widened, skipping', v_schema;
      CONTINUE;
    END IF;

    IF v_def IS NOT NULL THEN
      EXECUTE format(
        'ALTER TABLE %I.commission_rule DROP CONSTRAINT ex_commission_rule_no_overlap',
        v_schema);
    END IF;

    EXECUTE format($sql$
      ALTER TABLE %I.commission_rule
        ADD CONSTRAINT ex_commission_rule_no_overlap
        EXCLUDE USING gist (
          agreement_id WITH =,
          rule_type    WITH =,
          (COALESCE(breakpoint_amount::numeric, -1)) WITH =,
          daterange(effective_from, effective_thru, '[]') WITH &&
        )
    $sql$, v_schema);

    RAISE NOTICE '0004: widened commission_rule exclusion key on %', v_schema;
  END LOOP;
END $mig$;

-- ----------------------------------------------------------------------------
-- Verify, in-transaction, that a tiered schedule is now actually storable and
-- that the constraint still catches the error it exists for. A migration that
-- claims success without proving the behaviour changed is just a log line.
-- ----------------------------------------------------------------------------
DO $verify$
DECLARE
  v_schema text;
  v_party  uuid;
  v_ag     uuid;
  v_ok     boolean;
BEGIN
  SELECT nspname INTO v_schema FROM pg_namespace
   WHERE nspname LIKE 'tenant_%'
     AND EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n2 ON n2.oid=c.relnamespace
                  WHERE n2.nspname = pg_namespace.nspname AND c.relname='commission_rule')
   ORDER BY nspname LIMIT 1;

  IF v_schema IS NULL THEN
    RAISE NOTICE '0004: no tenant schema to verify against';
    RETURN;
  END IF;

  EXECUTE format('SET LOCAL search_path = %I, kernel', v_schema);

  -- Probe against an EXISTING party rather than inserting one. The migration
  -- runner does not set app.tenant_id, so kernel.current_tenant() resolves to
  -- NULL and any insert dies on tenant_id NOT NULL before reaching the
  -- constraint under test. Re-using a real row also leaves nothing behind if
  -- this block is interrupted.
  EXECUTE format('SELECT id FROM %I.party LIMIT 1', v_schema) INTO v_party;
  IF v_party IS NULL THEN
    RAISE NOTICE '0004: verification skipped on % (no party rows to probe with)', v_schema;
    RETURN;
  END IF;

  BEGIN
    EXECUTE format(
      'INSERT INTO %I.consignor_agreement (tenant_id, consignor_party_id,
                                           default_commission_rate, start_date)
         SELECT tenant_id, $1, 0.40, DATE ''2000-01-01''
           FROM %I.party WHERE id = $1 RETURNING id', v_schema, v_schema)
      INTO v_ag USING v_party;

    -- Three concurrent bands. This is what used to be impossible.
    -- tenant_id is carried across from the agreement for the same reason as
    -- above: current_tenant() is NULL under the migration runner.
    EXECUTE format(
      'INSERT INTO %I.commission_rule (tenant_id, agreement_id, rule_type, rate, effective_from)
         SELECT tenant_id, id, ''flat'', 0.40, DATE ''2000-01-01''
           FROM %I.consignor_agreement WHERE id = $1', v_schema, v_schema) USING v_ag;
    EXECUTE format(
      'INSERT INTO %I.commission_rule (tenant_id, agreement_id, rule_type, rate, breakpoint_amount, effective_from)
         SELECT tenant_id, id, ''tiered'', 0.30, 5000.00, DATE ''2000-01-01''
           FROM %I.consignor_agreement WHERE id = $1', v_schema, v_schema) USING v_ag;
    EXECUTE format(
      'INSERT INTO %I.commission_rule (tenant_id, agreement_id, rule_type, rate, breakpoint_amount, effective_from)
         SELECT tenant_id, id, ''tiered'', 0.25, 20000.00, DATE ''2000-01-01''
           FROM %I.consignor_agreement WHERE id = $1', v_schema, v_schema) USING v_ag;

    -- And the constraint must STILL reject a duplicate band.
    v_ok := false;
    BEGIN
      EXECUTE format(
        'INSERT INTO %I.commission_rule (tenant_id, agreement_id, rule_type, rate, breakpoint_amount, effective_from)
           SELECT tenant_id, id, ''tiered'', 0.20, 5000.00, DATE ''2000-06-01''
             FROM %I.consignor_agreement WHERE id = $1', v_schema, v_schema) USING v_ag;
    EXCEPTION WHEN exclusion_violation THEN
      v_ok := true;
    END;

    IF NOT v_ok THEN
      RAISE EXCEPTION
        '0004 VERIFY FAILED: duplicate tiered band at breakpoint 5000 was accepted on %', v_schema;
    END IF;

    RAISE NOTICE '0004: verified on % -- tiered bands storable, duplicates still rejected', v_schema;
  EXCEPTION
    WHEN undefined_table OR undefined_column THEN
      RAISE NOTICE '0004: verification skipped on % (schema incomplete)', v_schema;
      RETURN;
  END;

  -- Clean up the probe rows. This runs inside the migration transaction.
  -- The party is NOT deleted: it was pre-existing real data, not a probe row.
  EXECUTE format('DELETE FROM %I.commission_rule WHERE agreement_id = $1', v_schema) USING v_ag;
  EXECUTE format('DELETE FROM %I.consignor_agreement WHERE id = $1', v_schema) USING v_ag;
END $verify$;
