-- ============================================================================
-- 79_vendor_draw.sql — Vendor payable draw as a POS tender.
--
-- Lets a consignor/vendor spend against the balance the store owes them. The
-- tender mechanism already exists (tender_type.settlement_kind='liability'), so
-- this file adds the tender row, the overdraw guard, and the instrument-side
-- bookkeeping.
--
-- Accounting: drawing against a payable DEBITS the vendor payable control —
-- exactly like paying the vendor, except settled in merchandise instead of cash.
-- No revenue effect beyond the normal sale; the payable simply shrinks.
-- ============================================================================

INSERT INTO tender_type (code, name, settlement_kind, debit_role_code, subledger_type_code, is_active)
VALUES ('vendor_draw','Vendor Payable Draw','liability','vendor_payable_control','vendor_payable', true)
ON CONFLICT (code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- vendor_draw_available — how much can this vendor actually spend?
--
-- Reads the live ledger (ADR-0028), so it is always current: a sale that just
-- accrued is immediately spendable.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vendor_draw_available(p_party_id uuid)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(jl.base_credit - jl.base_debit), 0)
    FROM journal_line jl
   WHERE jl.party_id = p_party_id
     AND jl.subledger_type_code IN ('vendor_payable','consignor_payable');
$$;
COMMENT ON FUNCTION vendor_draw_available IS 'Realtime spendable vendor/consignor balance straight from the ledger (ADR-0028).';

-- ----------------------------------------------------------------------------
-- assert_vendor_draw_covered — refuse a draw that exceeds the balance owed.
--
-- A deferred constraint trigger: it fires at COMMIT, so the sale's own accrual
-- (a vendor selling their own goods) is already in the ledger and counts toward
-- what they can spend. An immediate trigger would reject legitimate draws.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assert_vendor_draw_covered() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_party     uuid;
  v_available numeric;
  v_drawn     numeric;
BEGIN
  IF NEW.tender_type_code <> 'vendor_draw' THEN RETURN NEW; END IF;

  v_party := NEW.party_id;
  IF v_party IS NULL THEN
    RAISE EXCEPTION 'A vendor_draw tender must identify the vendor (party_id)' USING ERRCODE='23514';
  END IF;

  -- What the ledger says we owe them right now. Because this trigger is
  -- DEFERRED, any payable accrued by this same sale is already included.
  v_available := vendor_draw_available(v_party);

  -- Total drawn by this vendor in the current transaction, including rows the
  -- ledger has not yet reflected. Checking only the balance would let a vendor
  -- with 0.00 owed still tender a draw -- the balance must COVER the draw.
  SELECT COALESCE(sum(pt.amount), 0) INTO v_drawn
    FROM payment_tender pt
   WHERE pt.tender_type_code = 'vendor_draw'
     AND pt.party_id = v_party
     AND pt.settled_at IS NULL
     AND EXISTS (SELECT 1 FROM payment p
                  WHERE p.id = pt.payment_id AND p.journal_entry_id IS NULL);

  IF v_available < v_drawn THEN
    RAISE EXCEPTION
      'Vendor % cannot draw %: only % available',
      v_party, v_drawn, v_available USING ERRCODE='23514';
  END IF;

  RETURN NEW;
END; $$;

CREATE CONSTRAINT TRIGGER trg_vendor_draw_covered
  AFTER INSERT ON payment_tender
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_vendor_draw_covered();
COMMENT ON FUNCTION assert_vendor_draw_covered IS
  'Deferred guard: a vendor cannot draw their payable negative. Runs at COMMIT so same-sale accruals count.';
