-- ============================================================================
-- 72_inventory.sql — Owned-goods inventory (ADR-0031, weighted average cost).
--
-- Consigned goods are deliberately NOT tracked here: the store holds them but
-- does not own them, so they are not a balance-sheet asset. Only `owned` stock
-- carries a cost and produces COGS.
--
-- Design:
--   * inventory_item      — the definition + current on-hand + current avg cost.
--   * inventory_movement  — APPEND-ONLY ledger of every quantity/cost change,
--                           mirroring the journal. Never edited.
--   * Average cost is recomputed on receipt and held constant on issue, which
--     is what "moving weighted average" means.
--
-- The Inventory GL control account must always equal Σ (on_hand × avg_cost).
-- That is asserted in db/tests/inventory.sql.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- inventory_item — an owned SKU.
-- ----------------------------------------------------------------------------
CREATE TABLE inventory_item (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id     uuid NOT NULL DEFAULT kernel.current_tenant(),
  sku           text NOT NULL,
  description   text NOT NULL,
  category      text,
  -- Party the goods were bought from. NULL for opening balances / found stock.
  supplier_party_id uuid REFERENCES party(id) ON DELETE RESTRICT,
  uom           text NOT NULL DEFAULT 'each',
  -- Denormalised running state. Maintained ONLY by inventory functions, and
  -- reconciled against inventory_movement by inventory_integrity_check().
  on_hand       numeric(19,4) NOT NULL DEFAULT 0,
  avg_cost      kernel.money_amount NOT NULL DEFAULT 0,
  currency      kernel.currency_code NOT NULL DEFAULT 'USD',
  reorder_point numeric(19,4),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid DEFAULT kernel.current_actor(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid DEFAULT kernel.current_actor(),
  version       integer NOT NULL DEFAULT 1,
  deleted_at    timestamptz,
  deleted_by    uuid,
  CHECK (avg_cost >= 0),
  -- Negative stock is a data-integrity failure, not a business state.
  CHECK (on_hand >= 0)
);
COMMENT ON TABLE inventory_item IS 'Owned-goods SKU with moving weighted-average cost (ADR-0031). Consigned goods are excluded.';
CREATE UNIQUE INDEX ux_inventory_item_sku ON inventory_item(tenant_id, sku) WHERE deleted_at IS NULL;
CREATE INDEX ix_inventory_item_active ON inventory_item(tenant_id, is_active) WHERE deleted_at IS NULL;
CREATE TRIGGER trg_inventory_item_audit
  BEFORE UPDATE ON inventory_item FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- Link POS lines to tracked stock. Added here rather than in 70_pos.sql so the
-- POS module stays independent of inventory: an owned line with a NULL
-- inventory_item_id is a valid untracked sale (e.g. a service or one-off).
ALTER TABLE sale_line
  ADD COLUMN IF NOT EXISTS inventory_item_id uuid REFERENCES inventory_item(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS ix_sale_line_inventory ON sale_line(inventory_item_id);
COMMENT ON COLUMN sale_line.inventory_item_id IS
  'Owned lines only. NULL = untracked (service/one-off). Consigned lines must leave this NULL (ADR-0031).';

-- Consigned goods are never inventory-valued.
ALTER TABLE sale_line DROP CONSTRAINT IF EXISTS ck_sale_line_consignment_no_inventory;
ALTER TABLE sale_line ADD CONSTRAINT ck_sale_line_consignment_no_inventory
  CHECK (line_kind <> 'consignment' OR inventory_item_id IS NULL);

-- ----------------------------------------------------------------------------
-- inventory_movement — append-only. Every change to quantity or value.
-- ----------------------------------------------------------------------------
CREATE TABLE inventory_movement (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  item_id          uuid NOT NULL REFERENCES inventory_item(id) ON DELETE RESTRICT,
  movement_kind    text NOT NULL
                     CHECK (movement_kind IN ('receipt','issue','adjustment','return_to_supplier','customer_return')),
  movement_date    date NOT NULL DEFAULT current_date,
  -- Signed: positive increases stock, negative decreases it.
  quantity         numeric(19,4) NOT NULL CHECK (quantity <> 0),
  unit_cost        kernel.money_amount NOT NULL CHECK (unit_cost >= 0),
  extended_cost    kernel.money_amount NOT NULL,
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  -- Running state AFTER this movement, so history is reconstructable.
  on_hand_after    numeric(19,4) NOT NULL,
  avg_cost_after   kernel.money_amount NOT NULL,
  source           text NOT NULL DEFAULT 'manual',
  source_ref       text,
  sale_line_id     uuid REFERENCES sale_line(id) ON DELETE RESTRICT,
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  memo             text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  -- extended_cost must equal |quantity| * unit_cost, signed with the quantity.
  CHECK (extended_cost = round(quantity * unit_cost, 4))
);
COMMENT ON TABLE inventory_movement IS 'Append-only inventory ledger. Never edited; corrections are new movements.';
CREATE INDEX ix_inventory_movement_item ON inventory_movement(item_id, movement_date);
CREATE INDEX ix_inventory_movement_entry ON inventory_movement(journal_entry_id);
CREATE INDEX ix_inventory_movement_saleline ON inventory_movement(sale_line_id);

-- Enforce append-only at the database, not by convention.
CREATE OR REPLACE FUNCTION inventory_movement_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'inventory_movement is append-only; post a correcting movement instead'
    USING ERRCODE='23514';
END; $$;
CREATE TRIGGER trg_inventory_movement_immutable
  BEFORE UPDATE OR DELETE ON inventory_movement
  FOR EACH ROW EXECUTE FUNCTION inventory_movement_immutable();

-- ----------------------------------------------------------------------------
-- receive_inventory — buy/receive stock. Recomputes weighted average cost.
--
--   new_avg = (on_hand*avg_cost + qty*unit_cost) / (on_hand + qty)
--
-- Posts: debit Inventory, credit AP control (or cash if no supplier given).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION receive_inventory(
  p_item_id         uuid,
  p_quantity        numeric,
  p_unit_cost       numeric,
  p_entry_date      date,
  p_idempotency_key text DEFAULT NULL,
  p_on_account      boolean DEFAULT true
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_item    inventory_item;
  v_ext     numeric;
  v_new_qty numeric;
  v_new_avg numeric;
  v_entry   uuid;
  v_credit  uuid;
  v_key     text;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Receipt quantity must be positive, got %', p_quantity USING ERRCODE='23514';
  END IF;
  IF p_unit_cost < 0 THEN
    RAISE EXCEPTION 'Unit cost cannot be negative, got %', p_unit_cost USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_item FROM inventory_item WHERE id = p_item_id FOR UPDATE;
  IF v_item.id IS NULL THEN
    RAISE EXCEPTION 'No inventory item %', p_item_id USING ERRCODE='23514';
  END IF;

  v_key := COALESCE(p_idempotency_key,
                    'inv_recv:' || p_item_id::text || ':' || p_entry_date::text || ':' || p_quantity::text);

  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  v_ext     := round(p_quantity * p_unit_cost, 4);
  v_new_qty := v_item.on_hand + p_quantity;
  -- Moving weighted average. Guarded against divide-by-zero.
  v_new_avg := CASE WHEN v_new_qty = 0 THEN 0
                    ELSE round(((v_item.on_hand * v_item.avg_cost) + v_ext) / v_new_qty, 4) END;

  IF p_on_account AND v_item.supplier_party_id IS NOT NULL THEN
    v_credit := posting_account('ap_control');
    v_entry := post_journal_entry(
      p_entry_date, 'Inventory receipt ' || v_item.sku, 'inventory_receipt', p_item_id::text, v_key,
      jsonb_build_array(
        jsonb_build_object('account_id', posting_account('inventory'), 'debit', v_ext),
        jsonb_build_object('account_id', v_credit, 'credit', v_ext,
                           'party_id', v_item.supplier_party_id, 'subledger_type_code','ap')));
    PERFORM open_item_create('ap', v_item.supplier_party_id, 'inventory_receipt', p_item_id::text,
                             NULL, v_ext, v_item.currency, p_entry_date, p_entry_date + 30, v_entry);
  ELSE
    v_credit := posting_account('cash');
    v_entry := post_journal_entry(
      p_entry_date, 'Inventory receipt ' || v_item.sku, 'inventory_receipt', p_item_id::text, v_key,
      jsonb_build_array(
        jsonb_build_object('account_id', posting_account('inventory'), 'debit', v_ext),
        jsonb_build_object('account_id', v_credit, 'credit', v_ext)));
  END IF;

  UPDATE inventory_item SET on_hand = v_new_qty, avg_cost = v_new_avg WHERE id = p_item_id;

  INSERT INTO inventory_movement (
    item_id, movement_kind, movement_date, quantity, unit_cost, extended_cost,
    currency, on_hand_after, avg_cost_after, source, source_ref, journal_entry_id, memo)
  VALUES (p_item_id,'receipt',p_entry_date,p_quantity,p_unit_cost,v_ext,
          v_item.currency,v_new_qty,v_new_avg,'inventory_receipt',p_item_id::text,v_entry,
          'Received ' || p_quantity || ' @ ' || p_unit_cost);

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION receive_inventory IS 'Receives owned stock and recomputes moving weighted-average cost (ADR-0031).';

-- ----------------------------------------------------------------------------
-- issue_inventory_for_sale_line — relieve stock and book COGS at the sale.
--
-- Issues at the CURRENT average cost. Debit COGS / credit Inventory.
-- Called by post_sale for owned lines; safe to call directly.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION issue_inventory_for_sale_line(
  p_sale_line_id    uuid,
  p_entry_date      date,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_line    sale_line;
  v_item    inventory_item;
  v_cost    numeric;
  v_new_qty numeric;
  v_entry   uuid;
  v_key     text;
BEGIN
  SELECT * INTO v_line FROM sale_line WHERE id = p_sale_line_id;
  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'No sale line %', p_sale_line_id USING ERRCODE='23514';
  END IF;
  IF v_line.line_kind <> 'owned' THEN
    RETURN NULL;  -- consigned goods carry no inventory value (ADR-0031)
  END IF;
  IF v_line.inventory_item_id IS NULL THEN
    RETURN NULL;  -- untracked owned line (e.g. a service); nothing to relieve
  END IF;

  SELECT * INTO v_item FROM inventory_item WHERE id = v_line.inventory_item_id FOR UPDATE;

  v_key := COALESCE(p_idempotency_key, 'inv_issue:' || p_sale_line_id::text);
  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  IF v_line.quantity > v_item.on_hand THEN
    RAISE EXCEPTION 'Cannot sell % of %; only % on hand',
      v_line.quantity, v_item.sku, v_item.on_hand USING ERRCODE='23514';
  END IF;

  v_cost    := round(v_line.quantity * v_item.avg_cost, 4);
  v_new_qty := v_item.on_hand - v_line.quantity;

  -- A zero-cost item (e.g. donated stock) produces no COGS entry, but the
  -- quantity movement is still recorded so on-hand stays accurate.
  IF v_cost > 0 THEN
    v_entry := post_journal_entry(
      p_entry_date, 'COGS ' || v_item.sku, 'inventory_issue', p_sale_line_id::text, v_key,
      jsonb_build_array(
        jsonb_build_object('account_id', posting_account('cogs'),      'debit',  v_cost),
        jsonb_build_object('account_id', posting_account('inventory'), 'credit', v_cost)));
  END IF;

  UPDATE inventory_item SET on_hand = v_new_qty WHERE id = v_item.id;

  INSERT INTO inventory_movement (
    item_id, movement_kind, movement_date, quantity, unit_cost, extended_cost,
    currency, on_hand_after, avg_cost_after, source, source_ref, sale_line_id, journal_entry_id, memo)
  VALUES (v_item.id,'issue',p_entry_date,-v_line.quantity,v_item.avg_cost,
          round(-v_line.quantity * v_item.avg_cost,4),
          v_item.currency,v_new_qty,v_item.avg_cost,'sale',p_sale_line_id::text,
          p_sale_line_id,v_entry,'COGS at average cost');

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION issue_inventory_for_sale_line IS 'Relieves owned stock at average cost and books COGS at the sale (ADR-0028/0031).';

-- ----------------------------------------------------------------------------
-- adjust_inventory — shrink, spoilage, or physical-count correction.
--
-- Positive qty increases stock at the current average cost; negative reduces it.
-- Posts the value difference to the inventory adjustment expense account.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION adjust_inventory(
  p_item_id         uuid,
  p_quantity_delta  numeric,
  p_entry_date      date,
  p_memo            text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_item    inventory_item;
  v_value   numeric;
  v_new_qty numeric;
  v_entry   uuid;
  v_key     text;
BEGIN
  IF p_quantity_delta = 0 THEN
    RAISE EXCEPTION 'Adjustment quantity cannot be zero' USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_item FROM inventory_item WHERE id = p_item_id FOR UPDATE;
  IF v_item.id IS NULL THEN
    RAISE EXCEPTION 'No inventory item %', p_item_id USING ERRCODE='23514';
  END IF;

  v_new_qty := v_item.on_hand + p_quantity_delta;
  IF v_new_qty < 0 THEN
    RAISE EXCEPTION 'Adjustment would drive % negative (% on hand, delta %)',
      v_item.sku, v_item.on_hand, p_quantity_delta USING ERRCODE='23514';
  END IF;

  v_key := COALESCE(p_idempotency_key,
                    'inv_adj:' || p_item_id::text || ':' || p_entry_date::text || ':' || p_quantity_delta::text);
  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  v_value := round(abs(p_quantity_delta) * v_item.avg_cost, 4);

  IF v_value > 0 THEN
    IF p_quantity_delta < 0 THEN
      -- Shrink: expense the loss.
      v_entry := post_journal_entry(
        p_entry_date, COALESCE(p_memo,'Inventory shrink ' || v_item.sku),
        'inventory_adjustment', p_item_id::text, v_key,
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('inventory_adjustment'),'debit', v_value),
          jsonb_build_object('account_id', posting_account('inventory'),           'credit',v_value)));
    ELSE
      -- Found stock: reduce the expense.
      v_entry := post_journal_entry(
        p_entry_date, COALESCE(p_memo,'Inventory found ' || v_item.sku),
        'inventory_adjustment', p_item_id::text, v_key,
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('inventory'),           'debit', v_value),
          jsonb_build_object('account_id', posting_account('inventory_adjustment'),'credit',v_value)));
    END IF;
  END IF;

  UPDATE inventory_item SET on_hand = v_new_qty WHERE id = p_item_id;

  INSERT INTO inventory_movement (
    item_id, movement_kind, movement_date, quantity, unit_cost, extended_cost,
    currency, on_hand_after, avg_cost_after, source, source_ref, journal_entry_id, memo)
  VALUES (p_item_id,'adjustment',p_entry_date,p_quantity_delta,v_item.avg_cost,
          round(p_quantity_delta * v_item.avg_cost,4),
          v_item.currency,v_new_qty,v_item.avg_cost,'inventory_adjustment',p_item_id::text,v_entry,p_memo);

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION adjust_inventory IS 'Shrink/found-stock adjustment at average cost, expensed to inventory_adjustment.';

-- ----------------------------------------------------------------------------
-- inventory_value_check — Σ(on_hand × avg_cost) vs the Inventory GL account.
-- The core invariant for this module. Must be 0.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventory_value_check()
RETURNS TABLE (inventory_total numeric, gl_total numeric, difference numeric)
LANGUAGE sql STABLE AS $$
  WITH inv AS (
    SELECT COALESCE(sum(round(on_hand * avg_cost, 4)), 0) AS total
      FROM inventory_item WHERE deleted_at IS NULL
  ),
  gl AS (
    SELECT COALESCE(sum(jl.base_debit - jl.base_credit), 0) AS total
      FROM journal_line jl
     WHERE jl.account_id = posting_account('inventory')
  )
  SELECT inv.total, gl.total, inv.total - gl.total FROM inv, gl;
$$;
COMMENT ON FUNCTION inventory_value_check IS 'Invariant: Σ(on_hand × avg_cost) must equal the Inventory control account (difference = 0).';

-- ----------------------------------------------------------------------------
-- inventory_integrity_check — does the denormalised on_hand match the ledger?
-- Guards against any path that mutates inventory_item without a movement.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventory_integrity_check()
RETURNS TABLE (item_id uuid, sku text, item_on_hand numeric, movement_on_hand numeric, difference numeric)
LANGUAGE sql STABLE AS $$
  SELECT i.id, i.sku, i.on_hand,
         COALESCE(m.qty, 0),
         i.on_hand - COALESCE(m.qty, 0)
    FROM inventory_item i
    LEFT JOIN (SELECT item_id, sum(quantity) AS qty FROM inventory_movement GROUP BY item_id) m
           ON m.item_id = i.id
   WHERE i.deleted_at IS NULL
     AND i.on_hand - COALESCE(m.qty, 0) <> 0;
$$;
COMMENT ON FUNCTION inventory_integrity_check IS 'Returns rows only when inventory_item.on_hand disagrees with Σ movements. Empty = healthy.';
