-- ============================================================================
-- Ninja EMP — 65_consignment_posting.sql  (TENANT-SCOPED)
-- Wires the Consignment domain to the double-entry ledger. Idempotent;
-- resolves accounts via posting_map (ADR-0020) — never by hard-coded code.
--   * post_consignment_sale()   — records a sale: cash/revenue + COGS/payable.
--   * post_consignor_payout()   — pays a consignor: payable debit / cash credit.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- post_consignment_sale: post a completed sale and open the consignor payable.
-- Lines:
--   debit  cash (sale total)                     [or AR if on account]
--   credit sales_revenue (sale total)
--   debit  consignment_cogs (net-to-consignor total)
--   credit consignor_payable_control (net total, tagged per consignor)
-- The store's margin (commission) is implicit: revenue - COGS = commission.
-- Idempotent via p_idempotency_key. Returns the journal_entry id.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_consignment_sale(
  p_sale_id         uuid,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_sale      record;
  v_lines     jsonb := '[]'::jsonb;
  v_gross     kernel.money_amount := 0;
  v_net       kernel.money_amount := 0;
  v_ccy       kernel.currency_code;
  v_entry     uuid;
  v_line      record;
BEGIN
  SELECT * INTO v_sale FROM consignment_sale WHERE id = p_sale_id;
  IF v_sale IS NULL THEN
    RAISE EXCEPTION 'Consignment sale % not found', p_sale_id USING ERRCODE='23503';
  END IF;
  IF v_sale.status <> 'completed' THEN
    RAISE EXCEPTION 'Sale % is not completed (status=%)', p_sale_id, v_sale.status USING ERRCODE='23514';
  END IF;

  v_ccy := (SELECT functional_currency FROM tenant_config LIMIT 1);

  -- Totals.
  SELECT COALESCE(sum(sale_price),0), COALESCE(sum(net_to_consignor),0)
    INTO v_gross, v_net
    FROM consignment_sale_line WHERE sale_id = p_sale_id;

  IF v_gross = 0 THEN
    RAISE EXCEPTION 'Sale % has no lines', p_sale_id USING ERRCODE='23514';
  END IF;

  -- Cash debit (sale total) + revenue credit.
  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('cash'), 'debit', v_gross, 'currency', v_ccy,
    'memo', 'Consignment sale ' || v_sale.sale_no);
  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('sales_revenue'), 'credit', v_gross, 'currency', v_ccy,
    'memo', 'Consignment sale ' || v_sale.sale_no);

  -- COGS debit (net total) + consignor payable credit, tagged per consignor.
  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('consignment_cogs'), 'debit', v_net, 'currency', v_ccy,
    'memo', 'Consignment COGS sale ' || v_sale.sale_no);

  FOR v_line IN
    SELECT consignor_party_id, sum(net_to_consignor) AS net
      FROM consignment_sale_line WHERE sale_id = p_sale_id
     GROUP BY consignor_party_id
  LOOP
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('consignor_payable_control'),
      'credit', v_line.net, 'currency', v_ccy,
      'party_id', v_line.consignor_party_id,
      'subledger_type_code', 'consignor_payable',
      'memo', 'Consignor payable sale ' || v_sale.sale_no);
  END LOOP;

  v_entry := post_journal_entry(
    p_entry_date, 'Consignment sale ' || v_sale.sale_no,
    'consignment', p_sale_id::text, p_idempotency_key, v_lines
  );

  UPDATE consignment_sale SET journal_entry_id = v_entry WHERE id = p_sale_id;

  -- Open-item AP detail: one open item per consignor for this sale (ADR-0023).
  IF NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
    FOR v_line IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM consignment_sale_line WHERE sale_id = p_sale_id
       GROUP BY consignor_party_id
    LOOP
      PERFORM open_item_create(
        'consignor_payable', v_line.consignor_party_id, 'consignment', p_sale_id::text,
        'CSALE-' || v_sale.sale_no, v_line.net, v_ccy, p_entry_date, NULL, v_entry);
    END LOOP;
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_consignment_sale IS 'Idempotent consignment sale: cash/revenue + COGS/consignor-payable; opens AP items.';

-- ----------------------------------------------------------------------------
-- post_consignor_payout: pay a consignor for a finalized settlement.
-- Debits consignor payable control (tagged), credits cash. Idempotent.
-- ----------------------------------------------------------------------------
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

  -- Settle the consignor's open items FIFO (ADR-0023) so open items stay tied
  -- to the control account. Skip if already applied (idempotent).
  IF NOT EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    DECLARE
      v_remaining kernel.money_amount := v_pay.payout_amount;
      v_item      record;
      v_apply     kernel.money_amount;
    BEGIN
      FOR v_item IN
        SELECT * FROM open_item
         WHERE party_id = v_set.consignor_party_id
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
        VALUES (v_item.id, v_apply, v_pay.currency, p_entry_date, v_entry);
        UPDATE open_item
           SET open_amount = open_amount - v_apply,
               status = CASE WHEN open_amount - v_apply = 0 THEN 'settled' ELSE 'partial' END
         WHERE id = v_item.id;
        v_remaining := v_remaining - v_apply;
      END LOOP;
    END;
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_consignor_payout IS 'Idempotent consignor payout: payable debit / cash credit; marks settlement paid.';
