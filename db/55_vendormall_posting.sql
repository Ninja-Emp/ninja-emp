-- ============================================================================
-- Ninja EMP — 55_vendormall_posting.sql  (TENANT-SCOPED)
-- Wires the Vendor Mall domain to the double-entry ledger. All posting is
-- idempotent and resolves accounts through posting_map (ADR-0020) — never by
-- hard-coded account code.
--   * post_rent_invoice()    — bills a lease's periodic rent components to AR.
--   * post_deposit_receipt() — records a security deposit as cash / liability.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- Map a rent component type to its revenue posting role.
CREATE OR REPLACE FUNCTION rent_component_posting_role(p_type text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_type
    WHEN 'base_rent'       THEN 'rent_revenue'
    WHEN 'cam'             THEN 'cam_revenue'
    WHEN 'percentage_rent' THEN 'percentage_rent_revenue'
    ELSE 'other_income'
  END
$$;
COMMENT ON FUNCTION rent_component_posting_role IS 'Maps a rent component type to its revenue posting role.';

-- ----------------------------------------------------------------------------
-- post_rent_invoice: bill the lease's active rent components for a period.
-- Debits AR control (tagged to the lessee, subledger 'ar'); credits each
-- component's revenue account. Idempotent via p_idempotency_key.
-- Returns the journal_entry id.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_rent_invoice(
  p_lease_id        uuid,
  p_period_start    date,
  p_period_end      date,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_lease      record;
  v_lines      jsonb := '[]'::jsonb;
  v_total      kernel.money_amount := 0;
  v_comp       record;
  v_role       text;
  v_acct       uuid;
  v_amt        kernel.money_amount;
  v_entry      uuid;
BEGIN
  SELECT * INTO v_lease FROM lease WHERE id = p_lease_id AND deleted_at IS NULL;
  IF v_lease IS NULL THEN
    RAISE EXCEPTION 'Lease % not found', p_lease_id USING ERRCODE='23503';
  END IF;

  -- Sum fixed components effective within the period.
  FOR v_comp IN
    SELECT * FROM rent_component
     WHERE lease_id = p_lease_id
       AND component_type_code <> 'percentage_rent'
       AND effective_from <= p_period_end
       AND (effective_thru IS NULL OR effective_thru >= p_period_start)
     ORDER BY component_type_code
  LOOP
    v_amt := v_comp.amount;
    IF v_amt = 0 THEN CONTINUE; END IF;
    v_role := rent_component_posting_role(v_comp.component_type_code);
    v_acct := posting_account(v_role);
    v_total := v_total + v_amt;
    v_lines := v_lines || jsonb_build_object(
      'account_id', v_acct, 'credit', v_amt, 'currency', v_comp.currency,
      'memo', v_comp.component_type_code || ' ' || p_period_start || '..' || p_period_end
    );
  END LOOP;

  IF v_total = 0 THEN
    RAISE EXCEPTION 'Lease % has no billable rent components for %..%',
      p_lease_id, p_period_start, p_period_end USING ERRCODE='23514';
  END IF;

  -- AR debit line, tagged to the lessee on the 'ar' subledger.
  v_lines := jsonb_build_array(jsonb_build_object(
      'account_id', posting_account('ar_control'),
      'debit', v_total,
      'currency', (SELECT functional_currency FROM tenant_config LIMIT 1),
      'party_id', v_lease.lessee_party_id,
      'subledger_type_code', 'ar',
      'memo', 'Rent invoice lease ' || v_lease.lease_no
    )) || v_lines;

  v_entry := post_journal_entry(
    p_entry_date,
    'Rent invoice lease ' || v_lease.lease_no || ' ' || p_period_start || '..' || p_period_end,
    'rent', p_lease_id::text, p_idempotency_key, v_lines
  );

  -- Open-item AR detail (ADR-0023): one open item per invoice, due on the lease
  -- billing day of the period end month. Idempotent — skip if already opened.
  IF NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
    PERFORM open_item_create(
      'ar', v_lease.lessee_party_id, 'rent', p_lease_id::text,
      'RENT-' || v_lease.lease_no || '-' || to_char(p_period_end, 'YYYYMM'),
      v_total, (SELECT functional_currency FROM tenant_config LIMIT 1),
      p_entry_date,
      (date_trunc('month', p_period_end)
        + (LEAST(v_lease.billing_day, 28) - 1) * interval '1 day')::date,
      v_entry
    );
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_rent_invoice IS 'Idempotent rent invoice: AR debit (lessee) / revenue credits, resolved via posting_map.';

-- ----------------------------------------------------------------------------
-- post_deposit_receipt: record a security deposit as cash / deposit liability.
-- Idempotent; updates lease_deposit.journal_entry_id and status='held'.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_deposit_receipt(
  p_deposit_id      uuid,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_dep   record;
  v_entry uuid;
  v_lines jsonb;
BEGIN
  SELECT * INTO v_dep FROM lease_deposit WHERE id = p_deposit_id;
  IF v_dep IS NULL THEN
    RAISE EXCEPTION 'Lease deposit % not found', p_deposit_id USING ERRCODE='23503';
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('cash'),
                       'debit', v_dep.deposit_amount, 'currency', v_dep.currency,
                       'memo', 'Security deposit received'),
    jsonb_build_object('account_id', posting_account('security_deposit_control'),
                       'credit', v_dep.deposit_amount, 'currency', v_dep.currency,
                       'party_id', (SELECT lessee_party_id FROM lease WHERE id = v_dep.lease_id),
                       'subledger_type_code', 'security_deposit',
                       'memo', 'Security deposit held')
  );

  v_entry := post_journal_entry(
    p_entry_date, 'Security deposit for lease ' || v_dep.lease_id,
    'deposit', p_deposit_id::text, p_idempotency_key, v_lines
  );

  UPDATE lease_deposit
     SET journal_entry_id = v_entry,
         status = 'held',
         received_date = COALESCE(received_date, p_entry_date)
   WHERE id = p_deposit_id;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_deposit_receipt IS 'Idempotent deposit receipt: cash debit / deposit liability credit; links the ledger entry.';
