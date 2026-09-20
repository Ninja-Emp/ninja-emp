-- ============================================================================
-- Ninja EMP — 75_pos_posting.sql  (TENANT-SCOPED)
-- Wires POS to the double-entry ledger. Idempotent; resolves accounts via
-- posting_map (ADR-0020) — never by hard-coded account code.
--
--   * post_sale()                 — completes a sale (ADR-0028 accrual at sale)
--   * post_refund()               — reversal-not-edit refund document
--   * post_shift_close()          — drawer count, over/short (ADR-0029)
--   * post_merchant_settlement()  — card clearing -> bank, fee expensed
--
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- post_sale — the core POS posting.
--
-- DEBITS  (where the money went)
--   per tender: undeposited_funds | card_clearing | liability control
-- CREDITS (what was earned / owed)
--   sales_revenue      = net merchandise (subtotal - discount)
--   sales_tax_payable  = tax collected
-- Then, for CONSIGNMENT lines only (ADR-0028 — accrues AT SALE):
--   debit  consignment_cogs            (total net owed to consignors)
--   credit consignor_payable_control   (per consignor, subledger-tagged)
-- and an AP open item is opened per consignor so the vendor portal and aging
-- both read from the same source of truth.
--
-- Idempotent via p_idempotency_key. Returns the journal_entry id.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_sale(
  p_sale_id         uuid,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_sale     record;
  v_lines    jsonb := '[]'::jsonb;
  v_ccy      kernel.currency_code;
  v_entry    uuid;
  v_t        record;
  v_net_rev  kernel.money_amount;
  v_tender   kernel.money_amount;
  v_consignor_net kernel.money_amount;
  v_role     text;
  v_sub      text;
BEGIN
  SELECT * INTO v_sale FROM sale WHERE id = p_sale_id;
  IF v_sale IS NULL THEN
    RAISE EXCEPTION 'Sale % not found', p_sale_id USING ERRCODE='23503';
  END IF;
  IF v_sale.is_refund THEN
    RAISE EXCEPTION 'Sale % is a refund document; use post_refund()', p_sale_id USING ERRCODE='23514';
  END IF;
  IF v_sale.status <> 'completed' THEN
    RAISE EXCEPTION 'Sale % is not completed (status=%)', p_sale_id, v_sale.status USING ERRCODE='23514';
  END IF;

  v_ccy     := v_sale.currency;
  v_net_rev := v_sale.subtotal - v_sale.discount_total;

  -- --- DEBIT side: one line per tender ------------------------------------
  SELECT COALESCE(sum(pt.amount), 0) INTO v_tender
    FROM payment p JOIN payment_tender pt ON pt.payment_id = p.id
   WHERE p.sale_id = p_sale_id AND p.status = 'captured';

  IF v_tender <> v_sale.total THEN
    RAISE EXCEPTION 'Sale % tenders (%) do not equal sale total (%)',
      p_sale_id, v_tender, v_sale.total USING ERRCODE='23514';
  END IF;

  FOR v_t IN
    SELECT tt.debit_role_code, tt.settlement_kind, tt.subledger_type_code,
           pt.party_id, sum(pt.amount) AS amt
      FROM payment p
      JOIN payment_tender pt ON pt.payment_id = p.id
      JOIN tender_type tt ON tt.code = pt.tender_type_code
     WHERE p.sale_id = p_sale_id AND p.status = 'captured'
     GROUP BY tt.debit_role_code, tt.settlement_kind, tt.subledger_type_code, pt.party_id
  LOOP
    -- Liability tenders must be subledger-tagged to the party whose balance falls.
    IF v_t.settlement_kind = 'liability' THEN
      IF v_t.party_id IS NULL THEN
        RAISE EXCEPTION 'Liability tender on sale % requires party_id', p_sale_id USING ERRCODE='23514';
      END IF;
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account(v_t.debit_role_code),
        'debit', v_t.amt, 'currency', v_ccy,
        'party_id', v_t.party_id,
        'subledger_type_code', v_t.subledger_type_code,
        'memo', 'Tender ' || v_t.debit_role_code || ' sale ' || v_sale.sale_no);
    ELSE
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account(v_t.debit_role_code),
        'debit', v_t.amt, 'currency', v_ccy,
        'memo', 'Tender ' || v_t.debit_role_code || ' sale ' || v_sale.sale_no);
    END IF;
  END LOOP;

  -- --- CREDIT side: revenue + tax -----------------------------------------
  IF v_net_rev <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('sales_revenue'),
      'credit', v_net_rev, 'currency', v_ccy,
      'memo', 'Sale ' || v_sale.sale_no);
  END IF;

  IF v_sale.tax_total <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('sales_tax_payable'),
      'credit', v_sale.tax_total, 'currency', v_ccy,
      'memo', 'Sales tax sale ' || v_sale.sale_no);
  END IF;

  -- --- Consignor accrual AT SALE (ADR-0028) --------------------------------
  SELECT COALESCE(sum(net_to_consignor), 0) INTO v_consignor_net
    FROM sale_line WHERE sale_id = p_sale_id AND line_kind = 'consignment';

  IF v_consignor_net > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('consignment_cogs'),
      'debit', v_consignor_net, 'currency', v_ccy,
      'memo', 'Consignment COGS sale ' || v_sale.sale_no);

    FOR v_t IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM sale_line
       WHERE sale_id = p_sale_id AND line_kind = 'consignment'
       GROUP BY consignor_party_id
    LOOP
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account('consignor_payable_control'),
        'credit', v_t.net, 'currency', v_ccy,
        'party_id', v_t.consignor_party_id,
        'subledger_type_code', 'consignor_payable',
        'memo', 'Consignor payable sale ' || v_sale.sale_no);
    END LOOP;
  END IF;

  v_entry := post_journal_entry(
    p_entry_date, 'POS sale ' || v_sale.sale_no,
    'pos', p_sale_id::text, p_idempotency_key, v_lines);

  UPDATE sale SET journal_entry_id = v_entry WHERE id = p_sale_id;
  UPDATE payment SET journal_entry_id = v_entry
   WHERE sale_id = p_sale_id AND journal_entry_id IS NULL;

  -- Open-item AP per consignor so aging + portal read one source of truth.
  IF v_consignor_net > 0
     AND NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
    FOR v_t IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM sale_line
       WHERE sale_id = p_sale_id AND line_kind = 'consignment'
       GROUP BY consignor_party_id
    LOOP
      PERFORM open_item_create(
        'consignor_payable', v_t.consignor_party_id, 'pos', p_sale_id::text,
        'POS-' || v_sale.sale_no, v_t.net, v_ccy, p_entry_date, NULL, v_entry);
    END LOOP;
  END IF;

  RETURN v_entry;
END $$;
COMMENT ON FUNCTION post_sale IS 'Idempotent POS sale posting; accrues consignor payable AT SALE (ADR-0028).';

-- ----------------------------------------------------------------------------
-- post_refund — a refund is its OWN document that reverses the original.
-- Reversal-not-edit: we never mutate the original sale's journal entry.
-- Lines are the mirror image of post_sale.
-- ----------------------------------------------------------------------------
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
  -- ITEMS must be relieved too — otherwise the open-item layer would still show
  -- money owed that the GL control account no longer carries (ADR-0023).
  -- Idempotent: skip if this entry already produced applications.
  IF v_cons > 0
     AND NOT EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    DECLARE
      v_party     record;
      v_remaining kernel.money_amount;
      v_item      record;
      v_apply     kernel.money_amount;
    BEGIN
      FOR v_party IN
        SELECT consignor_party_id, sum(net_to_consignor) AS net
          FROM sale_line
         WHERE sale_id = p_refund_sale_id AND line_kind = 'consignment'
         GROUP BY consignor_party_id
      LOOP
        v_remaining := v_party.net;
        FOR v_item IN
          SELECT * FROM open_item
           WHERE party_id = v_party.consignor_party_id
             AND subledger_type_code = 'consignor_payable'
             AND status IN ('open','partial')
             AND deleted_at IS NULL
           ORDER BY COALESCE(due_date, issue_date), issue_date, id
           FOR UPDATE
        LOOP
          EXIT WHEN v_remaining <= 0;
          v_apply := LEAST(v_remaining, v_item.open_amount);
          IF v_apply <= 0 THEN CONTINUE; END IF;
          INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date, journal_entry_id)
          VALUES (v_item.id, v_apply, v_ccy, p_entry_date, v_entry);
          UPDATE open_item
             SET open_amount = open_amount - v_apply,
                 status = CASE WHEN open_amount - v_apply = 0 THEN 'settled' ELSE 'partial' END
           WHERE id = v_item.id;
          v_remaining := v_remaining - v_apply;
        END LOOP;
      END LOOP;
    END;
  END IF;

  RETURN v_entry;
END $$;
COMMENT ON FUNCTION post_refund IS 'Idempotent refund posting (reversal-not-edit; reverses consignor accrual and relieves open items).';

-- ----------------------------------------------------------------------------
-- post_shift_close — count the drawer and book any over/short.
-- expected_cash = opening_float + cash tenders taken during the shift.
-- Difference -> cash_over_short (never silently into revenue, ADR-0029).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_shift_close(
  p_shift_id        uuid,
  p_counted_cash    kernel.money_amount,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_shift    record;
  v_cash_in  kernel.money_amount;
  v_expected kernel.money_amount;
  v_diff     kernel.money_amount;
  v_lines    jsonb;
  v_entry    uuid;
  v_ccy      kernel.currency_code;
BEGIN
  SELECT * INTO v_shift FROM shift WHERE id = p_shift_id;
  IF v_shift IS NULL THEN
    RAISE EXCEPTION 'Shift % not found', p_shift_id USING ERRCODE='23503';
  END IF;
  v_ccy := v_shift.currency;

  -- Cash actually taken in this shift (cash-kind tenders only).
  SELECT COALESCE(sum(pt.amount), 0) INTO v_cash_in
    FROM sale s
    JOIN payment p ON p.sale_id = s.id AND p.status = 'captured'
    JOIN payment_tender pt ON pt.payment_id = p.id
    JOIN tender_type tt ON tt.code = pt.tender_type_code
   WHERE s.shift_id = p_shift_id
     AND tt.settlement_kind = 'cash'
     AND NOT s.is_refund;

  v_expected := v_shift.opening_float + v_cash_in;
  v_diff     := p_counted_cash - v_expected;

  UPDATE shift
     SET counted_cash = p_counted_cash,
         expected_cash = v_expected,
         over_short    = v_diff,
         closed_at     = COALESCE(closed_at, now()),
         status        = 'closed'
   WHERE id = p_shift_id;

  -- No difference -> nothing to post. That is the good case.
  IF v_diff = 0 THEN
    RETURN NULL;
  END IF;

  IF v_diff > 0 THEN
    -- Drawer is OVER: more cash than expected -> income.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', posting_account('undeposited_funds'),
                         'debit', v_diff, 'currency', v_ccy,
                         'memo', 'Drawer over shift ' || v_shift.shift_no),
      jsonb_build_object('account_id', posting_account('cash_over_short'),
                         'credit', v_diff, 'currency', v_ccy,
                         'memo', 'Drawer over shift ' || v_shift.shift_no));
  ELSE
    -- Drawer is SHORT: less cash than expected -> expense (contra-income).
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', posting_account('cash_over_short'),
                         'debit', -v_diff, 'currency', v_ccy,
                         'memo', 'Drawer short shift ' || v_shift.shift_no),
      jsonb_build_object('account_id', posting_account('undeposited_funds'),
                         'credit', -v_diff, 'currency', v_ccy,
                         'memo', 'Drawer short shift ' || v_shift.shift_no));
  END IF;

  v_entry := post_journal_entry(
    p_entry_date, 'Shift close ' || v_shift.shift_no,
    'pos_shift', p_shift_id::text, p_idempotency_key, v_lines);

  UPDATE shift SET journal_entry_id = v_entry WHERE id = p_shift_id;
  RETURN v_entry;
END $$;
COMMENT ON FUNCTION post_shift_close IS 'Closes a drawer session and books over/short (ADR-0029).';

-- ----------------------------------------------------------------------------
-- post_merchant_settlement — processor deposit: clearing -> bank, fee expensed.
--   debit  bank          (net received)
--   debit  merchant_fees (fee)
--   credit card_clearing (gross)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_merchant_settlement(
  p_settlement_id   uuid,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_s     record;
  v_lines jsonb;
  v_entry uuid;
BEGIN
  SELECT * INTO v_s FROM merchant_settlement WHERE id = p_settlement_id;
  IF v_s IS NULL THEN
    RAISE EXCEPTION 'Merchant settlement % not found', p_settlement_id USING ERRCODE='23503';
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('bank'),
                       'debit', v_s.net_amount, 'currency', v_s.currency,
                       'memo', 'Processor deposit ' || v_s.settlement_no));

  IF v_s.fee_amount > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('merchant_fees'),
      'debit', v_s.fee_amount, 'currency', v_s.currency,
      'memo', 'Merchant fees ' || v_s.settlement_no);
  END IF;

  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('card_clearing'),
    'credit', v_s.gross_amount, 'currency', v_s.currency,
    'memo', 'Clearing released ' || v_s.settlement_no);

  v_entry := post_journal_entry(
    p_entry_date, 'Merchant settlement ' || v_s.settlement_no,
    'merchant', p_settlement_id::text, p_idempotency_key, v_lines);

  UPDATE merchant_settlement SET journal_entry_id = v_entry WHERE id = p_settlement_id;
  RETURN v_entry;
END $$;
COMMENT ON FUNCTION post_merchant_settlement IS 'Clearing -> bank with merchant fee expensed (ADR-0029).';
