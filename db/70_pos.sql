-- ============================================================================
-- Ninja EMP — 70_pos.sql  (TENANT-SCOPED)
-- Part 5: POS & Payments.
--
-- Design notes:
--   * ADR-0028: consignor/vendor liability accrues AT SALE (not at settlement),
--     so the vendor portal can read realtime numbers straight from the ledger.
--   * ADR-0029: split tenders are first-class; card tenders hit a CLEARING
--     asset (not cash); liability tenders (store credit / gift certificate)
--     debit the liability control; drawer differences go to cash over/short.
--   * Reversal-not-edit: refunds are new documents that reverse, never updates.
--
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- tender_type — how a customer can pay. Drives which account is debited.
--   settlement_kind:
--     cash      -> undeposited funds / cash on hand
--     clearing  -> card clearing (settles later, net of fees)
--     liability -> extinguishes a liability (store credit, gift certificate)
-- ----------------------------------------------------------------------------
CREATE TABLE tender_type (
  code             text PRIMARY KEY,
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  name             text NOT NULL,
  settlement_kind  text NOT NULL
                     CHECK (settlement_kind IN ('cash','clearing','liability')),
  -- posting_role used to resolve the DEBIT account for this tender.
  debit_role_code  text NOT NULL REFERENCES kernel.posting_role(code),
  -- subledger tagging for liability tenders (store credit / gift certificate).
  subledger_type_code text REFERENCES kernel.subledger_type(code),
  opens_drawer     boolean NOT NULL DEFAULT false,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1,
  -- liability tenders MUST carry a subledger type; others must not.
  CHECK ( (settlement_kind = 'liability') = (subledger_type_code IS NOT NULL) )
);
COMMENT ON TABLE tender_type IS 'Payment methods. settlement_kind drives which account is debited (ADR-0029).';
CREATE TRIGGER trg_tender_type_audit
  BEFORE UPDATE ON tender_type FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

INSERT INTO tender_type (code, name, settlement_kind, debit_role_code, subledger_type_code, opens_drawer) VALUES
  ('cash',        'Cash',              'cash',      'undeposited_funds', NULL,               true),
  ('check',       'Check',             'cash',      'undeposited_funds', NULL,               true),
  ('card',        'Credit/Debit Card', 'clearing',  'card_clearing',     NULL,               false),
  ('store_credit','Store Credit',      'liability', 'customer_credit_control',  'customer_credit',   false),
  ('gift_cert',   'Gift Certificate',  'liability', 'gift_certificate_control', 'gift_certificate',  false)
ON CONFLICT (code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- tax_jurisdiction / tax_rate — effective-dated sales tax.
-- ----------------------------------------------------------------------------
CREATE TABLE tax_jurisdiction (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id   uuid NOT NULL DEFAULT kernel.current_tenant(),
  code        text NOT NULL,
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid DEFAULT kernel.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid DEFAULT kernel.current_actor(),
  version     integer NOT NULL DEFAULT 1,
  deleted_at  timestamptz,
  deleted_by  uuid,
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE tax_jurisdiction IS 'Sales-tax authority (state/county/city/special district).';
CREATE TRIGGER trg_tax_jurisdiction_audit
  BEFORE UPDATE ON tax_jurisdiction FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

CREATE TABLE tax_rate (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id       uuid NOT NULL DEFAULT kernel.current_tenant(),
  jurisdiction_id uuid NOT NULL REFERENCES tax_jurisdiction(id) ON DELETE RESTRICT,
  rate            kernel.percent_rate NOT NULL CHECK (rate >= 0 AND rate <= 1),
  effective_from  date NOT NULL DEFAULT current_date,
  effective_thru  date,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid DEFAULT kernel.current_actor(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid DEFAULT kernel.current_actor(),
  version         integer NOT NULL DEFAULT 1,
  CHECK (effective_thru IS NULL OR effective_thru >= effective_from),
  -- ADR-0021: effective-dated rows must not overlap.
  CONSTRAINT ex_tax_rate_no_overlap EXCLUDE USING gist (
    jurisdiction_id WITH =,
    daterange(effective_from, COALESCE(effective_thru, 'infinity'::date), '[]') WITH &&
  )
);
COMMENT ON TABLE tax_rate IS 'Effective-dated tax rate per jurisdiction (non-overlapping, ADR-0021).';
CREATE TRIGGER trg_tax_rate_audit
  BEFORE UPDATE ON tax_rate FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- register / shift — physical or virtual checkout + its cash drawer session.
-- ----------------------------------------------------------------------------
CREATE TABLE register (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id   uuid NOT NULL DEFAULT kernel.current_tenant(),
  code        text NOT NULL,
  name        text NOT NULL,
  location_id uuid REFERENCES location(id) ON DELETE RESTRICT,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid DEFAULT kernel.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid DEFAULT kernel.current_actor(),
  version     integer NOT NULL DEFAULT 1,
  deleted_at  timestamptz,
  deleted_by  uuid,
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE register IS 'A checkout station (central counter or vendor-run register).';
CREATE TRIGGER trg_register_audit
  BEFORE UPDATE ON register FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

CREATE TABLE shift (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  shift_no         bigint GENERATED ALWAYS AS IDENTITY,
  register_id      uuid NOT NULL REFERENCES register(id) ON DELETE RESTRICT,
  opened_at        timestamptz NOT NULL DEFAULT now(),
  opened_by_party_id uuid REFERENCES party(id) ON DELETE RESTRICT,
  opening_float    kernel.money_amount NOT NULL DEFAULT 0 CHECK (opening_float >= 0),
  closed_at        timestamptz,
  counted_cash     kernel.money_amount,
  expected_cash    kernel.money_amount,
  over_short       kernel.money_amount,
  status           text NOT NULL DEFAULT 'open'
                     CHECK (status IN ('open','closed')),
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1,
  CHECK (status = 'open' OR closed_at IS NOT NULL)
);
COMMENT ON TABLE shift IS 'Cash-drawer session. Over/short is booked at close (ADR-0029).';
CREATE INDEX ix_shift_register ON shift(register_id, status);
CREATE TRIGGER trg_shift_audit
  BEFORE UPDATE ON shift FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- Only one OPEN shift per register at a time.
CREATE UNIQUE INDEX ux_shift_one_open_per_register
  ON shift(register_id) WHERE status = 'open';

-- ----------------------------------------------------------------------------
-- sale / sale_line — the POS document.
-- A line is either a CONSIGNMENT line (owed to a consignor) or an OWNED line
-- (store inventory). Consignment lines carry the consignor + commission split.
-- ----------------------------------------------------------------------------
CREATE TABLE sale (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id         uuid NOT NULL DEFAULT kernel.current_tenant(),
  sale_no           bigint GENERATED ALWAYS AS IDENTITY,
  register_id       uuid REFERENCES register(id) ON DELETE RESTRICT,
  shift_id          uuid REFERENCES shift(id) ON DELETE RESTRICT,
  customer_party_id uuid REFERENCES party(id) ON DELETE RESTRICT,
  sale_date         date NOT NULL DEFAULT current_date,
  channel           text NOT NULL DEFAULT 'in_store'
                      CHECK (channel IN ('in_store','online','phone','event')),
  -- Money totals are DERIVED from lines; enforced by trigger below.
  subtotal          kernel.money_amount NOT NULL DEFAULT 0,
  discount_total    kernel.money_amount NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  tax_total         kernel.money_amount NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  total             kernel.money_amount NOT NULL DEFAULT 0,
  currency          kernel.currency_code NOT NULL DEFAULT 'USD',
  status            text NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft','completed','voided','refunded','partially_refunded')),
  -- Refund linkage: a refund document points at the sale it reverses.
  refunds_sale_id   uuid REFERENCES sale(id) ON DELETE RESTRICT,
  is_refund         boolean NOT NULL DEFAULT false,
  journal_entry_id  uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid DEFAULT kernel.current_actor(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        uuid DEFAULT kernel.current_actor(),
  version           integer NOT NULL DEFAULT 1,
  deleted_at        timestamptz,
  deleted_by        uuid,
  CHECK (total = subtotal - discount_total + tax_total),
  CHECK (is_refund = (refunds_sale_id IS NOT NULL))
);
COMMENT ON TABLE sale IS 'POS sale document. Refunds are separate documents (reversal-not-edit).';
CREATE INDEX ix_sale_date ON sale(sale_date) WHERE deleted_at IS NULL;
CREATE INDEX ix_sale_customer ON sale(customer_party_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_sale_shift ON sale(shift_id);
CREATE TRIGGER trg_sale_audit
  BEFORE UPDATE ON sale FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

CREATE TABLE sale_line (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id          uuid NOT NULL DEFAULT kernel.current_tenant(),
  sale_id            uuid NOT NULL REFERENCES sale(id) ON DELETE RESTRICT,
  line_no            integer NOT NULL,
  line_kind          text NOT NULL
                       CHECK (line_kind IN ('consignment','owned')),
  -- Consignment lines reference the consigned item + its consignor.
  consignment_item_id uuid REFERENCES consignment_item(id) ON DELETE RESTRICT,
  consignor_party_id  uuid REFERENCES party(id) ON DELETE RESTRICT,
  -- Vendor-mall lines may attribute to a vendor (lessee) for reporting.
  vendor_party_id     uuid REFERENCES party(id) ON DELETE RESTRICT,
  sku                text,
  description        text NOT NULL,
  quantity           kernel.quantity NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price         kernel.money_amount NOT NULL CHECK (unit_price >= 0),
  discount_amount    kernel.money_amount NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  extended_price     kernel.money_amount NOT NULL CHECK (extended_price >= 0),
  -- Commission split (consignment lines only). ADR-0028: accrues AT SALE.
  commission_rate    kernel.percent_rate,
  commission_amount  kernel.money_amount NOT NULL DEFAULT 0 CHECK (commission_amount >= 0),
  net_to_consignor   kernel.money_amount NOT NULL DEFAULT 0 CHECK (net_to_consignor >= 0),
  -- Cost (owned lines only) for COGS.
  unit_cost          kernel.money_amount,
  is_taxable         boolean NOT NULL DEFAULT true,
  tax_amount         kernel.money_amount NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  currency           kernel.currency_code NOT NULL DEFAULT 'USD',
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid DEFAULT kernel.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid DEFAULT kernel.current_actor(),
  version            integer NOT NULL DEFAULT 1,
  UNIQUE (sale_id, line_no),
  -- extended price must equal qty*price less discount
  CHECK (extended_price = (quantity * unit_price) - discount_amount),
  -- consignment lines must identify the consignor and split exactly
  CHECK (line_kind <> 'consignment' OR consignor_party_id IS NOT NULL),
  CHECK (line_kind <> 'consignment' OR commission_amount + net_to_consignor = extended_price),
  -- owned lines carry no consignor split
  CHECK (line_kind <> 'owned' OR (consignor_party_id IS NULL
                                  AND commission_amount = 0
                                  AND net_to_consignor = 0))
);
COMMENT ON TABLE sale_line IS 'Sale line. Consignment lines accrue consignor payable AT SALE (ADR-0028).';
CREATE INDEX ix_sale_line_sale ON sale_line(sale_id);
CREATE INDEX ix_sale_line_consignor ON sale_line(consignor_party_id);
CREATE INDEX ix_sale_line_vendor ON sale_line(vendor_party_id);
CREATE INDEX ix_sale_line_item ON sale_line(consignment_item_id);
CREATE TRIGGER trg_sale_line_audit
  BEFORE UPDATE ON sale_line FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- Per-line tax detail (a line can be taxed by several jurisdictions).
CREATE TABLE sale_line_tax (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id       uuid NOT NULL DEFAULT kernel.current_tenant(),
  sale_line_id    uuid NOT NULL REFERENCES sale_line(id) ON DELETE RESTRICT,
  jurisdiction_id uuid NOT NULL REFERENCES tax_jurisdiction(id) ON DELETE RESTRICT,
  rate            kernel.percent_rate NOT NULL,
  tax_amount      kernel.money_amount NOT NULL CHECK (tax_amount >= 0),
  currency        kernel.currency_code NOT NULL DEFAULT 'USD',
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid DEFAULT kernel.current_actor(),
  UNIQUE (sale_line_id, jurisdiction_id)
);
COMMENT ON TABLE sale_line_tax IS 'Tax detail per line per jurisdiction (supports multi-jurisdiction tax).';
CREATE INDEX ix_sale_line_tax_line ON sale_line_tax(sale_line_id);

-- ----------------------------------------------------------------------------
-- payment / payment_tender — money received for a sale (split tenders).
-- ----------------------------------------------------------------------------
CREATE TABLE payment (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  payment_no       bigint GENERATED ALWAYS AS IDENTITY,
  sale_id          uuid NOT NULL REFERENCES sale(id) ON DELETE RESTRICT,
  payment_date     date NOT NULL DEFAULT current_date,
  amount           kernel.money_amount NOT NULL,
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  status           text NOT NULL DEFAULT 'captured'
                     CHECK (status IN ('pending','captured','voided','refunded')),
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1
);
COMMENT ON TABLE payment IS 'Money received (or refunded) for a sale. May comprise several tenders.';
CREATE INDEX ix_payment_sale ON payment(sale_id);
CREATE TRIGGER trg_payment_audit
  BEFORE UPDATE ON payment FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

CREATE TABLE payment_tender (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id         uuid NOT NULL DEFAULT kernel.current_tenant(),
  payment_id        uuid NOT NULL REFERENCES payment(id) ON DELETE RESTRICT,
  tender_type_code  text NOT NULL REFERENCES tender_type(code) ON DELETE RESTRICT,
  amount            kernel.money_amount NOT NULL CHECK (amount > 0),
  currency          kernel.currency_code NOT NULL DEFAULT 'USD',
  -- For liability tenders: which party's credit/certificate was drawn down.
  party_id          uuid REFERENCES party(id) ON DELETE RESTRICT,
  -- Card metadata (never store PAN; last4 only).
  card_last4        char(4),
  processor_ref     text,
  -- Merchant settlement linkage (filled by post_merchant_settlement).
  settled_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid DEFAULT kernel.current_actor(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        uuid DEFAULT kernel.current_actor(),
  version           integer NOT NULL DEFAULT 1
);
COMMENT ON TABLE payment_tender IS 'One tender within a payment. Split tenders are first-class (ADR-0029).';
CREATE INDEX ix_payment_tender_payment ON payment_tender(payment_id);
CREATE INDEX ix_payment_tender_type ON payment_tender(tender_type_code);
CREATE TRIGGER trg_payment_tender_audit
  BEFORE UPDATE ON payment_tender FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- merchant_settlement — processor deposits net of fees (clearing -> bank).
-- ----------------------------------------------------------------------------
CREATE TABLE merchant_settlement (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  settlement_no    bigint GENERATED ALWAYS AS IDENTITY,
  settlement_date  date NOT NULL DEFAULT current_date,
  gross_amount     kernel.money_amount NOT NULL CHECK (gross_amount >= 0),
  fee_amount       kernel.money_amount NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  net_amount       kernel.money_amount NOT NULL CHECK (net_amount >= 0),
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  processor_ref    text,
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1,
  CHECK (net_amount = gross_amount - fee_amount)
);
COMMENT ON TABLE merchant_settlement IS 'Processor payout: clearing -> bank, with fee expensed (ADR-0029).';
CREATE TRIGGER trg_merchant_settlement_audit
  BEFORE UPDATE ON merchant_settlement FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- Invariant: sale header totals must equal the sum of its lines.
-- Deferred so a sale + its lines can be inserted in any order in one txn.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assert_sale_totals() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_sale    uuid := COALESCE(NEW.sale_id, OLD.sale_id);
  v_sub     numeric;
  v_disc    numeric;
  v_tax     numeric;
  r         record;
BEGIN
  -- Resolve the sale row; skip if it has been removed.
  SELECT * INTO r FROM sale WHERE id = v_sale;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT COALESCE(sum(quantity * unit_price), 0),
         COALESCE(sum(discount_amount), 0),
         COALESCE(sum(tax_amount), 0)
    INTO v_sub, v_disc, v_tax
    FROM sale_line WHERE sale_id = v_sale;

  IF r.subtotal <> v_sub OR r.discount_total <> v_disc OR r.tax_total <> v_tax THEN
    RAISE EXCEPTION
      'Sale % totals do not match its lines: header(sub=%, disc=%, tax=%) lines(sub=%, disc=%, tax=%)',
      v_sale, r.subtotal, r.discount_total, r.tax_total, v_sub, v_disc, v_tax;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_sale_line_totals
  AFTER INSERT OR UPDATE OR DELETE ON sale_line
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_sale_totals();

-- ----------------------------------------------------------------------------
-- Invariant: captured tenders must sum to the payment amount.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assert_payment_tenders() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_payment uuid := COALESCE(NEW.payment_id, OLD.payment_id);
  v_sum     numeric;
  r         record;
BEGIN
  SELECT * INTO r FROM payment WHERE id = v_payment;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF r.status = 'pending' THEN RETURN NULL; END IF;

  SELECT COALESCE(sum(amount), 0) INTO v_sum
    FROM payment_tender WHERE payment_id = v_payment;

  IF v_sum <> r.amount THEN
    RAISE EXCEPTION 'Payment % tenders (%) do not equal payment amount (%)',
      v_payment, v_sum, r.amount;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_payment_tender_sum
  AFTER INSERT OR UPDATE OR DELETE ON payment_tender
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_payment_tenders();

-- ----------------------------------------------------------------------------
-- Helper: resolve the effective tax rate for a jurisdiction on a date.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION effective_tax_rate(p_jurisdiction uuid, p_on date)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT rate FROM tax_rate
   WHERE jurisdiction_id = p_jurisdiction
     AND p_on >= effective_from
     AND (effective_thru IS NULL OR p_on <= effective_thru)
   LIMIT 1
$$;
COMMENT ON FUNCTION effective_tax_rate(uuid, date) IS 'Effective-dated tax rate lookup (ADR-0021).';
