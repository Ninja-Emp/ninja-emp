-- ============================================================================
-- Ninja EMP — 45_openitem.sql  (TENANT-SCOPED)
-- Open-item AR/AP subledger (ADR-0023). A running-balance subledger answers
-- "how much is owed"; open-item accounting answers "which invoices are unpaid,
-- how old, and when did each settle" — required for aging, statements,
-- collections, and cash-basis conversion (ADR-0022).
--
-- Design: ONE open-item model for every subledger kind (ar, ap, vendor_payable,
-- customer_credit, gift_certificate, security_deposit). `open_amount` is always
-- a positive magnitude; the subledger_type_code determines direction.
-- The GL control account remains the source of truth; open items are detail.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- open_item — one row per invoice/charge that can be settled.
-- ----------------------------------------------------------------------------
CREATE TABLE open_item (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  subledger_type_code text NOT NULL REFERENCES kernel.subledger_type(code),
  party_id            uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  source              text NOT NULL,                 -- rent | consignment | pos | manual
  source_ref          text,                          -- e.g. lease id / sale id
  document_no         text,                          -- human-readable invoice no
  original_amount     kernel.money_amount NOT NULL CHECK (original_amount >= 0),
  open_amount         kernel.money_amount NOT NULL CHECK (open_amount >= 0),
  currency            kernel.currency_code NOT NULL DEFAULT 'USD',
  issue_date          date NOT NULL,
  due_date            date,
  status              text NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open','partial','settled','written_off','void')),
  journal_entry_id    uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid DEFAULT kernel.current_actor(),
  version             integer NOT NULL DEFAULT 1,
  deleted_at          timestamptz,
  deleted_by          uuid,
  CHECK (open_amount <= original_amount),
  CHECK (due_date IS NULL OR due_date >= issue_date)
);
COMMENT ON TABLE open_item IS 'Open-item AR/AP detail (ADR-0023). open_amount is a positive magnitude; subledger_type_code gives direction.';

CREATE INDEX ix_open_item_party   ON open_item(tenant_id, subledger_type_code, party_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_open_item_open    ON open_item(tenant_id, subledger_type_code, due_date) WHERE status IN ('open','partial') AND deleted_at IS NULL;
CREATE INDEX ix_open_item_source  ON open_item(source, source_ref);

CREATE TRIGGER trg_open_item_audit
  BEFORE UPDATE ON open_item FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- payment_application — matches a cash settlement to an open item (many-to-many).
-- ----------------------------------------------------------------------------
CREATE TABLE payment_application (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  open_item_id     uuid NOT NULL REFERENCES open_item(id) ON DELETE RESTRICT,
  applied_amount   kernel.money_amount NOT NULL CHECK (applied_amount > 0),
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  applied_date     date NOT NULL,
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1
);
COMMENT ON TABLE payment_application IS 'Allocation of a cash settlement to an open item (ADR-0023).';

CREATE INDEX ix_payment_application_item ON payment_application(open_item_id);
CREATE INDEX ix_payment_application_je   ON payment_application(journal_entry_id);

CREATE TRIGGER trg_payment_application_audit
  BEFORE UPDATE ON payment_application FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- open_item — helper to create an open item (used by domain posting functions).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION open_item_create(
  p_subledger_type text,
  p_party_id       uuid,
  p_source         text,
  p_source_ref     text,
  p_document_no    text,
  p_amount         kernel.money_amount,
  p_currency       kernel.currency_code,
  p_issue_date     date,
  p_due_date       date,
  p_journal_entry  uuid
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO open_item (
    subledger_type_code, party_id, source, source_ref, document_no,
    original_amount, open_amount, currency, issue_date, due_date, journal_entry_id
  ) VALUES (
    p_subledger_type, p_party_id, p_source, p_source_ref, p_document_no,
    p_amount, p_amount, p_currency, p_issue_date, p_due_date, p_journal_entry
  ) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;
COMMENT ON FUNCTION open_item_create IS 'Creates an open item (AR/AP detail) linked to its originating journal entry.';

-- ----------------------------------------------------------------------------
-- subledger_control_role — maps a subledger type to its control posting role.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION subledger_control_role(p_subledger_type text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_subledger_type
    WHEN 'ar'                THEN 'ar_control'
    WHEN 'ap'                THEN 'ap_control'
    WHEN 'vendor_payable'    THEN 'vendor_payable_control'
    WHEN 'consignor_payable' THEN 'consignor_payable_control'
    WHEN 'customer_credit'   THEN 'customer_credit_control'
    WHEN 'gift_certificate'  THEN 'gift_certificate_control'
    WHEN 'security_deposit'  THEN 'security_deposit_control'
    ELSE NULL
  END
$$;
COMMENT ON FUNCTION subledger_control_role IS 'Maps a subledger type to its GL control posting role (ADR-0020).';

-- ----------------------------------------------------------------------------
-- apply_payment — settle a party's open items FIFO and post the cash entry.
-- For debit-normal subledgers (ar) the store RECEIVES cash: debit cash /
-- credit control. For credit-normal subledgers (ap, vendor_payable,
-- consignor_payable) the store PAYS cash: debit control / credit cash.
-- Idempotent via p_idempotency_key. Returns the journal_entry id.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_payment(
  p_party_id        uuid,
  p_subledger_type  text,
  p_amount          kernel.money_amount,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_receipt   boolean;   -- true = store receives cash (AR), false = store pays (AP-like)
  v_control   uuid;
  v_cash      uuid;
  v_ccy       kernel.currency_code;
  v_entry     uuid;
  v_remaining kernel.money_amount := p_amount;
  v_item      record;
  v_apply     kernel.money_amount;
  v_lines     jsonb;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be positive' USING ERRCODE='23514';
  END IF;

  -- Direction: AR is debit-normal (we receive); all payable-like subledgers are credit-normal (we pay).
  v_receipt := p_subledger_type = 'ar';
  v_control := posting_account(subledger_control_role(p_subledger_type));
  v_cash    := posting_account('cash');
  v_ccy     := (SELECT functional_currency FROM tenant_config LIMIT 1);

  -- Post the cash entry first (idempotent).
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

  -- If this idempotency key was already applied, do not double-allocate.
  IF EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    RETURN v_entry;
  END IF;

  -- Allocate FIFO across the party's open items.
  FOR v_item IN
    SELECT * FROM open_item
     WHERE party_id = p_party_id
       AND subledger_type_code = p_subledger_type
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

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'Payment of % exceeds open items for party % subledger % (unapplied %)',
      p_amount, p_party_id, p_subledger_type, v_remaining USING ERRCODE='23514';
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION apply_payment IS 'Idempotent payment: posts cash entry and allocates FIFO across open items (ADR-0023).';

-- ----------------------------------------------------------------------------
-- Views: open items, aging.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_open_item AS
  SELECT oi.id, oi.subledger_type_code, oi.party_id, p.display_name AS party_name,
         oi.source, oi.source_ref, oi.document_no,
         oi.original_amount, oi.open_amount, oi.currency,
         oi.issue_date, oi.due_date, oi.status,
         (current_date - COALESCE(oi.due_date, oi.issue_date)) AS days_outstanding
    FROM open_item oi
    JOIN party p ON p.id = oi.party_id
   WHERE oi.deleted_at IS NULL;
COMMENT ON VIEW v_open_item IS 'Open items with party name and days outstanding.';

-- Aging buckets (0-30, 31-60, 61-90, 90+), per party per subledger type.
CREATE OR REPLACE VIEW v_aging AS
  SELECT subledger_type_code, party_id, party_name,
         sum(CASE WHEN days_outstanding <= 30 THEN open_amount ELSE 0 END) AS bucket_0_30,
         sum(CASE WHEN days_outstanding BETWEEN 31 AND 60 THEN open_amount ELSE 0 END) AS bucket_31_60,
         sum(CASE WHEN days_outstanding BETWEEN 61 AND 90 THEN open_amount ELSE 0 END) AS bucket_61_90,
         sum(CASE WHEN days_outstanding > 90 THEN open_amount ELSE 0 END) AS bucket_90_plus,
         sum(open_amount) AS total_open
    FROM v_open_item
   WHERE status IN ('open','partial')
   GROUP BY subledger_type_code, party_id, party_name;
COMMENT ON VIEW v_aging IS 'AR/AP aging buckets per party per subledger type.';

-- ----------------------------------------------------------------------------
-- INVARIANT: Σ open items per subledger type must equal its GL control balance.
-- Extends subledger_control_check (ADR-0023). difference must be 0.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION open_item_control_check()
RETURNS TABLE (
  subledger_type_code text,
  open_item_total     numeric,
  control_total       numeric,
  difference          numeric
)
LANGUAGE sql STABLE AS $$
  WITH oi AS (
    SELECT subledger_type_code AS st, sum(open_amount) AS total
      FROM open_item
     WHERE status IN ('open','partial') AND deleted_at IS NULL
     GROUP BY subledger_type_code
  ),
  ctl AS (
    SELECT a.control_subledger_type_code AS st,
           abs(sum(jl.base_debit - jl.base_credit)) AS total
      FROM journal_line jl
      JOIN account a ON a.id = jl.account_id
     WHERE a.is_control
     GROUP BY a.control_subledger_type_code
  )
  SELECT COALESCE(oi.st, ctl.st),
         COALESCE(oi.total, 0),
         COALESCE(ctl.total, 0),
         COALESCE(oi.total, 0) - COALESCE(ctl.total, 0)
    FROM oi FULL OUTER JOIN ctl ON oi.st = ctl.st
   ORDER BY 1;
$$;
COMMENT ON FUNCTION open_item_control_check IS 'Invariant: Σ open items must equal the GL control balance per subledger type (difference = 0).';
