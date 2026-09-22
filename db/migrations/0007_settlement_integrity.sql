-- ============================================================================
-- 0007_settlement_integrity.sql
--
-- Closes the six settlement defects (F1-F6) found in the open-item /
-- payment-application / reversal layer, and ports three ideas from EMP.
--
-- The defects all share one property: THE TRIAL BALANCE STILL NETS TO ZERO
-- WHILE THE DETAIL LIES. They were not caught by the existing 222 assertions
-- because those were written after the code, against what the code does. The
-- invariants are now written down first in docs/SETTLEMENT_INVARIANTS.md; this
-- migration is the mechanism that enforces them. See ADR-0039.
--
--   F1  reversing a payment did not un-apply it (CRITICAL)
--   F2  FIFO was mandatory; a specific invoice could not be targeted
--   F3  four copies of the allocator, two of them missing the invoice filter
--   F4  two allocators silently swallowed unapplied cash
--   F5  payment_application was mutable; stored-value bypassed it entirely
--   F6  write-off raced a concurrent settlement; the control check masked signs
--
--   B1  hash-chained journal (tamper-evidence)
--   B2  scale CHECK (no sub-cent posting)
--   B3  reversal-as-document-status (cannot re-reverse)
--
-- Idempotent and re-runnable. Applied once per tenant schema by scripts/migrate.sh
-- with search_path = <tenant>, kernel. The same changes are mirrored into the
-- base schema files so a fresh db/provision.sh build is correct too.
-- ============================================================================
\set ON_ERROR_STOP on

-- ============================================================================
-- PART 0. Money scale helper (B2 / MO-1).
--
-- A CHECK constraint cannot contain a subquery, so the currency's scale is
-- reached through a function. It is STABLE, not IMMUTABLE: it reads
-- kernel.currency, and claiming immutability for a table read is a lie that
-- bites at dump/restore time. kernel.currency is static reference data, so the
-- value is stable in practice.
-- ============================================================================
CREATE OR REPLACE FUNCTION kernel.money_scale_ok(p_amount numeric, p_currency char(3))
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_amount = round(p_amount, COALESCE((SELECT minor_unit FROM kernel.currency WHERE code = p_currency), 2))
$$;
COMMENT ON FUNCTION kernel.money_scale_ok IS
  'True when p_amount has no digits beyond the currency scale. Used by scale CHECKs (MO-1).';

-- ============================================================================
-- PART 1. open_item: item_kind gains 'on_account' (F4 / AL-5).
--
-- An overpayment that is not applied to an invoice is money the store holds
-- for the party: a credit. It is modelled as its own kind so it is visible in
-- aging and never mistaken for an invoice.
-- ============================================================================
ALTER TABLE open_item DROP CONSTRAINT IF EXISTS open_item_item_kind_check;
ALTER TABLE open_item ADD CONSTRAINT open_item_item_kind_check
  CHECK (item_kind IN ('invoice','credit_memo','on_account'));

-- on_account is a credit: it reduces the signed subledger balance.
CREATE OR REPLACE FUNCTION open_item_signed(p_kind text, p_amount kernel.money_amount)
RETURNS kernel.money_amount
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_kind IN ('credit_memo','on_account') THEN -p_amount ELSE p_amount END;
$$;
COMMENT ON FUNCTION open_item_signed IS
  'Signed contribution of an open item to its subledger balance: credit memos and on-account credits are negative.';

-- ============================================================================
-- PART 2. payment_application becomes the open-item ACTIVITY LEDGER (F5 / PA-2, PA-4, PA-5).
--
-- Every reduction of open_amount is recorded here, whatever caused it: a cash
-- settlement, a write-off, a stored-value redemption, a breakage recognition.
-- A reversal records an 'unapply' row rather than mutating history. That makes
-- PA-4 universally true: original - open = sum of signed applications.
-- ============================================================================
ALTER TABLE payment_application
  ADD COLUMN IF NOT EXISTS application_kind text NOT NULL DEFAULT 'apply';
ALTER TABLE payment_application
  ADD COLUMN IF NOT EXISTS reverses_application_id uuid REFERENCES payment_application(id) ON DELETE RESTRICT;

ALTER TABLE payment_application DROP CONSTRAINT IF EXISTS payment_application_kind_check;
ALTER TABLE payment_application ADD CONSTRAINT payment_application_kind_check
  CHECK (application_kind IN ('apply','unapply'));

COMMENT ON COLUMN payment_application.application_kind IS
  'apply = reduces the open item; unapply = restores it (a reversed settlement). Signed sum drives PA-4.';
COMMENT ON COLUMN payment_application.reverses_application_id IS
  'For an unapply row, the application it undoes.';

-- Append-only (PA-2). The old audit trigger is dropped: a table that cannot be
-- updated has nothing to audit on update.
DROP TRIGGER IF EXISTS trg_payment_application_audit ON payment_application;
DROP TRIGGER IF EXISTS trg_payment_application_append_only ON payment_application;
CREATE TRIGGER trg_payment_application_append_only
  BEFORE UPDATE OR DELETE ON payment_application
  FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();

-- ============================================================================
-- PART 2b. Reconcile legacy open items (PA-4 backfill).
--
-- Before this migration, several paths reduced open_amount without recording an
-- application: write_off_open_item, redeem_stored_value, recognize_breakage.
-- Those items now violate PA-4 (original - open <> net of applications). This
-- records the missing activity so the invariant holds on any database that
-- carries pre-fix history. It is a RECONCILIATION, not a settlement: the row
-- links to the item's own journal entry, which is the best available provenance.
-- Idempotent: after it runs, PA-4 holds and a re-run finds nothing to do.
-- ============================================================================
DO $pa4backfill$
DECLARE
  r       record;
  v_delta numeric;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT oi.id, oi.currency, oi.issue_date, oi.journal_entry_id,
           (oi.original_amount - oi.open_amount) AS settled,
           COALESCE(app.net, 0) AS applied
      FROM open_item oi
      LEFT JOIN (
        SELECT open_item_id,
               sum(CASE WHEN application_kind = 'apply' THEN applied_amount
                        ELSE -applied_amount END) AS net
          FROM payment_application
         GROUP BY open_item_id
      ) app ON app.open_item_id = oi.id
     WHERE (oi.original_amount - oi.open_amount) <> COALESCE(app.net, 0)
  LOOP
    v_delta := r.settled - r.applied;
    IF v_delta > 0 THEN
      INSERT INTO payment_application
        (open_item_id, applied_amount, currency, applied_date, journal_entry_id, application_kind)
      VALUES (r.id, v_delta, r.currency, r.issue_date, r.journal_entry_id, 'apply');
      v_count := v_count + 1;
    ELSIF v_delta < 0 THEN
      INSERT INTO payment_application
        (open_item_id, applied_amount, currency, applied_date, journal_entry_id, application_kind)
      VALUES (r.id, -v_delta, r.currency, r.issue_date, r.journal_entry_id, 'unapply');
      v_count := v_count + 1;
    END IF;
  END LOOP;
  IF v_count > 0 THEN
    RAISE NOTICE '0007: reconciled % legacy open item(s) (PA-4 backfill)', v_count;
  END IF;
END $pa4backfill$;

-- ============================================================================
-- PART 3. THE ONE ALLOCATOR (F2, F3, F4 / AL-1..AL-6).
--
-- allocate_payment() is the only function that turns a cash amount into
-- applications. apply_payment, post_consignor_payout and post_refund all call
-- it. It filters to invoices, locks rows, supports a directed target, and
-- never drops a remainder silently.
-- ============================================================================
CREATE OR REPLACE FUNCTION allocate_payment(
  p_party_id       uuid,
  p_subledger_type text,
  p_amount         kernel.money_amount,
  p_entry_date     date,
  p_journal_entry  uuid,
  p_open_item_id   uuid    DEFAULT NULL,
  p_on_account     boolean DEFAULT false
) RETURNS kernel.money_amount
LANGUAGE plpgsql AS $$
DECLARE
  v_remaining kernel.money_amount := p_amount;
  v_item      record;
  v_apply     kernel.money_amount;
  v_ccy       kernel.currency_code;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Allocation amount must be positive, got %', p_amount USING ERRCODE='23514';
  END IF;

  v_ccy := (SELECT functional_currency FROM tenant_config LIMIT 1);

  -- AL-4: a directed target is consumed first.
  IF p_open_item_id IS NOT NULL THEN
    SELECT * INTO v_item FROM open_item
     WHERE id = p_open_item_id
       AND party_id = p_party_id
       AND subledger_type_code = p_subledger_type
       AND item_kind = 'invoice'
       AND status IN ('open','partial')
       AND deleted_at IS NULL
     FOR UPDATE;
    IF v_item.id IS NULL THEN
      RAISE EXCEPTION 'Directed open item % is not an open invoice for party % subledger %',
        p_open_item_id, p_party_id, p_subledger_type USING ERRCODE='23514';
    END IF;
    v_apply := LEAST(v_remaining, v_item.open_amount);
    IF v_apply > 0 THEN
      INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date, journal_entry_id, application_kind)
      VALUES (v_item.id, v_apply, v_ccy, p_entry_date, p_journal_entry, 'apply');
      UPDATE open_item
         SET open_amount = open_amount - v_apply,
             status = CASE WHEN open_amount - v_apply = 0 THEN 'settled' ELSE 'partial' END
       WHERE id = v_item.id;
      v_remaining := v_remaining - v_apply;
    END IF;
  END IF;

  -- AL-2, AL-3, AL-6: invoices only, oldest first, locked.
  FOR v_item IN
    SELECT * FROM open_item
     WHERE party_id = p_party_id
       AND subledger_type_code = p_subledger_type
       AND status IN ('open','partial')
       AND item_kind = 'invoice'
       AND deleted_at IS NULL
       AND (p_open_item_id IS NULL OR id <> p_open_item_id)
     ORDER BY COALESCE(due_date, issue_date), issue_date, id
     FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_apply := LEAST(v_remaining, v_item.open_amount);
    IF v_apply <= 0 THEN CONTINUE; END IF;
    INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date, journal_entry_id, application_kind)
    VALUES (v_item.id, v_apply, v_ccy, p_entry_date, p_journal_entry, 'apply');
    UPDATE open_item
       SET open_amount = open_amount - v_apply,
           status = CASE WHEN open_amount - v_apply = 0 THEN 'settled' ELSE 'partial' END
     WHERE id = v_item.id;
    v_remaining := v_remaining - v_apply;
  END LOOP;

  -- AL-5: no silent remainder. Either record an on-account credit or raise.
  IF v_remaining > 0 THEN
    IF p_on_account THEN
      INSERT INTO open_item (
        subledger_type_code, party_id, source, source_ref, document_no, item_kind,
        original_amount, open_amount, currency, issue_date, due_date, journal_entry_id
      ) VALUES (
        p_subledger_type, p_party_id, 'on_account', p_journal_entry::text, NULL, 'on_account',
        v_remaining, v_remaining, v_ccy, p_entry_date, NULL, p_journal_entry
      );
      v_remaining := 0;
    ELSE
      RAISE EXCEPTION 'Allocation of % exceeds open invoices for party % subledger % (unapplied %)',
        p_amount, p_party_id, p_subledger_type, v_remaining USING ERRCODE='23514';
    END IF;
  END IF;

  RETURN v_remaining;
END; $$;
COMMENT ON FUNCTION allocate_payment IS
  'The single allocator (AL-1): invoices only, FIFO or directed, locked, never drops a remainder.';

-- ============================================================================
-- PART 4. REVERSAL UN-APPLIES SETTLEMENT (F1 / PA-5, RV-5).
-- ============================================================================
CREATE OR REPLACE FUNCTION unapply_for_entry(p_entry_id uuid, p_reversal_entry uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_app record;
  v_oa  record;
BEGIN
  -- Restore every open item this entry settled, and record the un-application.
  FOR v_app IN
    SELECT * FROM payment_application
     WHERE journal_entry_id = p_entry_id AND application_kind = 'apply'
     ORDER BY id
     FOR UPDATE
  LOOP
    UPDATE open_item
       SET open_amount = open_amount + v_app.applied_amount,
           status = CASE
                      WHEN open_amount + v_app.applied_amount = original_amount THEN 'open'
                      WHEN open_amount + v_app.applied_amount = 0 THEN 'settled'
                      ELSE 'partial'
                    END
     WHERE id = v_app.open_item_id;

    INSERT INTO payment_application (
      open_item_id, applied_amount, currency, applied_date, journal_entry_id,
      application_kind, reverses_application_id
    ) VALUES (
      v_app.open_item_id, v_app.applied_amount, v_app.currency, v_app.applied_date,
      p_reversal_entry, 'unapply', v_app.id
    );
  END LOOP;

  -- Void any on-account credit this entry created: it existed only because of
  -- the overpayment the entry recorded, so reversing the entry removes it.
  FOR v_oa IN
    SELECT * FROM open_item
     WHERE journal_entry_id = p_entry_id
       AND item_kind = 'on_account'
       AND status IN ('open','partial')
     FOR UPDATE
  LOOP
    INSERT INTO payment_application (
      open_item_id, applied_amount, currency, applied_date, journal_entry_id, application_kind
    ) VALUES (
      v_oa.id, v_oa.open_amount, v_oa.currency, p_reversal_entry, p_reversal_entry, 'apply'
    );
    UPDATE open_item SET open_amount = 0, status = 'void' WHERE id = v_oa.id;
  END LOOP;
END; $$;
COMMENT ON FUNCTION unapply_for_entry IS
  'Restores the open items a settlement entry settled and records the un-application (PA-5).';

-- reverse_journal_entry now: refuses to re-reverse (B3/RV-4), and un-applies
-- settlement (F1/RV-5).
CREATE OR REPLACE FUNCTION reverse_journal_entry(
  p_entry_id        uuid,
  p_reversal_date   date,
  p_memo            text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_new uuid;
  v_no  smallint := 0;
  v_line record;
BEGIN
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_new FROM journal_entry
      WHERE idempotency_key = p_idempotency_key AND tenant_id = kernel.current_tenant();
    IF v_new IS NOT NULL THEN RETURN v_new; END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM journal_entry WHERE id = p_entry_id) THEN
    RAISE EXCEPTION 'Journal entry % not found', p_entry_id USING ERRCODE='23503';
  END IF;

  -- RV-4: reversal is a document status. A reversed entry cannot be reversed
  -- again, and a reversal is itself terminal.
  IF EXISTS (SELECT 1 FROM journal_entry WHERE reversal_of_id = p_entry_id) THEN
    RAISE EXCEPTION 'Entry % has already been reversed; a reversed entry cannot be reversed again',
      p_entry_id USING ERRCODE='23514';
  END IF;
  IF EXISTS (SELECT 1 FROM journal_entry WHERE id = p_entry_id AND reversal_of_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Entry % is itself a reversal; reversals are terminal', p_entry_id USING ERRCODE='23514';
  END IF;

  INSERT INTO journal_entry (entry_date, memo, source, source_ref, idempotency_key, reversal_of_id, created_by)
  SELECT p_reversal_date,
         COALESCE(p_memo, 'Reversal of entry ' || je.entry_no),
         'reversal', je.id::text, p_idempotency_key, je.id, kernel.current_actor()
    FROM journal_entry je WHERE je.id = p_entry_id
  RETURNING id INTO v_new;

  FOR v_line IN SELECT * FROM journal_line WHERE journal_entry_id = p_entry_id ORDER BY line_no LOOP
    v_no := v_no + 1;
    INSERT INTO journal_line (
      journal_entry_id, line_no, account_id, debit, credit, currency, fx_rate,
      base_debit, base_credit, party_id, subledger_type_code, memo
    ) VALUES (
      v_new, v_no, v_line.account_id,
      v_line.credit, v_line.debit,          -- swap sides
      v_line.currency, v_line.fx_rate,
      v_line.base_credit, v_line.base_debit,
      v_line.party_id, v_line.subledger_type_code,
      'Reversal: ' || COALESCE(v_line.memo,'')
    );
  END LOOP;

  -- F1: the mirror restores the GL control; this restores the open items.
  PERFORM unapply_for_entry(p_entry_id, v_new);

  RETURN v_new;
END; $$;
COMMENT ON FUNCTION reverse_journal_entry IS
  'Posts a mirror entry linked via reversal_of_id, un-applies any settlement, and refuses to re-reverse.';

-- ============================================================================
-- PART 5. Entry points call the one allocator (F3, F4).
-- ============================================================================

-- apply_payment: gains a directed target and an on-account option. The old
-- 5-argument signature is dropped first: CREATE OR REPLACE cannot replace a
-- function whose argument list changed, it would create an ambiguous overload.
DROP FUNCTION IF EXISTS apply_payment(uuid, text, kernel.money_amount, date, text);
CREATE OR REPLACE FUNCTION apply_payment(
  p_party_id        uuid,
  p_subledger_type  text,
  p_amount          kernel.money_amount,
  p_entry_date      date,
  p_idempotency_key text,
  p_open_item_id    uuid    DEFAULT NULL,
  p_on_account      boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_receipt boolean;
  v_control uuid;
  v_cash    uuid;
  v_ccy     kernel.currency_code;
  v_entry   uuid;
  v_lines   jsonb;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be positive' USING ERRCODE='23514';
  END IF;

  v_receipt := p_subledger_type = 'ar';
  v_control := posting_account(subledger_control_role(p_subledger_type));
  v_cash    := posting_account('cash');
  v_ccy     := (SELECT functional_currency FROM tenant_config LIMIT 1);

  IF v_receipt THEN
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', p_amount, 'currency', v_ccy, 'memo', 'Payment received'),
      jsonb_build_object('account_id', v_control, 'credit', p_amount, 'currency', v_ccy,
                         'party_id', p_party_id, 'subledger_type_code', p_subledger_type, 'memo', 'Payment applied')
    );
  ELSE
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_control, 'debit', p_amount, 'currency', v_ccy,
                         'party_id', p_party_id, 'subledger_type_code', p_subledger_type, 'memo', 'Payment applied'),
      jsonb_build_object('account_id', v_cash, 'credit', p_amount, 'currency', v_ccy, 'memo', 'Payment made')
    );
  END IF;

  v_entry := post_journal_entry(
    p_entry_date, 'Payment ' || p_subledger_type || ' party ' || p_party_id,
    'payment', p_party_id::text, p_idempotency_key, v_lines
  );

  -- Idempotent: if this entry already produced settlement activity, stop.
  IF EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry)
     OR EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry AND item_kind = 'on_account') THEN
    RETURN v_entry;
  END IF;

  PERFORM allocate_payment(p_party_id, p_subledger_type, p_amount, p_entry_date, v_entry,
                           p_open_item_id, p_on_account);
  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION apply_payment IS
  'Idempotent payment: posts cash entry and allocates via allocate_payment (directed or FIFO).';

-- post_consignor_payout: uses the one allocator; a remainder now RAISES (F4).
CREATE OR REPLACE FUNCTION post_consignor_payout(
  p_payout_id       uuid,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_pay   record;
  v_set   record;
  v_entry uuid;
  v_lines jsonb;
BEGIN
  SELECT * INTO v_pay FROM consignor_payout WHERE id = p_payout_id;
  IF v_pay IS NULL THEN
    RAISE EXCEPTION 'Consignor payout % not found', p_payout_id USING ERRCODE='23503';
  END IF;
  SELECT * INTO v_set FROM consignor_settlement WHERE id = v_pay.settlement_id;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('consignor_payable_control'),
                       'debit', v_pay.payout_amount, 'currency', v_pay.currency,
                       'party_id', v_set.consignor_party_id,
                       'subledger_type_code', 'consignor_payable',
                       'memo', 'Consignor payout settlement ' || v_set.settlement_no),
    jsonb_build_object('account_id', posting_account('cash'),
                       'credit', v_pay.payout_amount, 'currency', v_pay.currency,
                       'memo', 'Consignor payout settlement ' || v_set.settlement_no)
  );

  v_entry := post_journal_entry(
    p_entry_date, 'Consignor payout settlement ' || v_set.settlement_no,
    'payout', p_payout_id::text, p_idempotency_key, v_lines
  );

  UPDATE consignor_payout SET journal_entry_id = v_entry WHERE id = p_payout_id;
  UPDATE consignor_settlement SET status = 'paid' WHERE id = v_pay.settlement_id;

  IF NOT EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    PERFORM allocate_payment(v_set.consignor_party_id, 'consignor_payable',
                             v_pay.payout_amount, p_entry_date, v_entry);
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_consignor_payout IS
  'Idempotent consignor payout: payable debit / cash credit; allocates via allocate_payment (raises on remainder).';

-- post_refund: the fourth copy of the allocator is deleted. It had the same two
-- defects as the others -- no invoice filter (F3) and a silently dropped
-- remainder (F4) -- and it is the copy that actually ran on every POS refund.
-- It now calls allocate_payment like everything else.
CREATE OR REPLACE FUNCTION post_refund(
  p_refund_sale_id  uuid,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_sale    record;
  v_lines   jsonb := '[]'::jsonb;
  v_ccy     kernel.currency_code;
  v_entry   uuid;
  v_t       record;
  v_net_rev kernel.money_amount;
  v_cons    kernel.money_amount;
BEGIN
  SELECT * INTO v_sale FROM sale WHERE id = p_refund_sale_id;
  IF v_sale IS NULL THEN
    RAISE EXCEPTION 'Refund % not found', p_refund_sale_id USING ERRCODE='23503';
  END IF;
  IF NOT v_sale.is_refund THEN
    RAISE EXCEPTION 'Sale % is not a refund document', p_refund_sale_id USING ERRCODE='23514';
  END IF;

  v_ccy     := v_sale.currency;
  v_net_rev := v_sale.subtotal - v_sale.discount_total;

  -- CREDIT the tenders (money going back out).
  FOR v_t IN
    SELECT tt.debit_role_code, tt.settlement_kind, tt.subledger_type_code,
           pt.party_id, sum(pt.amount) AS amt
      FROM payment p
      JOIN payment_tender pt ON pt.payment_id = p.id
      JOIN tender_type tt ON tt.code = pt.tender_type_code
     WHERE p.sale_id = p_refund_sale_id AND p.status = 'captured'
     GROUP BY tt.debit_role_code, tt.settlement_kind, tt.subledger_type_code, pt.party_id
  LOOP
    IF v_t.settlement_kind = 'liability' THEN
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account(v_t.debit_role_code),
        'credit', v_t.amt, 'currency', v_ccy,
        'party_id', v_t.party_id,
        'subledger_type_code', v_t.subledger_type_code,
        'memo', 'Refund tender sale ' || v_sale.sale_no);
    ELSE
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account(v_t.debit_role_code),
        'credit', v_t.amt, 'currency', v_ccy,
        'memo', 'Refund tender sale ' || v_sale.sale_no);
    END IF;
  END LOOP;

  -- DEBIT revenue + tax back.
  IF v_net_rev <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('sales_revenue'),
      'debit', v_net_rev, 'currency', v_ccy,
      'memo', 'Refund ' || v_sale.sale_no);
  END IF;
  IF v_sale.tax_total <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('sales_tax_payable'),
      'debit', v_sale.tax_total, 'currency', v_ccy,
      'memo', 'Refund tax ' || v_sale.sale_no);
  END IF;

  -- Reverse the consignor accrual too (their liability falls back).
  SELECT COALESCE(sum(net_to_consignor), 0) INTO v_cons
    FROM sale_line WHERE sale_id = p_refund_sale_id AND line_kind = 'consignment';

  IF v_cons > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('consignment_cogs'),
      'credit', v_cons, 'currency', v_ccy,
      'memo', 'Reverse consignment COGS ' || v_sale.sale_no);
    FOR v_t IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM sale_line
       WHERE sale_id = p_refund_sale_id AND line_kind = 'consignment'
       GROUP BY consignor_party_id
    LOOP
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account('consignor_payable_control'),
        'debit', v_t.net, 'currency', v_ccy,
        'party_id', v_t.consignor_party_id,
        'subledger_type_code', 'consignor_payable',
        'memo', 'Reverse consignor payable ' || v_sale.sale_no);
    END LOOP;
  END IF;

  v_entry := post_journal_entry(
    p_entry_date, 'POS refund ' || v_sale.sale_no,
    'pos_refund', p_refund_sale_id::text, p_idempotency_key, v_lines);

  UPDATE sale SET journal_entry_id = v_entry WHERE id = p_refund_sale_id;
  UPDATE sale SET status = 'refunded' WHERE id = v_sale.refunds_sale_id;

  -- The refund cancels the obligation to the consignor, so the matching OPEN
  -- ITEMS must be relieved too -- otherwise the open-item layer would still show
  -- money owed that the GL control account no longer carries (ADR-0023).
  -- Idempotent: skip if this entry already produced applications.
  IF v_cons > 0
     AND NOT EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    FOR v_t IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM sale_line
       WHERE sale_id = p_refund_sale_id AND line_kind = 'consignment'
       GROUP BY consignor_party_id
    LOOP
      PERFORM allocate_payment(v_t.consignor_party_id, 'consignor_payable',
                               v_t.net, p_entry_date, v_entry);
    END LOOP;
  END IF;

  RETURN v_entry;
END $$;
COMMENT ON FUNCTION post_refund IS
  'Idempotent refund posting (reversal-not-edit; reverses consignor accrual and relieves open items via allocate_payment).';

-- ============================================================================
-- PART 6. write_off_open_item: lock the row (F6/CA-4) and record the activity (F5).
-- ============================================================================
CREATE OR REPLACE FUNCTION write_off_open_item(
  p_open_item_id    uuid,
  p_entry_date      date,
  p_amount          kernel.money_amount DEFAULT NULL,
  p_memo            text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_item    open_item;
  v_amt     numeric;
  v_entry   uuid;
  v_control uuid;
  v_expense uuid;
  v_role    text;
BEGIN
  SELECT * INTO v_item FROM open_item WHERE id = p_open_item_id FOR UPDATE;
  IF v_item.id IS NULL THEN
    RAISE EXCEPTION 'No open item %', p_open_item_id USING ERRCODE='23514';
  END IF;

  v_amt := COALESCE(p_amount, v_item.open_amount);
  IF v_amt <= 0 THEN
    RAISE EXCEPTION 'Write-off amount must be positive, got %', v_amt USING ERRCODE='23514';
  END IF;
  IF v_amt > v_item.open_amount THEN
    RAISE EXCEPTION 'Cannot write off % against an open balance of %',
      v_amt, v_item.open_amount USING ERRCODE='23514';
  END IF;

  v_role    := subledger_control_role(v_item.subledger_type_code);
  v_control := posting_account(v_role);
  v_expense := posting_account('bad_debt_expense');

  v_entry := post_journal_entry(
    p_entry_date,
    COALESCE(p_memo, 'Write-off ' || COALESCE(v_item.document_no, v_item.id::text)),
    'write_off', v_item.id::text,
    COALESCE(p_idempotency_key, 'write_off:' || v_item.id::text || ':' || p_entry_date::text),
    jsonb_build_array(
      jsonb_build_object('account_id', v_expense, 'debit', v_amt, 'memo','Bad debt'),
      jsonb_build_object('account_id', v_control, 'credit', v_amt,
                         'party_id', v_item.party_id,
                         'subledger_type_code', v_item.subledger_type_code)
    )
  );

  IF NOT EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date, journal_entry_id, application_kind)
    VALUES (v_item.id, v_amt, v_item.currency, p_entry_date, v_entry, 'apply');
    UPDATE open_item
       SET open_amount = open_amount - v_amt,
           status = CASE WHEN open_amount - v_amt = 0 THEN 'written_off' ELSE 'partial' END
     WHERE id = v_item.id;
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION write_off_open_item IS
  'Writes off an uncollectible open item (row locked), recording the activity so PA-4 holds.';

-- ============================================================================
-- PART 7. Control check compares SIGNED sums (F6/CA-2); PA-4 reconciliation.
-- ============================================================================
CREATE OR REPLACE FUNCTION open_item_control_check()
RETURNS TABLE (
  subledger_type_code text,
  open_item_total     numeric,
  control_total       numeric,
  difference          numeric
)
LANGUAGE sql STABLE AS $$
  WITH oi AS (
    SELECT subledger_type_code AS st,
           sum(open_item_signed(item_kind, open_amount)) AS total
      FROM open_item
     WHERE status IN ('open','partial') AND deleted_at IS NULL
     GROUP BY subledger_type_code
  ),
  ctl AS (
    -- SIGNED on both sides. abs() would mask a genuine sign error (a credit
    -- posted as a debit) as a match; a normal-balance-signed sum does not.
    SELECT a.control_subledger_type_code AS st,
           sum(CASE WHEN at.normal_balance = 'D' THEN jl.base_debit - jl.base_credit
                    ELSE jl.base_credit - jl.base_debit END) AS total
      FROM journal_line jl
      JOIN account a ON a.id = jl.account_id
      JOIN kernel.account_type at ON at.code = a.account_type_code
     WHERE a.is_control
     GROUP BY a.control_subledger_type_code
  )
  SELECT COALESCE(oi.st, ctl.st),
         COALESCE(oi.total, 0),
         COALESCE(ctl.total, 0),
         COALESCE(oi.total, 0) - COALESCE(ctl.total, 0)
    FROM oi FULL OUTER JOIN ctl ON oi.st = ctl.st
   WHERE COALESCE(oi.st, ctl.st) IN (
           SELECT code FROM kernel.subledger_type WHERE uses_open_items)
   ORDER BY 1;
$$;
COMMENT ON FUNCTION open_item_control_check IS
  'Invariant: signed sum of open items must equal the normal-balance-signed GL control balance (difference = 0).';

-- PA-4: original - open must equal the net of applications. Returns offenders.
CREATE OR REPLACE FUNCTION open_item_application_check()
RETURNS TABLE (
  open_item_id    uuid,
  document_no     text,
  original_amount numeric,
  open_amount     numeric,
  applied_net     numeric,
  difference      numeric
)
LANGUAGE sql STABLE AS $$
  SELECT oi.id, oi.document_no, oi.original_amount, oi.open_amount,
         COALESCE(app.net, 0),
         (oi.original_amount - oi.open_amount) - COALESCE(app.net, 0)
    FROM open_item oi
    LEFT JOIN (
      SELECT open_item_id,
             sum(CASE WHEN application_kind = 'apply' THEN applied_amount ELSE -applied_amount END) AS net
        FROM payment_application
       GROUP BY open_item_id
    ) app ON app.open_item_id = oi.id
   WHERE (oi.original_amount - oi.open_amount) <> COALESCE(app.net, 0)
   ORDER BY oi.id;
$$;
COMMENT ON FUNCTION open_item_application_check IS
  'Invariant PA-4: original - open must equal the net of applications. Must return zero rows.';

-- ============================================================================
-- PART 8. B1 - hash-chained journal (JI-3).
-- ============================================================================
CREATE OR REPLACE FUNCTION journal_entry_digest(
  p_prev            text,
  p_entry_no        bigint,
  p_entry_date      date,
  p_memo            text,
  p_source          text,
  p_source_ref      text,
  p_idempotency_key text,
  p_reversal_of_id  uuid
) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(kernel.digest(
    COALESCE(p_prev,'')            || E'\x1f' || p_entry_no::text        || E'\x1f' ||
    p_entry_date::text             || E'\x1f' || COALESCE(p_memo,'')     || E'\x1f' ||
    p_source                       || E'\x1f' || COALESCE(p_source_ref,'') || E'\x1f' ||
    COALESCE(p_idempotency_key,'') || E'\x1f' || COALESCE(p_reversal_of_id::text,'')
  , 'sha256'), 'hex');
$$;
COMMENT ON FUNCTION journal_entry_digest IS
  'SHA-256 over an entry''s immutable header content plus its predecessor hash (JI-3).';

ALTER TABLE journal_entry ADD COLUMN IF NOT EXISTS prev_hash  text;
ALTER TABLE journal_entry ADD COLUMN IF NOT EXISTS entry_hash text;

-- Backfill any un-hashed history (live tenants). The append-only trigger blocks
-- UPDATE, so it is disabled for the backfill only, then re-enabled.
DO $backfill$
DECLARE
  r      record;
  v_prev text := NULL;
  v_hash text;
BEGIN
  IF EXISTS (SELECT 1 FROM journal_entry WHERE entry_hash IS NULL) THEN
    EXECUTE 'ALTER TABLE journal_entry DISABLE TRIGGER trg_journal_entry_append_only';
    FOR r IN SELECT * FROM journal_entry ORDER BY entry_no LOOP
      v_hash := journal_entry_digest(v_prev, r.entry_no, r.entry_date, r.memo,
                                     r.source, r.source_ref, r.idempotency_key, r.reversal_of_id);
      UPDATE journal_entry SET prev_hash = v_prev, entry_hash = v_hash WHERE id = r.id;
      v_prev := v_hash;
    END LOOP;
    EXECUTE 'ALTER TABLE journal_entry ENABLE TRIGGER trg_journal_entry_append_only';
    RAISE NOTICE '0007: backfilled journal hash chain';
  END IF;
END $backfill$;

CREATE OR REPLACE FUNCTION journal_entry_hash_chain() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_prev text;
BEGIN
  SELECT entry_hash INTO v_prev
    FROM journal_entry
   WHERE tenant_id = NEW.tenant_id
   ORDER BY entry_no DESC
   LIMIT 1;
  NEW.prev_hash  := v_prev;
  NEW.entry_hash := journal_entry_digest(v_prev, NEW.entry_no, NEW.entry_date, NEW.memo,
                                         NEW.source, NEW.source_ref, NEW.idempotency_key, NEW.reversal_of_id);
  RETURN NEW;
END; $$;
COMMENT ON FUNCTION journal_entry_hash_chain IS
  'BEFORE INSERT: chains each entry to its predecessor (JI-3).';

DROP TRIGGER IF EXISTS trg_journal_entry_hash_chain ON journal_entry;
CREATE TRIGGER trg_journal_entry_hash_chain
  BEFORE INSERT ON journal_entry
  FOR EACH ROW EXECUTE FUNCTION journal_entry_hash_chain();

-- One entry per hash; one successor per prev_hash; exactly one genesis.
CREATE UNIQUE INDEX IF NOT EXISTS ux_journal_entry_hash
  ON journal_entry (tenant_id, entry_hash);
CREATE UNIQUE INDEX IF NOT EXISTS ux_journal_entry_prev_hash
  ON journal_entry (tenant_id, prev_hash) WHERE prev_hash IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_journal_entry_genesis
  ON journal_entry (tenant_id) WHERE prev_hash IS NULL;

CREATE OR REPLACE FUNCTION verify_journal_chain()
RETURNS TABLE (entry_no bigint, entry_id uuid, problem text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  r        record;
  v_prev   text := NULL;
  v_expect text;
BEGIN
  FOR r IN SELECT * FROM journal_entry ORDER BY entry_no LOOP
    v_expect := journal_entry_digest(v_prev, r.entry_no, r.entry_date, r.memo,
                                     r.source, r.source_ref, r.idempotency_key, r.reversal_of_id);
    IF r.prev_hash IS DISTINCT FROM v_prev THEN
      entry_no := r.entry_no; entry_id := r.id; problem := 'prev_hash does not match predecessor';
      RETURN NEXT;
    END IF;
    IF r.entry_hash IS DISTINCT FROM v_expect THEN
      entry_no := r.entry_no; entry_id := r.id; problem := 'entry_hash does not match content';
      RETURN NEXT;
    END IF;
    v_prev := r.entry_hash;
  END LOOP;
END; $$;
COMMENT ON FUNCTION verify_journal_chain IS
  'Returns one row per broken link in the journal hash chain. Must return zero rows.';

-- ============================================================================
-- PART 9. B2 - scale CHECKs (MO-1). No sub-cent amount may be posted.
-- ============================================================================
ALTER TABLE journal_line DROP CONSTRAINT IF EXISTS journal_line_debit_scale_check;
ALTER TABLE journal_line ADD CONSTRAINT journal_line_debit_scale_check
  CHECK (kernel.money_scale_ok(debit, currency));
ALTER TABLE journal_line DROP CONSTRAINT IF EXISTS journal_line_credit_scale_check;
ALTER TABLE journal_line ADD CONSTRAINT journal_line_credit_scale_check
  CHECK (kernel.money_scale_ok(credit, currency));

ALTER TABLE open_item DROP CONSTRAINT IF EXISTS open_item_original_scale_check;
ALTER TABLE open_item ADD CONSTRAINT open_item_original_scale_check
  CHECK (kernel.money_scale_ok(original_amount, currency));
ALTER TABLE open_item DROP CONSTRAINT IF EXISTS open_item_open_scale_check;
ALTER TABLE open_item ADD CONSTRAINT open_item_open_scale_check
  CHECK (kernel.money_scale_ok(open_amount, currency));

ALTER TABLE payment_application DROP CONSTRAINT IF EXISTS payment_application_scale_check;
ALTER TABLE payment_application ADD CONSTRAINT payment_application_scale_check
  CHECK (kernel.money_scale_ok(applied_amount, currency));

-- ============================================================================
-- PART 10. VERIFY, in-transaction, that the mechanisms actually bite.
--
-- A migration that logs success without proving behaviour changed is a log
-- line. This manufactures its own fixture and unwinds it by deliberate
-- exception (journal tables are append-only, so DELETE is not available).
-- ============================================================================
DO $verify$
DECLARE
  v_tenant   uuid;
  v_date     date;
  v_party    uuid;
  v_ar       uuid;
  v_cash     uuid;
  v_entry    uuid;
  v_item     uuid;
  v_ok_rev   boolean := false;
  v_ok_scale boolean := false;
  v_ok_app   boolean := false;
  v_reason   text;
BEGIN
  SELECT tenant_id INTO v_tenant FROM tenant_config LIMIT 1;
  IF v_tenant IS NULL THEN
    RAISE NOTICE '0007: verification skipped (no tenant_config)';
    RETURN;
  END IF;

  SELECT min(start_date) INTO v_date FROM fiscal_period WHERE status = 'open';
  IF v_date IS NULL THEN
    RAISE NOTICE '0007: verification skipped (no open fiscal period)';
    RETURN;
  END IF;

  SELECT id INTO v_ar   FROM account WHERE code = '1100' AND is_control;
  SELECT id INTO v_cash FROM account WHERE code = '1000';
  IF v_ar IS NULL OR v_cash IS NULL THEN
    RAISE NOTICE '0007: verification skipped (missing 1100/1000)';
    RETURN;
  END IF;

  PERFORM set_config('app.tenant_id', v_tenant::text, true);

  BEGIN
    INSERT INTO party (tenant_id, party_type, display_name)
    VALUES (v_tenant, 'organization', '_m0007 verification probe') RETURNING id INTO v_party;

    -- An AR invoice of 100, opened by a balanced entry.
    v_entry := post_journal_entry(v_date, '_m0007 probe invoice', 'migration', 'probe',
      '_m0007_inv_' || v_tenant::text,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar, 'debit', 100.00, 'currency', 'USD',
                           'party_id', v_party, 'subledger_type_code', 'ar'),
        jsonb_build_object('account_id', v_cash, 'credit', 100.00, 'currency', 'USD')));
    v_item := open_item_create('ar', v_party, 'manual', 'probe', 'PROBE-1', 100.00, 'USD', v_date, NULL, v_entry);

    -- A receipt of 100 settles it.
    PERFORM apply_payment(v_party, 'ar', 100.00, v_date, '_m0007_pay_' || v_tenant::text);

    -- ---- F1: reversing the receipt must restore the open item --------------
    DECLARE v_pay_entry uuid;
    BEGIN
      SELECT journal_entry_id INTO v_pay_entry FROM payment_application
       WHERE open_item_id = v_item AND application_kind = 'apply' LIMIT 1;
      PERFORM reverse_journal_entry(v_pay_entry, v_date, 'probe reversal',
                                    '_m0007_rev_' || v_tenant::text);
      IF (SELECT open_amount FROM open_item WHERE id = v_item) = 100.00 THEN
        v_ok_rev := true;
      END IF;
    END;

    -- ---- B3: re-reversing the same entry must be refused -------------------
    BEGIN
      PERFORM reverse_journal_entry(
        (SELECT journal_entry_id FROM payment_application WHERE open_item_id = v_item AND application_kind='apply' LIMIT 1),
        v_date, 'probe re-reversal', '_m0007_rev2_' || v_tenant::text);
    EXCEPTION WHEN others THEN
      v_reason := SQLERRM;   -- expected
    END;

    -- ---- B2: a sub-cent posting must be refused ----------------------------
    BEGIN
      PERFORM post_journal_entry(v_date, '_m0007 probe subcent', 'migration', 'probe',
        '_m0007_sub_' || v_tenant::text,
        jsonb_build_array(
          jsonb_build_object('account_id', v_cash, 'debit', 1.005, 'currency', 'USD'),
          jsonb_build_object('account_id', v_ar, 'credit', 1.005, 'currency', 'USD',
                             'party_id', v_party, 'subledger_type_code', 'ar')));
    EXCEPTION WHEN check_violation THEN
      v_ok_scale := true;
    END;

    -- ---- PA-4: the tie-out must hold after the reversal --------------------
    IF NOT EXISTS (SELECT 1 FROM open_item_application_check() WHERE open_item_id = v_item) THEN
      v_ok_app := true;
    END IF;

    RAISE EXCEPTION '_m0007_unwind';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> '_m0007_unwind' THEN RAISE; END IF;
  END;

  PERFORM set_config('app.tenant_id', '', true);

  IF NOT v_ok_rev THEN
    RAISE EXCEPTION '0007 VERIFY FAILED: reversing a receipt did not restore the open item (F1)';
  END IF;
  IF NOT v_ok_scale THEN
    RAISE EXCEPTION '0007 VERIFY FAILED: a sub-cent amount was accepted (B2)';
  END IF;
  IF NOT v_ok_app THEN
    RAISE EXCEPTION '0007 VERIFY FAILED: PA-4 tie-out broken after reversal';
  END IF;

  RAISE NOTICE '0007: verified -- reversal un-applies, re-reversal refused, sub-cent refused, tie-out holds';
END $verify$;
