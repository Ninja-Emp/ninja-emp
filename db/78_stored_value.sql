-- ============================================================================
-- 78_stored_value.sql — Gift certificates & store credit (ADR-0032).
--
-- Before this file, both were REDEEMABLE as tenders but could not be ISSUED:
-- the liability had no origin document. This closes that gap.
--
-- Core principles:
--   * Issuing stored value creates a LIABILITY, never revenue. Revenue is
--     recognised on redemption, when goods actually change hands.
--   * Each instrument is an open item, so it ties to the GL control account
--     exactly like AR/AP.
--   * Breakage is OPT-IN (tenant_config.breakage_after_months, default NULL =
--     never). Recognising it automatically is legally wrong in many US states
--     where unredeemed balances escheat rather than becoming income.
-- ============================================================================

-- Breakage policy lives with tenant config, not hard-coded in the posting path.
ALTER TABLE tenant_config
  ADD COLUMN IF NOT EXISTS breakage_after_months smallint;
COMMENT ON COLUMN tenant_config.breakage_after_months IS
  'Months of inactivity after which unredeemed stored value MAY be recognised as breakage income. NULL = never (default). Check state escheatment law before setting (ADR-0032).';

-- ----------------------------------------------------------------------------
-- stored_value — one row per gift certificate or store-credit instrument.
-- ----------------------------------------------------------------------------
CREATE TABLE stored_value (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  instrument_kind  text NOT NULL CHECK (instrument_kind IN ('gift_certificate','store_credit')),
  -- Human-facing code on the card/receipt. Unique per tenant.
  code             text NOT NULL,
  -- Gift certificates are often bearer instruments -> party may be NULL.
  -- Store credit always belongs to someone.
  party_id         uuid REFERENCES party(id) ON DELETE RESTRICT,
  original_amount  kernel.money_amount NOT NULL CHECK (original_amount > 0),
  balance          kernel.money_amount NOT NULL CHECK (balance >= 0),
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  issued_date      date NOT NULL DEFAULT current_date,
  expires_date     date,
  last_activity_at date NOT NULL DEFAULT current_date,
  status           text NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active','redeemed','expired','voided','broken')),
  -- Why it exists: a sale (bought), a refund (credit issued), or manual.
  origin           text NOT NULL DEFAULT 'manual',
  origin_ref       text,
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  open_item_id     uuid REFERENCES open_item(id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1,
  deleted_at       timestamptz,
  deleted_by       uuid,
  CHECK (balance <= original_amount),
  -- Store credit is always attributable; a bearer gift certificate need not be.
  CHECK (instrument_kind <> 'store_credit' OR party_id IS NOT NULL),
  CHECK (expires_date IS NULL OR expires_date >= issued_date)
);
COMMENT ON TABLE stored_value IS 'Gift certificates and store credit. Issuance creates a liability, never revenue (ADR-0032).';
CREATE UNIQUE INDEX ux_stored_value_code ON stored_value(tenant_id, code) WHERE deleted_at IS NULL;
CREATE INDEX ix_stored_value_party  ON stored_value(tenant_id, party_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_stored_value_active ON stored_value(tenant_id, instrument_kind, status)
  WHERE status = 'active' AND deleted_at IS NULL;
CREATE TRIGGER trg_stored_value_audit
  BEFORE UPDATE ON stored_value FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- stored_value_activity — append-only history per instrument.
-- ----------------------------------------------------------------------------
CREATE TABLE stored_value_activity (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  stored_value_id  uuid NOT NULL REFERENCES stored_value(id) ON DELETE RESTRICT,
  activity_kind    text NOT NULL CHECK (activity_kind IN ('issue','redeem','reload','void','expire','breakage')),
  activity_date    date NOT NULL DEFAULT current_date,
  -- Signed: positive increases the balance, negative decreases it.
  amount           kernel.money_amount NOT NULL CHECK (amount <> 0),
  balance_after    kernel.money_amount NOT NULL CHECK (balance_after >= 0),
  sale_id          uuid REFERENCES sale(id) ON DELETE RESTRICT,
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  memo             text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor()
);
COMMENT ON TABLE stored_value_activity IS 'Append-only per-instrument history. Never edited.';
CREATE INDEX ix_sv_activity_instrument ON stored_value_activity(stored_value_id, activity_date);

CREATE OR REPLACE FUNCTION stored_value_activity_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'stored_value_activity is append-only' USING ERRCODE='23514';
END; $$;
CREATE TRIGGER trg_sv_activity_immutable
  BEFORE UPDATE OR DELETE ON stored_value_activity
  FOR EACH ROW EXECUTE FUNCTION stored_value_activity_immutable();

-- ----------------------------------------------------------------------------
-- issue_stored_value — sell a gift certificate / grant store credit.
--
-- Debit: cash (sold) or the refund-driven source. Credit: the liability control.
-- NO REVENUE is recognised here. That is the whole point.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION issue_stored_value(
  p_instrument_kind text,
  p_code            text,
  p_party_id        uuid,
  p_amount          kernel.money_amount,
  p_entry_date      date,
  p_paid_with_cash  boolean DEFAULT true,
  p_expires_date    date DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_sv      uuid;
  v_entry   uuid;
  v_role    text;
  v_control uuid;
  v_sub     text;
  v_key     text;
  v_oi      uuid;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Stored value amount must be positive, got %', p_amount USING ERRCODE='23514';
  END IF;

  v_sub  := CASE p_instrument_kind
              WHEN 'gift_certificate' THEN 'gift_certificate'
              WHEN 'store_credit'     THEN 'customer_credit'
              ELSE NULL END;
  IF v_sub IS NULL THEN
    RAISE EXCEPTION 'Unknown instrument kind %', p_instrument_kind USING ERRCODE='23514';
  END IF;

  v_role    := subledger_control_role(v_sub);
  v_control := posting_account(v_role);
  v_key     := COALESCE(p_idempotency_key, 'sv_issue:' || p_code);

  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN
    SELECT id INTO v_sv FROM stored_value WHERE journal_entry_id = v_entry;
    RETURN v_sv;
  END IF;

  -- A bearer gift certificate has no party, but an open item needs one to tie
  -- to the subledger. Only create the open item when we know the holder.
  IF p_paid_with_cash THEN
    v_entry := post_journal_entry(
      p_entry_date, 'Issue ' || p_instrument_kind || ' ' || p_code,
      'stored_value_issue', p_code, v_key,
      CASE WHEN p_party_id IS NOT NULL THEN
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('undeposited_funds'), 'debit', p_amount),
          jsonb_build_object('account_id', v_control, 'credit', p_amount,
                             'party_id', p_party_id, 'subledger_type_code', v_sub))
      ELSE
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('undeposited_funds'), 'debit', p_amount),
          jsonb_build_object('account_id', v_control, 'credit', p_amount))
      END);
  ELSE
    -- Credit issued without cash in (e.g. goodwill, or a refund to store credit).
    v_entry := post_journal_entry(
      p_entry_date, 'Grant ' || p_instrument_kind || ' ' || p_code,
      'stored_value_issue', p_code, v_key,
      CASE WHEN p_party_id IS NOT NULL THEN
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('sales_discounts'), 'debit', p_amount),
          jsonb_build_object('account_id', v_control, 'credit', p_amount,
                             'party_id', p_party_id, 'subledger_type_code', v_sub))
      ELSE
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('sales_discounts'), 'debit', p_amount),
          jsonb_build_object('account_id', v_control, 'credit', p_amount))
      END);
  END IF;

  IF p_party_id IS NOT NULL THEN
    v_oi := open_item_create(v_sub, p_party_id, 'stored_value_issue', p_code, p_code,
                             p_amount, 'USD', p_entry_date, NULL, v_entry);
  END IF;

  INSERT INTO stored_value (
    instrument_kind, code, party_id, original_amount, balance,
    issued_date, expires_date, last_activity_at, origin, origin_ref,
    journal_entry_id, open_item_id)
  VALUES (p_instrument_kind, p_code, p_party_id, p_amount, p_amount,
          p_entry_date, p_expires_date, p_entry_date, 'manual', p_code, v_entry, v_oi)
  RETURNING id INTO v_sv;

  INSERT INTO stored_value_activity (stored_value_id, activity_kind, activity_date,
                                     amount, balance_after, journal_entry_id, memo)
  VALUES (v_sv, 'issue', p_entry_date, p_amount, p_amount, v_entry, 'Issued');

  RETURN v_sv;
END; $$;
COMMENT ON FUNCTION issue_stored_value IS 'Issues a gift certificate / store credit as a LIABILITY. No revenue recognised (ADR-0032).';

-- ----------------------------------------------------------------------------
-- redeem_stored_value — draw down an instrument.
--
-- The GL side of redemption comes from the POS tender path (a liability tender
-- debits the control account). This function maintains the INSTRUMENT: balance,
-- status, activity, and the open item.
--
-- GL LINKAGE IS MANDATORY. Drawing an instrument down without a corresponding
-- journal entry would silently break `stored_value_control_check` — the
-- instrument balance would fall while the GL liability stayed put. Requiring
-- the linkage makes that drift structurally impossible rather than merely
-- discouraged. Callers redeeming outside POS must post their entry first and
-- pass it in.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION redeem_stored_value(
  p_code        text,
  p_amount      kernel.money_amount,
  p_entry_date  date,
  p_sale_id     uuid DEFAULT NULL,
  p_entry_id    uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_sv  stored_value;
  v_new numeric;
BEGIN
  IF p_entry_id IS NULL AND p_sale_id IS NULL THEN
    RAISE EXCEPTION
      'redeem_stored_value requires a journal entry or sale for GL linkage; '
      'redeeming without one would break the stored-value control invariant'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_sv FROM stored_value WHERE code = p_code AND deleted_at IS NULL FOR UPDATE;
  IF v_sv.id IS NULL THEN
    RAISE EXCEPTION 'No stored value instrument with code %', p_code USING ERRCODE='23514';
  END IF;
  IF v_sv.status <> 'active' THEN
    RAISE EXCEPTION 'Instrument % is %, not active', p_code, v_sv.status USING ERRCODE='23514';
  END IF;
  IF v_sv.expires_date IS NOT NULL AND p_entry_date > v_sv.expires_date THEN
    RAISE EXCEPTION 'Instrument % expired on %', p_code, v_sv.expires_date USING ERRCODE='23514';
  END IF;
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Redemption must be positive, got %', p_amount USING ERRCODE='23514';
  END IF;
  IF p_amount > v_sv.balance THEN
    RAISE EXCEPTION 'Cannot redeem % against a balance of % on %',
      p_amount, v_sv.balance, p_code USING ERRCODE='23514';
  END IF;

  v_new := v_sv.balance - p_amount;

  UPDATE stored_value
     SET balance = v_new,
         status  = CASE WHEN v_new = 0 THEN 'redeemed' ELSE 'active' END,
         last_activity_at = p_entry_date
   WHERE id = v_sv.id;

  -- Keep the open item in step so the subledger still ties to the control.
  -- The reduction is recorded as an application (F5/PA-4): every change to
  -- open_amount must be visible in the activity ledger.
  IF v_sv.open_item_id IS NOT NULL THEN
    INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date,
                                     journal_entry_id, application_kind)
    VALUES (v_sv.open_item_id, p_amount, v_sv.currency, p_entry_date, p_entry_id, 'apply');
    UPDATE open_item
       SET open_amount = open_amount - p_amount,
           status = CASE WHEN open_amount - p_amount = 0 THEN 'settled' ELSE 'partial' END
     WHERE id = v_sv.open_item_id;
  END IF;

  INSERT INTO stored_value_activity (stored_value_id, activity_kind, activity_date,
                                     amount, balance_after, sale_id, journal_entry_id, memo)
  VALUES (v_sv.id, 'redeem', p_entry_date, -p_amount, v_new, p_sale_id, p_entry_id, 'Redeemed');

  RETURN v_sv.id;
END; $$;
COMMENT ON FUNCTION redeem_stored_value IS 'Draws down an instrument and keeps its open item in step. GL side comes from the POS tender.';

-- ----------------------------------------------------------------------------
-- recognize_breakage — OPT-IN. Does nothing unless the tenant configured it.
--
-- Debit the liability control, credit breakage income. Never automatic.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recognize_breakage(
  p_as_of           date,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_months  smallint;
  v_lines   jsonb := '[]'::jsonb;
  v_total   numeric := 0;
  v_entry   uuid;
  v_key     text;
  r         record;
  -- Open items to relieve, collected in the loop and applied once the entry
  -- exists (so each application can link to it).
  v_oi_ids  uuid[]  := '{}';
  v_oi_amts numeric[] := '{}';
  v_oi_ccy  text[]  := '{}';
  v_oi      uuid;
  v_amt     numeric;
  v_ccy     text;
  i         int;
BEGIN
  SELECT breakage_after_months INTO v_months FROM tenant_config LIMIT 1;

  -- Default is NULL = never. Escheatment law usually forbids this; the tenant
  -- must opt in deliberately (ADR-0032).
  IF v_months IS NULL THEN
    RETURN NULL;
  END IF;

  v_key := COALESCE(p_idempotency_key, 'breakage:' || p_as_of::text);
  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  FOR r IN
    SELECT sv.id, sv.code, sv.balance, sv.party_id, sv.instrument_kind,
           CASE sv.instrument_kind
             WHEN 'gift_certificate' THEN 'gift_certificate'
             ELSE 'customer_credit' END AS sub
      FROM stored_value sv
     WHERE sv.status = 'active'
       AND sv.balance > 0
       AND sv.deleted_at IS NULL
       AND sv.last_activity_at + (v_months || ' months')::interval <= p_as_of
  LOOP
    v_lines := v_lines || CASE WHEN r.party_id IS NOT NULL THEN
        jsonb_build_object('account_id', posting_account(subledger_control_role(r.sub)),
                           'debit', r.balance, 'party_id', r.party_id,
                           'subledger_type_code', r.sub, 'memo','Breakage ' || r.code)
      ELSE
        jsonb_build_object('account_id', posting_account(subledger_control_role(r.sub)),
                           'debit', r.balance, 'memo','Breakage ' || r.code)
      END;
    v_total := v_total + r.balance;

    UPDATE stored_value SET balance = 0, status = 'broken', last_activity_at = p_as_of
     WHERE id = r.id;
    -- Collect the open item to relieve; it is applied after the entry exists.
    SELECT sv.open_item_id, oi.open_amount, oi.currency
      INTO v_oi, v_amt, v_ccy
      FROM stored_value sv JOIN open_item oi ON oi.id = sv.open_item_id
     WHERE sv.id = r.id;
    IF v_oi IS NOT NULL THEN
      v_oi_ids  := v_oi_ids  || v_oi;
      v_oi_amts := v_oi_amts || v_amt;
      v_oi_ccy  := v_oi_ccy  || v_ccy;
    END IF;
    INSERT INTO stored_value_activity (stored_value_id, activity_kind, activity_date,
                                       amount, balance_after, memo)
    VALUES (r.id, 'breakage', p_as_of, -r.balance, 0, 'Recognized as breakage income');
  END LOOP;

  IF v_total = 0 THEN RETURN NULL; END IF;

  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('gift_certificate_breakage'), 'credit', v_total,
    'memo','Breakage income');

  v_entry := post_journal_entry(p_as_of, 'Stored value breakage', 'breakage',
                                p_as_of::text, v_key, v_lines);

  -- Record the activity (F5/PA-4) and relieve the open items.
  IF array_length(v_oi_ids, 1) IS NOT NULL THEN
    FOR i IN 1 .. array_length(v_oi_ids, 1) LOOP
      INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date,
                                       journal_entry_id, application_kind)
      VALUES (v_oi_ids[i], v_oi_amts[i], v_oi_ccy[i], p_as_of, v_entry, 'apply');
      UPDATE open_item SET open_amount = 0, status = 'settled' WHERE id = v_oi_ids[i];
    END LOOP;
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION recognize_breakage IS
  'OPT-IN breakage recognition. Returns NULL unless tenant_config.breakage_after_months is set (ADR-0032).';

-- ----------------------------------------------------------------------------
-- stored_value_control_check — instruments vs GL control accounts.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stored_value_control_check()
RETURNS TABLE (instrument_kind text, instrument_total numeric, gl_total numeric, difference numeric)
LANGUAGE sql STABLE AS $$
  WITH sv AS (
    SELECT k.kind AS instrument_kind,
           COALESCE((SELECT sum(balance) FROM stored_value s
                      WHERE s.instrument_kind = k.kind AND s.deleted_at IS NULL), 0) AS total
      FROM (VALUES ('gift_certificate'),('store_credit')) AS k(kind)
  ),
  gl AS (
    SELECT 'gift_certificate'::text AS kind,
           COALESCE((SELECT sum(jl.base_credit - jl.base_debit) FROM journal_line jl
                      WHERE jl.account_id = posting_account('gift_certificate_control')),0) AS total
    UNION ALL
    SELECT 'store_credit',
           COALESCE((SELECT sum(jl.base_credit - jl.base_debit) FROM journal_line jl
                      WHERE jl.account_id = posting_account('customer_credit_control')),0)
  )
  SELECT sv.instrument_kind, sv.total, gl.total, sv.total - gl.total
    FROM sv JOIN gl ON gl.kind = sv.instrument_kind;
$$;
COMMENT ON FUNCTION stored_value_control_check IS 'Invariant: Σ instrument balances must equal the GL liability control (difference = 0).';

-- ----------------------------------------------------------------------------
-- v_stored_value_outstanding — live liability report.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stored_value_outstanding AS
SELECT sv.instrument_kind,
       sv.code,
       sv.party_id,
       p.display_name AS party_name,
       sv.original_amount,
       sv.balance,
       sv.issued_date,
       sv.expires_date,
       sv.last_activity_at,
       (current_date - sv.last_activity_at) AS days_inactive,
       sv.status
  FROM stored_value sv
  LEFT JOIN party p ON p.id = sv.party_id
 WHERE sv.status = 'active' AND sv.balance > 0 AND sv.deleted_at IS NULL;
COMMENT ON VIEW v_stored_value_outstanding IS 'Outstanding stored-value liability with inactivity aging.';
