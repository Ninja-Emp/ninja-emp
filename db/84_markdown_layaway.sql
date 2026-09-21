-- ============================================================================
-- Ninja EMP — 84_markdown_layaway.sql  (TENANT-SCOPED)
--
-- Two retail mechanics that are usually implemented badly, and both of which
-- are really accounting questions wearing a merchandising costume.
--
-- ---------------------------------------------------------------------------
-- 1. MARKDOWNS  (ADR-0036)
--
-- The lazy implementation is to UPDATE the price on the item and move on. That
-- destroys the only number that makes a consignment or vendor-mall business
-- legible: how much margin was deliberately given away, and by whom.
--
-- It also breaks the consignor relationship. A consignor agreed to a price. If
-- the store discounts below it, SOMEONE absorbs the difference, and which one
-- is a contractual question with a real cash consequence:
--
--   'store'     — the store eats it. The consignor is still settled on the
--                 agreed price. Markdown is a store expense (contra-revenue).
--   'consignor' — the consignor eats it. Their net is computed on the reduced
--                 price. No store expense.
--   'shared'    — split by share_store_rate.
--
-- Storing that per markdown, rather than assuming, is the whole point. Most
-- systems assume 'consignor' silently and generate disputes the store cannot
-- defend because it has no record of who agreed to what.
--
-- Markdowns are recorded as EVENTS, not as price overwrites. The current price
-- is derived. History is never lost.
--
-- ---------------------------------------------------------------------------
-- 2. LAYAWAY  (ADR-0036)
--
-- A layaway deposit is NOT revenue. The customer has paid money, the store has
-- not delivered goods, and the customer can usually walk away. Until pickup it
-- is a LIABILITY. Recognising it as revenue on receipt overstates income,
-- overstates tax, and — in the states that regulate layaway — is simply
-- unlawful.
--
-- So: deposits credit a layaway liability. At pickup the liability is
-- extinguished and the sale is recognised. On cancellation the liability is
-- extinguished too, but split between cash refunded and any forfeited fee,
-- which IS income.
--
-- Goods on layaway are RESERVED, not sold. They must not be sellable twice.
--
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ============================================================================
-- PART 1 — MARKDOWNS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- markdown_reason — why the price was cut. A lookup, because "why" drives
-- real decisions (damaged goods are a supplier conversation; aged stock is a
-- buying conversation) and free text makes that unanswerable.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS markdown_reason (
  tenant_id   uuid NOT NULL DEFAULT kernel.current_tenant(),
  code        text NOT NULL,
  name        text NOT NULL,
  description text,
  -- Whether this reason, by default, is the store's cost or the consignor's.
  default_absorbed_by text NOT NULL DEFAULT 'store'
    CHECK (default_absorbed_by IN ('store','consignor','shared')),
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, code)
);
COMMENT ON TABLE markdown_reason IS
  'Why a price was reduced, and who absorbs it by default. Drives buying and supplier decisions.';

INSERT INTO markdown_reason (code, name, default_absorbed_by, description) VALUES
  ('aged',        'Aged Stock',        'consignor',
   'Item has passed its agreed ageing window; consignor agreed to automatic reduction.'),
  ('damaged',     'Damaged',           'consignor',
   'Condition is worse than declared at intake.'),
  ('promotion',   'Store Promotion',   'store',
   'Store-initiated sale event. The store chose this, so the store pays for it.'),
  ('price_match', 'Price Match',       'store',
   'Matched a competitor price to close the sale.'),
  ('clearance',   'Clearance',         'shared',
   'End-of-life clearance, typically split by agreement.'),
  ('negotiated',  'Negotiated at Sale','store',
   'Floor-level haggling. Tracked so it can be measured, and capped.')
ON CONFLICT (tenant_id, code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- markdown_event — one deliberate price reduction.
--
-- Append-only. A markdown is a decision someone made on a date; correcting it
-- means a new event, not editing away the evidence. Same discipline as the
-- ledger (reversal-not-edit), for the same reason: disputes are settled by
-- history, and history you can overwrite settles nothing.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS markdown_event (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),

  -- Exactly one target: a consigned item or an owned inventory item.
  consignment_item_id uuid REFERENCES consignment_item(id) ON DELETE RESTRICT,
  inventory_item_id   uuid REFERENCES inventory_item(id)   ON DELETE RESTRICT,

  reason_code         text NOT NULL,
  old_price           kernel.money_amount NOT NULL CHECK (old_price >= 0),
  new_price           kernel.money_amount NOT NULL CHECK (new_price >= 0),
  currency            kernel.currency_code NOT NULL DEFAULT 'USD',

  -- Who absorbs the reduction, and in what proportion.
  absorbed_by         text NOT NULL DEFAULT 'store'
                        CHECK (absorbed_by IN ('store','consignor','shared')),
  share_store_rate    kernel.percent_rate,

  effective_from      date NOT NULL DEFAULT current_date,
  effective_thru      date,
  approved_by         uuid,
  note                text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),

  FOREIGN KEY (tenant_id, reason_code) REFERENCES markdown_reason(tenant_id, code),
  -- Exactly one target, never both, never neither.
  CHECK ( (consignment_item_id IS NOT NULL) <> (inventory_item_id IS NOT NULL) ),
  -- A markdown goes DOWN. A price increase is not a markdown and must not be
  -- smuggled through this table to dodge the approval trail.
  CHECK (new_price < old_price),
  -- 'shared' is meaningless without the split; the others must not carry one.
  CHECK ( (absorbed_by = 'shared' AND share_store_rate IS NOT NULL
             AND share_store_rate > 0 AND share_store_rate < 1)
       OR (absorbed_by <> 'shared' AND share_store_rate IS NULL) ),
  CHECK (effective_thru IS NULL OR effective_thru >= effective_from)
);
COMMENT ON TABLE markdown_event IS
  'Append-only record of deliberate price reductions, including who absorbs the cost (ADR-0036).';

CREATE INDEX IF NOT EXISTS ix_markdown_event_citem
  ON markdown_event (consignment_item_id) WHERE consignment_item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_markdown_event_iitem
  ON markdown_event (inventory_item_id) WHERE inventory_item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_markdown_event_effective
  ON markdown_event (tenant_id, effective_from);

DROP TRIGGER IF EXISTS trg_markdown_event_append_only ON markdown_event;
CREATE TRIGGER trg_markdown_event_append_only
  BEFORE UPDATE OR DELETE ON markdown_event
  FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();

-- ----------------------------------------------------------------------------
-- apply_markdown — record a reduction and move the item's effective price.
--
-- Writes the markdown_event AND the item_price_change history row, so the
-- existing price-history mechanism stays the single place to ask "what was
-- this priced at on date X".
--
-- No journal entry is posted here, deliberately. Marking an item down is not
-- an economic event for a consignment store: nothing has been bought, sold or
-- paid. The margin consequence lands when the item SELLS, and it lands via
-- the commission split. Posting a markdown expense at markdown time would
-- create an expense for goods that may never sell, and would double-count
-- against the lower revenue actually recognised at sale.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_markdown(
  p_consignment_item_id uuid,
  p_new_price           kernel.money_amount,
  p_reason_code         text,
  p_absorbed_by         text DEFAULT NULL,
  p_share_store_rate    kernel.percent_rate DEFAULT NULL,
  p_effective_from      date DEFAULT current_date,
  p_note                text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_item     record;
  v_reason   record;
  v_absorb   text;
  v_share    kernel.percent_rate;
  v_id       uuid;
BEGIN
  SELECT * INTO v_item FROM consignment_item WHERE id = p_consignment_item_id;
  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Consignment item % not found', p_consignment_item_id USING ERRCODE='23503';
  END IF;
  IF v_item.status NOT IN ('received','available') THEN
    RAISE EXCEPTION 'Item % is % and cannot be marked down', p_consignment_item_id, v_item.status
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_reason FROM markdown_reason
   WHERE code = p_reason_code AND tenant_id = kernel.current_tenant();
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Unknown markdown reason %', p_reason_code USING ERRCODE='23503';
  END IF;

  -- Fall back to the reason's default rather than forcing every caller to
  -- restate policy. The stored value is still explicit on the row.
  v_absorb := COALESCE(p_absorbed_by, v_reason.default_absorbed_by);
  v_share  := CASE WHEN v_absorb = 'shared' THEN COALESCE(p_share_store_rate, 0.5) ELSE NULL END;

  IF p_new_price >= v_item.agreed_price THEN
    RAISE EXCEPTION 'Markdown to % is not below the current price % on item %',
      p_new_price, v_item.agreed_price, p_consignment_item_id USING ERRCODE='23514';
  END IF;

  INSERT INTO markdown_event (
    consignment_item_id, reason_code, old_price, new_price, currency,
    absorbed_by, share_store_rate, effective_from, note
  ) VALUES (
    p_consignment_item_id, p_reason_code, v_item.agreed_price, p_new_price, v_item.currency,
    v_absorb, v_share, p_effective_from, p_note
  ) RETURNING id INTO v_id;

  -- Keep the existing price-history mechanism authoritative.
  INSERT INTO item_price_change (item_id, old_price, new_price, reason)
  VALUES (p_consignment_item_id, v_item.agreed_price, p_new_price,
          'markdown:' || p_reason_code);

  UPDATE consignment_item
     SET agreed_price = p_new_price
   WHERE id = p_consignment_item_id;

  RETURN v_id;
END; $$;
COMMENT ON FUNCTION apply_markdown IS
  'Records a markdown event + price history and moves the item price. Posts no journal entry (ADR-0036).';

-- ----------------------------------------------------------------------------
-- markdown_absorption — how a sold item''s total markdown splits.
--
-- This is the number that settles consignor disputes: original ticket, what it
-- actually sold for, and how the gap was shared.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION markdown_absorption(p_consignment_item_id uuid)
RETURNS TABLE (
  original_price   numeric,
  current_price    numeric,
  total_markdown   numeric,
  store_absorbed   numeric,
  consignor_absorbed numeric
)
LANGUAGE sql STABLE AS $$
  WITH ev AS (
    SELECT old_price, new_price, absorbed_by, share_store_rate,
           (old_price - new_price) AS gap
      FROM markdown_event
     WHERE consignment_item_id = p_consignment_item_id
  )
  SELECT
    COALESCE((SELECT max(old_price) FROM ev), ci.agreed_price)::numeric,
    ci.agreed_price::numeric,
    COALESCE((SELECT sum(gap) FROM ev), 0)::numeric,
    COALESCE((SELECT sum(CASE absorbed_by
                           WHEN 'store'  THEN gap
                           WHEN 'shared' THEN round(gap * share_store_rate, 4)
                           ELSE 0 END) FROM ev), 0)::numeric,
    COALESCE((SELECT sum(CASE absorbed_by
                           WHEN 'consignor' THEN gap
                           WHEN 'shared'    THEN gap - round(gap * share_store_rate, 4)
                           ELSE 0 END) FROM ev), 0)::numeric
    FROM consignment_item ci
   WHERE ci.id = p_consignment_item_id;
$$;
COMMENT ON FUNCTION markdown_absorption IS
  'Original vs current price for an item and how the reduction split between store and consignor.';

-- ----------------------------------------------------------------------------
-- consignor_price_floor — the price the consignor is settled on.
--
-- When the store absorbs a markdown, the consignor is still owed their share
-- of the ORIGINAL price. This returns the price the settlement must use, which
-- is the sale price plus anything the store agreed to eat.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION consignor_price_floor(p_consignment_item_id uuid)
RETURNS kernel.money_amount
LANGUAGE sql STABLE AS $$
  SELECT (ci.agreed_price + COALESCE((
           SELECT sum(CASE absorbed_by
                        WHEN 'store'  THEN (old_price - new_price)
                        WHEN 'shared' THEN round((old_price - new_price) * share_store_rate, 4)
                        ELSE 0 END)
             FROM markdown_event me
            WHERE me.consignment_item_id = p_consignment_item_id), 0))::kernel.money_amount
    FROM consignment_item ci
   WHERE ci.id = p_consignment_item_id;
$$;
COMMENT ON FUNCTION consignor_price_floor IS
  'Price the consignor is settled on: sale price plus any reduction the store agreed to absorb.';

-- ============================================================================
-- PART 2 — LAYAWAY
-- ============================================================================

-- ----------------------------------------------------------------------------
-- layaway — a customer order held against staged payments.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS layaway (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id          uuid NOT NULL DEFAULT kernel.current_tenant(),
  layaway_no         bigint GENERATED ALWAYS AS IDENTITY,
  customer_party_id  uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,

  opened_date        date NOT NULL DEFAULT current_date,
  due_date           date,

  -- Derived from lines; maintained by the layaway functions.
  goods_total        kernel.money_amount NOT NULL DEFAULT 0 CHECK (goods_total >= 0),
  tax_total          kernel.money_amount NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  total              kernel.money_amount NOT NULL DEFAULT 0 CHECK (total >= 0),
  paid_total         kernel.money_amount NOT NULL DEFAULT 0 CHECK (paid_total >= 0),
  currency           kernel.currency_code NOT NULL DEFAULT 'USD',

  -- Cancellation fee the store retains. Legislated in several states, so it
  -- is per-layaway data, not a hard-coded constant.
  cancellation_fee   kernel.money_amount NOT NULL DEFAULT 0 CHECK (cancellation_fee >= 0),

  status             text NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open','completed','cancelled','defaulted')),

  -- Set when the goods are handed over and the sale is recognised.
  sale_id            uuid REFERENCES sale(id) ON DELETE RESTRICT,
  closed_date        date,

  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid DEFAULT kernel.current_actor(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid DEFAULT kernel.current_actor(),
  version            integer NOT NULL DEFAULT 1,

  CHECK (total = goods_total + tax_total),
  -- Never collect more than the order is worth.
  CHECK (paid_total <= total),
  -- A closed layaway must say when, and a completed one must point at its sale.
  CHECK (status = 'open' OR closed_date IS NOT NULL),
  CHECK (status <> 'completed' OR sale_id IS NOT NULL)
);
COMMENT ON TABLE layaway IS
  'Customer layaway order. Deposits are a LIABILITY until pickup, never revenue (ADR-0036).';

CREATE INDEX IF NOT EXISTS ix_layaway_customer ON layaway (customer_party_id);
CREATE INDEX IF NOT EXISTS ix_layaway_status   ON layaway (tenant_id, status);
CREATE TRIGGER trg_layaway_audit
  BEFORE UPDATE ON layaway FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- layaway_line — the reserved goods.
--
-- A consigned item on layaway is RESERVED: it is off the floor but not sold.
-- The partial unique index below is what actually prevents selling it twice.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS layaway_line (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  layaway_id          uuid NOT NULL REFERENCES layaway(id) ON DELETE CASCADE,
  line_no             integer NOT NULL,

  consignment_item_id uuid REFERENCES consignment_item(id) ON DELETE RESTRICT,
  inventory_item_id   uuid REFERENCES inventory_item(id)   ON DELETE RESTRICT,

  description         text NOT NULL,
  quantity            kernel.quantity NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price          kernel.money_amount NOT NULL CHECK (unit_price >= 0),
  extended_price      kernel.money_amount NOT NULL CHECK (extended_price >= 0),
  currency            kernel.currency_code NOT NULL DEFAULT 'USD',
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),

  UNIQUE (layaway_id, line_no),
  CHECK (extended_price = quantity * unit_price),
  CHECK ( (consignment_item_id IS NOT NULL) <> (inventory_item_id IS NOT NULL) )
);
COMMENT ON TABLE layaway_line IS 'Goods reserved against a layaway. Reserved is not sold.';

CREATE INDEX IF NOT EXISTS ix_layaway_line_layaway ON layaway_line (layaway_id);

-- A unique consigned item can be on at most ONE OPEN layaway at a time.
-- Without this, two customers pay deposits on the same one-of-a-kind item and
-- the store finds out at pickup.
--
-- The predicate must be scoped to OPEN layaways. A plain unique index on
-- consignment_item_id would also block the item forever after a CANCELLED
-- layaway -- the goods are back on the floor but could never be reserved
-- again. Postgres will not allow a subquery in a partial index predicate, so
-- the open-only scope is enforced by trigger instead.
CREATE OR REPLACE FUNCTION assert_layaway_item_free() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.consignment_item_id IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (
    SELECT 1
      FROM layaway_line ll
      JOIN layaway l ON l.id = ll.layaway_id
     WHERE ll.consignment_item_id = NEW.consignment_item_id
       AND ll.id <> NEW.id
       AND l.status = 'open'
  ) THEN
    RAISE EXCEPTION 'Consignment item % is already on an open layaway', NEW.consignment_item_id
      USING ERRCODE='23505';
  END IF;
  RETURN NEW;
END; $$;
COMMENT ON FUNCTION assert_layaway_item_free IS
  'Prevents the same consigned item being reserved on two open layaways. Cancelled layaways free it.';

DROP TRIGGER IF EXISTS trg_layaway_line_item_free ON layaway_line;
CREATE TRIGGER trg_layaway_line_item_free
  BEFORE INSERT OR UPDATE ON layaway_line
  FOR EACH ROW EXECUTE FUNCTION assert_layaway_item_free();

-- ----------------------------------------------------------------------------
-- layaway_payment — staged customer payments.
--
-- Append-only and journal-linked. This is cash the store is holding on trust;
-- an editable record of it is not acceptable.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS layaway_payment (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  layaway_id       uuid NOT NULL REFERENCES layaway(id) ON DELETE RESTRICT,
  payment_date     date NOT NULL DEFAULT current_date,
  amount           kernel.money_amount NOT NULL CHECK (amount <> 0),
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  tender_type_code text,
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  idempotency_key  text,
  note             text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor()
);
COMMENT ON TABLE layaway_payment IS
  'Append-only staged payments against a layaway. Negative amounts are refunds.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_layaway_payment_idem
  ON layaway_payment (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_layaway_payment_layaway ON layaway_payment (layaway_id);

DROP TRIGGER IF EXISTS trg_layaway_payment_append_only ON layaway_payment;
CREATE TRIGGER trg_layaway_payment_append_only
  BEFORE UPDATE OR DELETE ON layaway_payment
  FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();

-- ----------------------------------------------------------------------------
-- open_layaway — create the order and reserve the goods.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION open_layaway(
  p_customer_party_id uuid,
  p_lines             jsonb,
  p_due_date          date DEFAULT NULL,
  p_cancellation_fee  kernel.money_amount DEFAULT 0,
  p_opened_date       date DEFAULT current_date
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id    uuid;
  v_line  jsonb;
  v_no    integer := 0;
  v_ccy   kernel.currency_code;
  v_goods kernel.money_amount := 0;
  v_ext   kernel.money_amount;
  v_citem uuid;
  v_stat  text;
BEGIN
  IF jsonb_array_length(COALESCE(p_lines,'[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'A layaway must reserve at least one item' USING ERRCODE='23514';
  END IF;

  v_ccy := (SELECT functional_currency FROM tenant_config LIMIT 1);

  INSERT INTO layaway (customer_party_id, opened_date, due_date,
                       cancellation_fee, currency)
  VALUES (p_customer_party_id, p_opened_date, p_due_date,
          COALESCE(p_cancellation_fee,0), v_ccy)
  RETURNING id INTO v_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_no  := v_no + 1;
    v_ext := round(COALESCE((v_line->>'quantity')::numeric,1)
                   * (v_line->>'unit_price')::numeric, 4);
    v_citem := NULLIF(v_line->>'consignment_item_id','')::uuid;

    -- Reserve the consigned item: it must be available, and it comes off the
    -- floor immediately so it cannot also be sold at the register.
    IF v_citem IS NOT NULL THEN
      SELECT status INTO v_stat FROM consignment_item WHERE id = v_citem FOR UPDATE;
      IF v_stat IS NULL THEN
        RAISE EXCEPTION 'Consignment item % not found', v_citem USING ERRCODE='23503';
      END IF;
      IF v_stat NOT IN ('received','available') THEN
        RAISE EXCEPTION 'Consignment item % is % and cannot be put on layaway', v_citem, v_stat
          USING ERRCODE='23514';
      END IF;
      UPDATE consignment_item SET status = 'reserved' WHERE id = v_citem;
    END IF;

    INSERT INTO layaway_line (
      layaway_id, line_no, consignment_item_id, inventory_item_id,
      description, quantity, unit_price, extended_price, currency
    ) VALUES (
      v_id, v_no, v_citem, NULLIF(v_line->>'inventory_item_id','')::uuid,
      v_line->>'description',
      COALESCE((v_line->>'quantity')::kernel.quantity, 1),
      (v_line->>'unit_price')::kernel.money_amount,
      v_ext, v_ccy
    );
    v_goods := v_goods + v_ext;
  END LOOP;

  UPDATE layaway
     SET goods_total = v_goods,
         total       = v_goods + tax_total
   WHERE id = v_id;

  RETURN v_id;
END; $$;
COMMENT ON FUNCTION open_layaway IS
  'Opens a layaway and RESERVES the consigned items so they cannot be sold twice.';

-- ----------------------------------------------------------------------------
-- post_layaway_payment — take a deposit.
--
--   debit  cash                      (money in)
--   credit layaway_deposit_control   (a liability, NOT revenue)
--
-- This is the crux of ADR-0036. The store has the customer's money and owes
-- them either goods or a refund.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_layaway_payment(
  p_layaway_id      uuid,
  p_amount          kernel.money_amount,
  p_payment_date    date,
  p_idempotency_key text,
  p_tender_type     text DEFAULT 'cash'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_lay   record;
  v_ccy   kernel.currency_code;
  v_entry uuid;
  v_lines jsonb;
BEGIN
  SELECT * INTO v_lay FROM layaway WHERE id = p_layaway_id FOR UPDATE;
  IF v_lay IS NULL THEN
    RAISE EXCEPTION 'Layaway % not found', p_layaway_id USING ERRCODE='23503';
  END IF;
  IF v_lay.status <> 'open' THEN
    RAISE EXCEPTION 'Layaway % is % and cannot take payments', p_layaway_id, v_lay.status
      USING ERRCODE='23514';
  END IF;
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Layaway payment must be positive (got %)', p_amount USING ERRCODE='23514';
  END IF;
  IF v_lay.paid_total + p_amount > v_lay.total THEN
    RAISE EXCEPTION 'Payment of % would overpay layaway % (paid %, total %)',
      p_amount, p_layaway_id, v_lay.paid_total, v_lay.total USING ERRCODE='23514';
  END IF;

  v_ccy := v_lay.currency;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('cash'),
                       'debit', p_amount, 'currency', v_ccy,
                       'memo', 'Layaway deposit ' || v_lay.layaway_no),
    jsonb_build_object('account_id', posting_account('layaway_deposit_control'),
                       'credit', p_amount, 'currency', v_ccy,
                       'party_id', v_lay.customer_party_id,
                       'subledger_type_code', 'layaway_deposit',
                       'memo', 'Layaway deposit ' || v_lay.layaway_no)
  );

  v_entry := post_journal_entry(
    p_payment_date, 'Layaway deposit ' || v_lay.layaway_no,
    'layaway', p_layaway_id::text, p_idempotency_key, v_lines);

  -- Guard the append-only payment row against a replayed idempotency key.
  IF NOT EXISTS (SELECT 1 FROM layaway_payment
                  WHERE idempotency_key = p_idempotency_key
                    AND idempotency_key IS NOT NULL) THEN
    INSERT INTO layaway_payment (layaway_id, payment_date, amount, currency,
                                 tender_type_code, journal_entry_id, idempotency_key)
    VALUES (p_layaway_id, p_payment_date, p_amount, v_ccy,
            p_tender_type, v_entry, p_idempotency_key);

    UPDATE layaway SET paid_total = paid_total + p_amount WHERE id = p_layaway_id;
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_layaway_payment IS
  'Idempotent layaway deposit: debit cash / credit layaway liability. Never revenue (ADR-0036).';

-- ----------------------------------------------------------------------------
-- complete_layaway — customer pays it off and collects the goods.
--
-- NOW the sale is recognised. The liability built up by the deposits is
-- extinguished against it:
--
--   debit  layaway_deposit_control   (release the whole liability)
--   credit sales_revenue             (recognise the sale)
--
-- Cash is NOT touched here: it came in at deposit time. Recognising revenue
-- and cash together at pickup would double-count the cash.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION complete_layaway(
  p_layaway_id      uuid,
  p_pickup_date     date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_lay   record;
  v_entry uuid;
  v_lines jsonb;
  v_sale  uuid;
  v_line  record;
  v_no    integer := 0;
BEGIN
  SELECT * INTO v_lay FROM layaway WHERE id = p_layaway_id FOR UPDATE;
  IF v_lay IS NULL THEN
    RAISE EXCEPTION 'Layaway % not found', p_layaway_id USING ERRCODE='23503';
  END IF;
  IF v_lay.status = 'completed' THEN
    RETURN (SELECT journal_entry_id FROM sale WHERE id = v_lay.sale_id);
  END IF;
  IF v_lay.status <> 'open' THEN
    RAISE EXCEPTION 'Layaway % is % and cannot be completed', p_layaway_id, v_lay.status
      USING ERRCODE='23514';
  END IF;
  IF v_lay.paid_total < v_lay.total THEN
    RAISE EXCEPTION 'Layaway % is not paid in full (paid %, total %)',
      p_layaway_id, v_lay.paid_total, v_lay.total USING ERRCODE='23514';
  END IF;

  -- Recognise the sale document. Tender is already collected, so the sale
  -- exists to record WHAT was sold; the cash leg happened at deposit time.
  INSERT INTO sale (customer_party_id, sale_date, channel,
                    subtotal, discount_total, tax_total, total, currency, status)
  VALUES (v_lay.customer_party_id, p_pickup_date, 'in_store',
          v_lay.goods_total, 0, v_lay.tax_total, v_lay.total, v_lay.currency, 'completed')
  RETURNING id INTO v_sale;

  FOR v_line IN SELECT * FROM layaway_line WHERE layaway_id = p_layaway_id ORDER BY line_no LOOP
    v_no := v_no + 1;
    INSERT INTO sale_line (
      sale_id, line_no, line_kind, consignment_item_id, consignor_party_id,
      description, quantity, unit_price, discount_amount, extended_price,
      commission_amount, net_to_consignor, unit_cost, is_taxable, currency
    )
    SELECT v_sale, v_no,
           CASE WHEN v_line.consignment_item_id IS NOT NULL THEN 'consignment' ELSE 'owned' END,
           v_line.consignment_item_id,
           ca.consignor_party_id,
           v_line.description, v_line.quantity, v_line.unit_price, 0, v_line.extended_price,
           -- Commission split is resolved by the consignment settlement path;
           -- at pickup the whole extended price is provisionally the
           -- consignor's, and settlement applies the rule. For owned goods
           -- there is no split at all.
           CASE WHEN v_line.consignment_item_id IS NOT NULL THEN 0 ELSE 0 END,
           CASE WHEN v_line.consignment_item_id IS NOT NULL THEN v_line.extended_price ELSE 0 END,
           NULL, false, v_line.currency
      FROM (SELECT 1) _
      LEFT JOIN consignment_item ci ON ci.id = v_line.consignment_item_id
      LEFT JOIN consignor_agreement ca ON ca.id = ci.agreement_id;

    IF v_line.consignment_item_id IS NOT NULL THEN
      UPDATE consignment_item SET status = 'sold' WHERE id = v_line.consignment_item_id;
    END IF;
  END LOOP;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('layaway_deposit_control'),
                       'debit', v_lay.total, 'currency', v_lay.currency,
                       'party_id', v_lay.customer_party_id,
                       'subledger_type_code', 'layaway_deposit',
                       'memo', 'Layaway pickup ' || v_lay.layaway_no),
    jsonb_build_object('account_id', posting_account('sales_revenue'),
                       'credit', v_lay.total, 'currency', v_lay.currency,
                       'memo', 'Layaway pickup ' || v_lay.layaway_no)
  );

  v_entry := post_journal_entry(
    p_pickup_date, 'Layaway pickup ' || v_lay.layaway_no,
    'layaway', p_layaway_id::text, p_idempotency_key, v_lines);

  UPDATE sale SET journal_entry_id = v_entry WHERE id = v_sale;

  UPDATE layaway
     SET status = 'completed', sale_id = v_sale, closed_date = p_pickup_date
   WHERE id = p_layaway_id;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION complete_layaway IS
  'Pickup: releases the layaway liability into revenue and creates the sale. Cash was taken at deposit time.';

-- ----------------------------------------------------------------------------
-- cancel_layaway — customer walks away.
--
--   debit  layaway_deposit_control  (release the whole liability)
--   credit cash                     (refund)
--   credit other_income             (forfeited fee, if any)
--
-- The fee IS income: the store earned it by holding goods off the floor. The
-- refund is not. Splitting them is the difference between a defensible number
-- and a guess. The reserved items go back on the floor.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_layaway(
  p_layaway_id      uuid,
  p_cancel_date     date,
  p_idempotency_key text,
  p_fee_override    kernel.money_amount DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_lay    record;
  v_fee    kernel.money_amount;
  v_refund kernel.money_amount;
  v_entry  uuid;
  v_lines  jsonb;
BEGIN
  SELECT * INTO v_lay FROM layaway WHERE id = p_layaway_id FOR UPDATE;
  IF v_lay IS NULL THEN
    RAISE EXCEPTION 'Layaway % not found', p_layaway_id USING ERRCODE='23503';
  END IF;
  IF v_lay.status <> 'open' THEN
    RAISE EXCEPTION 'Layaway % is % and cannot be cancelled', p_layaway_id, v_lay.status
      USING ERRCODE='23514';
  END IF;

  v_fee := COALESCE(p_fee_override, v_lay.cancellation_fee);
  -- Never keep more than the customer actually paid.
  v_fee := LEAST(v_fee, v_lay.paid_total);
  v_refund := v_lay.paid_total - v_fee;

  IF v_lay.paid_total = 0 THEN
    -- Nothing was ever collected, so there is no liability to unwind and no
    -- journal entry to post. Release the goods and close it.
    UPDATE consignment_item ci SET status = 'available'
      FROM layaway_line ll
     WHERE ll.layaway_id = p_layaway_id
       AND ci.id = ll.consignment_item_id
       AND ci.status = 'reserved';
    UPDATE layaway SET status = 'cancelled', closed_date = p_cancel_date
     WHERE id = p_layaway_id;
    RETURN NULL;
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('layaway_deposit_control'),
                       'debit', v_lay.paid_total, 'currency', v_lay.currency,
                       'party_id', v_lay.customer_party_id,
                       'subledger_type_code', 'layaway_deposit',
                       'memo', 'Layaway cancellation ' || v_lay.layaway_no)
  );

  IF v_refund > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('cash'),
      'credit', v_refund, 'currency', v_lay.currency,
      'memo', 'Layaway refund ' || v_lay.layaway_no);
  END IF;

  IF v_fee > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('other_income'),
      'credit', v_fee, 'currency', v_lay.currency,
      'memo', 'Layaway cancellation fee ' || v_lay.layaway_no);
  END IF;

  v_entry := post_journal_entry(
    p_cancel_date, 'Layaway cancellation ' || v_lay.layaway_no,
    'layaway', p_layaway_id::text, p_idempotency_key, v_lines);

  -- Record the refund as a negative payment so paid_total and the ledger agree.
  IF v_refund > 0 THEN
    INSERT INTO layaway_payment (layaway_id, payment_date, amount, currency,
                                 journal_entry_id, note)
    VALUES (p_layaway_id, p_cancel_date, -v_refund, v_lay.currency, v_entry,
            'Cancellation refund');
  END IF;

  -- Goods go back on the floor.
  UPDATE consignment_item ci SET status = 'available'
    FROM layaway_line ll
   WHERE ll.layaway_id = p_layaway_id
     AND ci.id = ll.consignment_item_id
     AND ci.status = 'reserved';

  UPDATE layaway
     SET status = 'cancelled', closed_date = p_cancel_date,
         paid_total = paid_total - v_refund
   WHERE id = p_layaway_id;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION cancel_layaway IS
  'Cancellation: unwinds the liability, refunds cash, recognises any forfeited fee as income, frees the goods.';

-- ----------------------------------------------------------------------------
-- layaway_liability_check — the layaway control account must equal the sum of
-- open layaway balances. Same discipline as subledger_control_check().
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION layaway_liability_check()
RETURNS TABLE (layaway_total numeric, control_total numeric, difference numeric)
LANGUAGE sql STABLE AS $$
  WITH lay AS (
    SELECT COALESCE(sum(paid_total), 0) AS total
      FROM layaway WHERE status = 'open'
  ),
  ctl AS (
    SELECT COALESCE(sum(jl.base_credit - jl.base_debit), 0) AS total
      FROM journal_line jl
      JOIN account a ON a.id = jl.account_id
     WHERE a.id = posting_account('layaway_deposit_control')
  )
  SELECT lay.total, ctl.total, (lay.total - ctl.total) FROM lay, ctl;
$$;
COMMENT ON FUNCTION layaway_liability_check IS
  'Open layaway deposits vs the layaway control account. Difference must be zero.';

-- ----------------------------------------------------------------------------
-- v_layaway_aging — what is overdue, and how much is at risk.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_layaway_aging AS
  SELECT l.id,
         l.layaway_no,
         p.display_name AS customer_name,
         l.opened_date,
         l.due_date,
         l.total,
         l.paid_total,
         (l.total - l.paid_total) AS balance_due,
         CASE WHEN l.due_date IS NULL THEN NULL
              ELSE (current_date - l.due_date) END AS days_overdue,
         l.status
    FROM layaway l
    JOIN party p ON p.id = l.customer_party_id
   WHERE l.status = 'open'
   ORDER BY l.due_date NULLS LAST, l.opened_date;
COMMENT ON VIEW v_layaway_aging IS 'Open layaways with balance due and days overdue.';
