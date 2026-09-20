-- ============================================================================
-- 77_pos_inventory.sql — Bridge POS sales to owned-goods inventory.
--
-- Kept OUT of 75_pos_posting.sql deliberately: POS must remain usable without
-- inventory (services, untracked one-offs), and inventory must remain usable
-- without POS (receipts, adjustments). This file is the only place the two meet.
--
-- ADR-0028: COGS accrues AT THE MOMENT OF SALE, same as consignor payable.
-- ADR-0031: owned goods relieve at moving weighted-average cost; consigned
--           goods are never inventory-valued.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- post_sale_inventory — relieve stock + book COGS for every owned line.
--
-- Separate journal entries per line (via issue_inventory_for_sale_line) keep
-- each COGS relief individually idempotent and individually reversible.
-- Returns the number of lines relieved.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_sale_inventory(
  p_sale_id    uuid,
  p_entry_date date
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_line  record;
  v_count integer := 0;
BEGIN
  FOR v_line IN
    SELECT id FROM sale_line
     WHERE sale_id = p_sale_id
       AND line_kind = 'owned'
       AND inventory_item_id IS NOT NULL
     ORDER BY line_no
  LOOP
    PERFORM issue_inventory_for_sale_line(v_line.id, p_entry_date, NULL);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END; $$;
COMMENT ON FUNCTION post_sale_inventory IS 'Books COGS and relieves stock for the owned lines of a sale (ADR-0028/0031).';

-- ----------------------------------------------------------------------------
-- post_refund_inventory — return owned goods to stock on a refund.
--
-- Restocks at the average cost recorded on the ORIGINAL issue, not today's
-- average. Using today's average would silently revalue inventory through a
-- refund, which is a classic source of unexplained margin drift.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_refund_inventory(
  p_refund_sale_id uuid,
  p_entry_date     date
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_sale    record;
  v_line    record;
  v_orig    record;
  v_item    inventory_item;
  v_cost    numeric;
  v_new_qty numeric;
  v_entry   uuid;
  v_key     text;
  v_count   integer := 0;
BEGIN
  SELECT * INTO v_sale FROM sale WHERE id = p_refund_sale_id;
  IF NOT v_sale.is_refund THEN
    RAISE EXCEPTION 'Sale % is not a refund document', p_refund_sale_id USING ERRCODE='23514';
  END IF;

  FOR v_line IN
    SELECT * FROM sale_line
     WHERE sale_id = p_refund_sale_id
       AND line_kind = 'owned'
       AND inventory_item_id IS NOT NULL
     ORDER BY line_no
  LOOP
    v_key := 'inv_return:' || v_line.id::text;
    SELECT id INTO v_entry FROM journal_entry
      WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
    IF v_entry IS NOT NULL THEN CONTINUE; END IF;   -- already restocked

    SELECT * INTO v_item FROM inventory_item WHERE id = v_line.inventory_item_id FOR UPDATE;

    -- Recover the cost actually used when these goods left, via the original sale.
    SELECT m.unit_cost INTO v_orig
      FROM inventory_movement m
      JOIN sale_line sl ON sl.id = m.sale_line_id
     WHERE m.item_id = v_item.id
       AND m.movement_kind = 'issue'
       AND sl.sale_id = v_sale.refunds_sale_id
     ORDER BY m.id DESC LIMIT 1;

    v_cost    := round(v_line.quantity * COALESCE(v_orig.unit_cost, v_item.avg_cost), 4);
    v_new_qty := v_item.on_hand + v_line.quantity;

    IF v_cost > 0 THEN
      v_entry := post_journal_entry(
        p_entry_date, 'Restock ' || v_item.sku, 'inventory_return', v_line.id::text, v_key,
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('inventory'), 'debit',  v_cost),
          jsonb_build_object('account_id', posting_account('cogs'),      'credit', v_cost)));
    END IF;

    UPDATE inventory_item SET on_hand = v_new_qty WHERE id = v_item.id;

    INSERT INTO inventory_movement (
      item_id, movement_kind, movement_date, quantity, unit_cost, extended_cost,
      currency, on_hand_after, avg_cost_after, source, source_ref, sale_line_id, journal_entry_id, memo)
    VALUES (v_item.id,'customer_return',p_entry_date, v_line.quantity,
            COALESCE(v_orig.unit_cost, v_item.avg_cost),
            v_cost, v_item.currency, v_new_qty, v_item.avg_cost,
            'refund', v_line.id::text, v_line.id, v_entry, 'Restocked at original issue cost');

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END; $$;
COMMENT ON FUNCTION post_refund_inventory IS 'Restocks owned goods on refund at the original issue cost (avoids revaluation drift).';

-- ----------------------------------------------------------------------------
-- v_sale_margin — realtime margin per sale.
--
-- Reads the ledger and the movement history directly, so it cannot drift.
-- Consigned margin is commission earned; owned margin is price less COGS.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_sale_margin AS
SELECT s.id AS sale_id,
       s.sale_no,
       s.sale_date,
       s.total,
       COALESCE(sum(sl.extended_price) FILTER (WHERE sl.line_kind='owned'), 0)       AS owned_revenue,
       COALESCE(sum(sl.extended_price) FILTER (WHERE sl.line_kind='consignment'), 0) AS consignment_revenue,
       COALESCE(sum(sl.commission_amount) FILTER (WHERE sl.line_kind='consignment'), 0) AS commission_earned,
       COALESCE(-(SELECT sum(m.extended_cost)
                    FROM inventory_movement m
                    JOIN sale_line x ON x.id = m.sale_line_id
                   WHERE x.sale_id = s.id AND m.movement_kind='issue'), 0)           AS owned_cogs,
       COALESCE(sum(sl.extended_price) FILTER (WHERE sl.line_kind='owned'), 0)
         + COALESCE(-(SELECT sum(m.extended_cost)
                        FROM inventory_movement m
                        JOIN sale_line x ON x.id = m.sale_line_id
                       WHERE x.sale_id = s.id AND m.movement_kind='issue'), 0) * -1
         + COALESCE(sum(sl.commission_amount) FILTER (WHERE sl.line_kind='consignment'), 0) AS gross_margin
  FROM sale s
  LEFT JOIN sale_line sl ON sl.sale_id = s.id
 GROUP BY s.id, s.sale_no, s.sale_date, s.total;
COMMENT ON VIEW v_sale_margin IS 'Realtime per-sale margin: owned (price - COGS) plus consignment commission.';
