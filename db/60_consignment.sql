-- ============================================================================
-- Ninja EMP — 60_consignment.sql  (TENANT-SCOPED)
-- Part 4: Consignment domain. A consignor places goods with the store; the
-- store sells them and owes the consignor the sale price less commission.
--
-- Accounting model (accrual, ADR-0022):
--   * On sale:  debit Cash/AR (sale price), credit Sales Revenue (sale price);
--               debit Consignment COGS (amount due to consignor),
--               credit Consignor Payable (amount due to consignor);
--               debit/credit Commission Revenue is the store's margin.
--   * On payout: debit Consignor Payable, credit Cash.
-- All posting is idempotent and resolves accounts via posting_map (ADR-0020).
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- consignor_agreement — the contract governing a consignor's terms.
-- ----------------------------------------------------------------------------
CREATE TABLE consignor_agreement (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  agreement_no        bigint GENERATED ALWAYS AS IDENTITY,
  consignor_party_id  uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  status              text NOT NULL DEFAULT 'active'
                        CHECK (status IN ('draft','active','suspended','terminated')),
  start_date          date NOT NULL DEFAULT current_date,
  end_date            date,
  settlement_frequency text NOT NULL DEFAULT 'monthly'
                        CHECK (settlement_frequency IN ('on_demand','weekly','biweekly','monthly')),
  default_commission_rate kernel.percent_rate NOT NULL DEFAULT 0.40
                        CHECK (default_commission_rate >= 0 AND default_commission_rate <= 1),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid DEFAULT kernel.current_actor(),
  version             integer NOT NULL DEFAULT 1,
  deleted_at          timestamptz,
  deleted_by          uuid,
  CHECK (end_date IS NULL OR end_date >= start_date)
);
COMMENT ON TABLE consignor_agreement IS 'Consignment contract: terms, commission default, settlement cadence.';

CREATE INDEX ix_consignor_agreement_party ON consignor_agreement(consignor_party_id) WHERE deleted_at IS NULL;
CREATE TRIGGER trg_consignor_agreement_audit
  BEFORE UPDATE ON consignor_agreement FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- commission_rule — effective-dated commission terms for an agreement.
-- Supports flat percentage and tiered (breakpoint) structures.
-- ----------------------------------------------------------------------------
CREATE TABLE commission_rule (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  agreement_id     uuid NOT NULL REFERENCES consignor_agreement(id) ON DELETE RESTRICT,
  rule_type        text NOT NULL DEFAULT 'flat'
                     CHECK (rule_type IN ('flat','tiered')),
  rate             kernel.percent_rate NOT NULL CHECK (rate >= 0 AND rate <= 1),
  breakpoint_amount kernel.money_amount,   -- tiered: rate applies above this amount
  effective_from   date NOT NULL DEFAULT current_date,
  effective_thru   date,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1,
  CHECK (effective_thru IS NULL OR effective_thru >= effective_from),
  CHECK ( (rule_type = 'tiered' AND breakpoint_amount IS NOT NULL)
       OR (rule_type = 'flat') )
);
COMMENT ON TABLE commission_rule IS 'Effective-dated commission terms (flat or tiered) per agreement.';

-- Effective-dated integrity: no overlapping rules for the same agreement (ADR-0021).
--
-- The exclusion key MUST include the band identity (rule_type + breakpoint),
-- not just the agreement.
--
-- The first version of this constraint keyed on (agreement_id, daterange) only.
-- That is correct for a flat rate and catastrophically wrong for a tiered one:
-- a tiered schedule IS a set of concurrently-effective rows, one per band
-- ("40% to 5,000, 30% to 20,000, 25% above"). Keying on the agreement alone
-- made the second band collide with the first, so a tiered commission was
-- physically unstorable and every tiered code path was unreachable. The
-- constraint did not merely over-restrict -- it silently deleted a headline
-- feature, and nothing failed until something tried to use it.
--
-- Compare rent_component (50_vendormall.sql), which got this right by keying
-- on component_type_code as well: base rent and percentage rent coexist on one
-- lease for the same dates because they are different THINGS, not competing
-- versions of one thing. A commission band is the same shape of object.
--
-- COALESCE(...,-1) folds flat rules (breakpoint NULL) into a single "base
-- band" slot. Two flat rates overlapping in time still collide, which is the
-- real error this constraint exists to prevent, as does re-declaring the same
-- breakpoint twice over overlapping dates.
ALTER TABLE commission_rule
  ADD CONSTRAINT ex_commission_rule_no_overlap
  EXCLUDE USING gist (
    agreement_id WITH =,
    rule_type    WITH =,
    (COALESCE(breakpoint_amount::numeric, -1)) WITH =,
    daterange(effective_from, effective_thru, '[]') WITH &&
  );
CREATE INDEX ix_commission_rule_agreement ON commission_rule(agreement_id);
CREATE TRIGGER trg_commission_rule_audit
  BEFORE UPDATE ON commission_rule FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- consignment_item — a physical item placed on consignment.
-- ----------------------------------------------------------------------------
CREATE TABLE consignment_item (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  agreement_id     uuid NOT NULL REFERENCES consignor_agreement(id) ON DELETE RESTRICT,
  item_no          bigint GENERATED ALWAYS AS IDENTITY,
  sku              text,
  description      text NOT NULL,
  category         text,
  condition        text,
  agreed_price     kernel.money_amount NOT NULL CHECK (agreed_price >= 0),
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  received_date    date NOT NULL DEFAULT current_date,
  -- 'reserved' = held against an open layaway (84_markdown_layaway.sql). It is
  -- off the sales floor but NOT sold: no revenue, no consignor payable, and it
  -- returns to 'available' if the layaway is cancelled.
  status           text NOT NULL DEFAULT 'received'
                     CHECK (status IN ('received','available','reserved','sold','returned','withdrawn','lost')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1,
  deleted_at       timestamptz,
  deleted_by       uuid
);
COMMENT ON TABLE consignment_item IS 'A consigned item: received, offered, sold, returned, or withdrawn.';

CREATE INDEX ix_consignment_item_agreement ON consignment_item(agreement_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_consignment_item_status    ON consignment_item(tenant_id, status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_consignment_item_sku ON consignment_item(tenant_id, sku) WHERE sku IS NOT NULL AND deleted_at IS NULL;
CREATE TRIGGER trg_consignment_item_audit
  BEFORE UPDATE ON consignment_item FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- item_price_change — effective-dated price history for an item.
-- ----------------------------------------------------------------------------
CREATE TABLE item_price_change (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id     uuid NOT NULL DEFAULT kernel.current_tenant(),
  item_id       uuid NOT NULL REFERENCES consignment_item(id) ON DELETE CASCADE,
  old_price     kernel.money_amount,
  new_price     kernel.money_amount NOT NULL CHECK (new_price >= 0),
  reason        text,
  changed_at    timestamptz NOT NULL DEFAULT now(),
  changed_by    uuid DEFAULT kernel.current_actor()
);
COMMENT ON TABLE item_price_change IS 'Price-change history for a consigned item (append-only detail).';

CREATE INDEX ix_item_price_change_item ON item_price_change(item_id);

-- ----------------------------------------------------------------------------
-- consignment_sale — a sale event (header).
-- ----------------------------------------------------------------------------
CREATE TABLE consignment_sale (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  sale_no          bigint GENERATED ALWAYS AS IDENTITY,
  sale_date        date NOT NULL DEFAULT current_date,
  channel          text NOT NULL DEFAULT 'store'
                     CHECK (channel IN ('store','online','event','other')),
  customer_party_id uuid REFERENCES party(id) ON DELETE RESTRICT,
  status           text NOT NULL DEFAULT 'completed'
                     CHECK (status IN ('completed','voided')),
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1
);
COMMENT ON TABLE consignment_sale IS 'A consignment sale header. Lines carry item, price, commission, and net-to-consignor.';

CREATE INDEX ix_consignment_sale_date ON consignment_sale(sale_date);
CREATE TRIGGER trg_consignment_sale_audit
  BEFORE UPDATE ON consignment_sale FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- consignment_sale_line — one item sold within a sale.
-- commission_amount + net_to_consignor = sale_price (exact, no rounding drift).
-- ----------------------------------------------------------------------------
CREATE TABLE consignment_sale_line (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id          uuid NOT NULL DEFAULT kernel.current_tenant(),
  sale_id            uuid NOT NULL REFERENCES consignment_sale(id) ON DELETE RESTRICT,
  item_id            uuid NOT NULL REFERENCES consignment_item(id) ON DELETE RESTRICT,
  consignor_party_id uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  sale_price         kernel.money_amount NOT NULL CHECK (sale_price >= 0),
  commission_rate    kernel.percent_rate NOT NULL CHECK (commission_rate >= 0 AND commission_rate <= 1),
  commission_amount  kernel.money_amount NOT NULL CHECK (commission_amount >= 0),
  net_to_consignor   kernel.money_amount NOT NULL CHECK (net_to_consignor >= 0),
  currency           kernel.currency_code NOT NULL DEFAULT 'USD',
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid DEFAULT kernel.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid DEFAULT kernel.current_actor(),
  version            integer NOT NULL DEFAULT 1,
  -- Exact split: commission + net must equal the sale price.
  CHECK (commission_amount + net_to_consignor = sale_price)
);
COMMENT ON TABLE consignment_sale_line IS 'A sold consignment item; commission + net_to_consignor = sale_price (exact).';

CREATE INDEX ix_consignment_sale_line_sale      ON consignment_sale_line(sale_id);
CREATE INDEX ix_consignment_sale_line_consignor ON consignment_sale_line(consignor_party_id);
CREATE TRIGGER trg_consignment_sale_line_audit
  BEFORE UPDATE ON consignment_sale_line FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- consignor_settlement — a settlement batch for a consignor over a period.
-- ----------------------------------------------------------------------------
CREATE TABLE consignor_settlement (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id          uuid NOT NULL DEFAULT kernel.current_tenant(),
  settlement_no      bigint GENERATED ALWAYS AS IDENTITY,
  consignor_party_id uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  period_start       date NOT NULL,
  period_end         date NOT NULL,
  gross_sales        kernel.money_amount NOT NULL DEFAULT 0,
  commission_total   kernel.money_amount NOT NULL DEFAULT 0,
  net_payable        kernel.money_amount NOT NULL DEFAULT 0,
  currency           kernel.currency_code NOT NULL DEFAULT 'USD',
  status             text NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft','finalized','paid','voided')),
  journal_entry_id   uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid DEFAULT kernel.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid DEFAULT kernel.current_actor(),
  version            integer NOT NULL DEFAULT 1,
  CHECK (period_end >= period_start)
);
COMMENT ON TABLE consignor_settlement IS 'A settlement batch: gross sales, commission, net payable to a consignor.';

CREATE INDEX ix_consignor_settlement_party ON consignor_settlement(consignor_party_id);
CREATE TRIGGER trg_consignor_settlement_audit
  BEFORE UPDATE ON consignor_settlement FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- settlement_line — the sale lines included in a settlement.
-- ----------------------------------------------------------------------------
CREATE TABLE settlement_line (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id       uuid NOT NULL DEFAULT kernel.current_tenant(),
  settlement_id   uuid NOT NULL REFERENCES consignor_settlement(id) ON DELETE RESTRICT,
  sale_line_id    uuid NOT NULL REFERENCES consignment_sale_line(id) ON DELETE RESTRICT,
  gross_amount    kernel.money_amount NOT NULL,
  commission_amount kernel.money_amount NOT NULL,
  net_amount      kernel.money_amount NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid DEFAULT kernel.current_actor(),
  UNIQUE (settlement_id, sale_line_id)
);
COMMENT ON TABLE settlement_line IS 'Sale lines rolled into a settlement batch.';

CREATE INDEX ix_settlement_line_settlement ON settlement_line(settlement_id);

-- ----------------------------------------------------------------------------
-- consignor_payout — the actual cash paid to a consignor for a settlement.
-- ----------------------------------------------------------------------------
CREATE TABLE consignor_payout (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  settlement_id    uuid NOT NULL REFERENCES consignor_settlement(id) ON DELETE RESTRICT,
  payout_amount    kernel.money_amount NOT NULL CHECK (payout_amount > 0),
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  payout_date      date NOT NULL DEFAULT current_date,
  method           text NOT NULL DEFAULT 'cash'
                     CHECK (method IN ('cash','check','ach','store_credit','other')),
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1
);
COMMENT ON TABLE consignor_payout IS 'Cash payout to a consignor for a settlement; links the ledger entry.';

CREATE INDEX ix_consignor_payout_settlement ON consignor_payout(settlement_id);
CREATE TRIGGER trg_consignor_payout_audit
  BEFORE UPDATE ON consignor_payout FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- View: consignor payable position (open items + running balance).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_consignor_payable AS
  SELECT oi.party_id, p.display_name AS consignor_name,
         sum(oi.open_amount) AS open_payable
    FROM open_item oi
    JOIN party p ON p.id = oi.party_id
   WHERE oi.subledger_type_code = 'consignor_payable'
     AND oi.status IN ('open','partial')
     AND oi.deleted_at IS NULL
   GROUP BY oi.party_id, p.display_name;
COMMENT ON VIEW v_consignor_payable IS 'Open consignor payable per consignor (from open items).';
