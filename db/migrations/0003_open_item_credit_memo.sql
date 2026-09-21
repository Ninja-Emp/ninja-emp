-- ============================================================================
-- 0003_open_item_credit_memo.sql
--
-- MODELLING GAP. open_item could only ever represent a DEBT:
--
--     original_amount CHECK (original_amount >= 0)
--     open_amount     CHECK (open_amount     >= 0)
--
-- That is correct for invoices and wrong for everything that produces a
-- credit balance. CAM reconciliation (83_lease_trueup.sql) genuinely does:
-- the landlord bills monthly ESTIMATES and trues up to actual at year end,
-- and when the estimates were too high the landlord OWES the tenant money.
-- post_cam_reconciliation() correctly computed the credit, posted a balanced
-- journal entry for it, and then died on:
--
--     new row for relation "open_item" violates check constraint
--     "open_item_open_amount_check"
--
-- so the credit had no open-item detail and the tenant's statement would
-- never show it.
--
-- THE FIX, AND WHY NOT NEGATIVE AMOUNTS
-- The tempting fix is to drop the >= 0 constraints and store -400.00. That is
-- worse than the bug:
--   * it removes the constraints that catch genuine sign errors everywhere
--     else, to accommodate one legitimate case;
--   * "open_amount" stops meaning "how much of this document is outstanding";
--   * FIFO allocation becomes ambiguous -- LEAST(remaining, -400) is nonsense;
--   * aging buckets silently mix directions.
--
-- Instead an open item now declares its DIRECTION. Amounts stay non-negative
-- on both kinds. A credit memo for 400.00 is an open credit of 400.00, not an
-- invoice for -400.00. Balances are taken through open_item_signed().
--
-- Idempotent and safe to re-run.
-- ============================================================================

ALTER TABLE open_item
  ADD COLUMN IF NOT EXISTS item_kind text NOT NULL DEFAULT 'invoice';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'open_item_item_kind_check'
       AND conrelid = 'open_item'::regclass
  ) THEN
    ALTER TABLE open_item
      ADD CONSTRAINT open_item_item_kind_check
      CHECK (item_kind IN ('invoice','credit_memo'));
  END IF;
END $$;

COMMENT ON COLUMN open_item.item_kind IS
  'invoice = the party owes this; credit_memo = the direction is reversed. Amounts stay non-negative on both.';

-- ---------------------------------------------------------------------------
-- Verification, in-transaction. Prove the column exists, the constraint is
-- enforced, and every pre-existing row was classified as an invoice (which is
-- correct: before this migration a credit could not be stored at all).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing int;
  v_rejected boolean := false;
BEGIN
  SELECT count(*) INTO v_missing
    FROM open_item WHERE item_kind IS NULL;
  IF v_missing > 0 THEN
    RAISE EXCEPTION '0003: % open_item rows have a NULL item_kind', v_missing;
  END IF;

  -- tenant_id is supplied EXPLICITLY from an existing row rather than left to
  -- its kernel.current_tenant() default. The migration runner does not set
  -- app.tenant_id, so the default resolves to NULL and the insert dies on the
  -- NOT NULL constraint BEFORE it ever reaches the CHECK this probe exists to
  -- test -- a verification that fails for the wrong reason proves nothing.
  BEGIN
    INSERT INTO open_item (
      tenant_id, subledger_type_code, party_id, source, document_no, item_kind,
      original_amount, open_amount, currency, issue_date)
    SELECT tenant_id, 'ar', id, 'migration-probe', 'PROBE', 'nonsense',
           1.00, 1.00, 'USD', current_date
      FROM party LIMIT 1;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;

  -- No party rows at all: nothing was inserted, so the probe is inconclusive
  -- rather than failed. Say so instead of reporting a constraint breach.
  IF NOT v_rejected AND NOT EXISTS (SELECT 1 FROM party) THEN
    RAISE NOTICE '0003: verification skipped (no party rows to probe with)';
    RETURN;
  END IF;

  IF NOT v_rejected THEN
    RAISE EXCEPTION '0003: item_kind CHECK constraint is not being enforced';
  END IF;

  RAISE NOTICE '0003: open_item.item_kind present and enforced.';
END $$;
