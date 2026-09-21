-- ============================================================================
-- 0006_item_price_barcode.sql
--
-- GAP FILL. The tenant UI (POS + inventory) needs two things the schema never
-- carried on an item:
--
--   1. a RETAIL PRICE for owned stock. inventory_item tracks cost (avg_cost,
--      ADR-0031) but not what the store sells it for. Without a list price the
--      POS cannot ring an owned item and the inventory list cannot show margin.
--      Consigned goods already carry agreed_price on consignment_item; owned
--      goods had no equivalent.
--
--   2. a BARCODE / GTIN for scan-to-cart. The POS is barcode-first; there was
--      no scannable identifier on either item table. A dedicated column (rather
--      than a generic item_identifier table) is the right size for now: one
--      scannable code per SKU, unique per tenant.
--
-- Both are additive and idempotent. list_price defaults to 0 so existing rows
-- stay valid; the UI treats 0 as "not yet priced".
-- ============================================================================

ALTER TABLE inventory_item
  ADD COLUMN IF NOT EXISTS list_price kernel.money_amount NOT NULL DEFAULT 0
    CHECK (list_price >= 0);

ALTER TABLE inventory_item
  ADD COLUMN IF NOT EXISTS barcode text;

-- A barcode identifies exactly one SKU within a tenant (when present).
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventory_item_barcode
  ON inventory_item (tenant_id, barcode)
  WHERE barcode IS NOT NULL AND deleted_at IS NULL;

ALTER TABLE consignment_item
  ADD COLUMN IF NOT EXISTS barcode text;

CREATE UNIQUE INDEX IF NOT EXISTS ux_consignment_item_barcode
  ON consignment_item (tenant_id, barcode)
  WHERE barcode IS NOT NULL AND deleted_at IS NULL;

COMMENT ON COLUMN inventory_item.list_price IS
  'Retail list price for owned stock. Cost lives in avg_cost (ADR-0031).';
COMMENT ON COLUMN inventory_item.barcode IS
  'Scannable GTIN/UPC for the POS. Unique per tenant when present.';
COMMENT ON COLUMN consignment_item.barcode IS
  'Scannable GTIN/UPC for the POS. Unique per tenant when present.';
