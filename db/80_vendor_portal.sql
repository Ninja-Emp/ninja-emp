-- ============================================================================
-- Ninja EMP — 80_vendor_portal.sql  (TENANT-SCOPED)
-- REALTIME vendor/consignor portal reads.
--
-- These views read straight from the LEDGER and the OPEN-ITEM layer — there is
-- no batch table, no nightly rollup, and therefore nothing that can drift.
-- This is only possible because liability accrues AT SALE (ADR-0028).
--
-- Sign convention: payables are credit-normal, so "owed to vendor" is
-- credit - debit (the inverse of v_subledger's debit-normal balance).
--
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- v_vendor_balance_realtime — what we owe each consignor/vendor RIGHT NOW.
-- Sourced from journal lines tagged to the payable subledgers, so it is exactly
-- the GL balance (never an approximation).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_vendor_balance_realtime AS
SELECT
  jl.party_id,
  p.display_name            AS vendor_name,
  jl.subledger_type_code,
  sum(jl.base_credit - jl.base_debit) AS balance_owed,
  max(je.entry_date)        AS last_activity_date,
  count(*)                  AS ledger_line_count
FROM journal_line jl
JOIN journal_entry je ON je.id = jl.journal_entry_id
JOIN party p          ON p.id  = jl.party_id
WHERE jl.subledger_type_code IN ('consignor_payable','vendor_payable')
GROUP BY jl.party_id, p.display_name, jl.subledger_type_code;
COMMENT ON VIEW v_vendor_balance_realtime IS
  'Realtime payable balance per vendor/consignor, straight from the ledger (ADR-0028).';

-- ----------------------------------------------------------------------------
-- v_vendor_sales_realtime — per-vendor sales activity, line-level, realtime.
-- Covers consignment lines (by consignor) and vendor-attributed owned lines.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_vendor_sales_realtime AS
SELECT
  COALESCE(sl.consignor_party_id, sl.vendor_party_id) AS party_id,
  pt.display_name        AS vendor_name,
  s.sale_date,
  s.id                   AS sale_id,
  s.sale_no,
  sl.id                  AS sale_line_id,
  sl.line_kind,
  sl.sku,
  sl.description,
  sl.quantity,
  sl.extended_price      AS gross_amount,
  sl.commission_amount,
  sl.net_to_consignor    AS net_amount,
  s.is_refund
FROM sale_line sl
JOIN sale s   ON s.id = sl.sale_id
JOIN party pt ON pt.id = COALESCE(sl.consignor_party_id, sl.vendor_party_id)
WHERE s.status IN ('completed','refunded','partially_refunded')
  AND s.deleted_at IS NULL;
COMMENT ON VIEW v_vendor_sales_realtime IS
  'Line-level realtime sales feed for the vendor portal.';

-- ----------------------------------------------------------------------------
-- v_vendor_sales_today — the headline number a vendor sees on login.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_vendor_sales_today AS
SELECT
  party_id,
  vendor_name,
  sale_date,
  count(*) FILTER (WHERE NOT is_refund)              AS items_sold,
  COALESCE(sum(gross_amount) FILTER (WHERE NOT is_refund), 0)
    - COALESCE(sum(gross_amount) FILTER (WHERE is_refund), 0)      AS gross_sales,
  COALESCE(sum(commission_amount) FILTER (WHERE NOT is_refund), 0)
    - COALESCE(sum(commission_amount) FILTER (WHERE is_refund), 0) AS commission,
  COALESCE(sum(net_amount) FILTER (WHERE NOT is_refund), 0)
    - COALESCE(sum(net_amount) FILTER (WHERE is_refund), 0)        AS net_earned
FROM v_vendor_sales_realtime
GROUP BY party_id, vendor_name, sale_date;
COMMENT ON VIEW v_vendor_sales_today IS
  'Per-vendor per-day sales summary (net of refunds) for the portal dashboard.';

-- ----------------------------------------------------------------------------
-- v_vendor_payout_available — what a vendor could be paid right now.
-- Unsettled open items only; ties to the payable control account.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_vendor_payout_available AS
SELECT
  oi.party_id,
  p.display_name       AS vendor_name,
  oi.subledger_type_code,
  sum(oi.open_amount)  AS available_amount,
  count(*)             AS open_item_count,
  min(oi.issue_date)   AS oldest_item_date
FROM open_item oi
JOIN party p ON p.id = oi.party_id
WHERE oi.subledger_type_code IN ('consignor_payable','vendor_payable')
  AND oi.status IN ('open','partial')
  AND oi.deleted_at IS NULL
GROUP BY oi.party_id, p.display_name, oi.subledger_type_code;
COMMENT ON VIEW v_vendor_payout_available IS
  'Unsettled amounts available for payout, per vendor (realtime).';

-- ----------------------------------------------------------------------------
-- v_vendor_statement — full activity statement (ledger truth), per vendor.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_vendor_statement AS
SELECT
  jl.party_id,
  p.display_name    AS vendor_name,
  je.entry_date,
  je.source,
  je.source_ref,
  je.memo,
  jl.base_debit     AS debit_amount,
  jl.base_credit    AS credit_amount,
  (jl.base_credit - jl.base_debit) AS net_change,
  sum(jl.base_credit - jl.base_debit) OVER (
    PARTITION BY jl.party_id
    ORDER BY je.entry_date, je.id, jl.id
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS running_balance
FROM journal_line jl
JOIN journal_entry je ON je.id = jl.journal_entry_id
JOIN party p          ON p.id  = jl.party_id
WHERE jl.subledger_type_code IN ('consignor_payable','vendor_payable');
COMMENT ON VIEW v_vendor_statement IS
  'Per-vendor statement with running balance, derived from the ledger.';

-- ----------------------------------------------------------------------------
-- vendor_portal_check — proves the portal number EQUALS the GL control balance.
-- If this ever fails, the portal is lying and we want to know immediately.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vendor_portal_check(p_subledger text DEFAULT 'consignor_payable')
RETURNS TABLE (portal_total kernel.money_amount,
               gl_total     kernel.money_amount,
               difference   kernel.money_amount)
LANGUAGE plpgsql AS $$
DECLARE
  v_portal kernel.money_amount;
  v_gl     kernel.money_amount;
  v_acct   uuid;
BEGIN
  SELECT COALESCE(sum(balance_owed), 0) INTO v_portal
    FROM v_vendor_balance_realtime WHERE subledger_type_code = p_subledger;

  SELECT id INTO v_acct FROM account
   WHERE is_control AND control_subledger_type_code = p_subledger
   LIMIT 1;

  SELECT COALESCE(sum(jl.base_credit - jl.base_debit), 0) INTO v_gl
    FROM journal_line jl
   WHERE jl.account_id = v_acct;

  RETURN QUERY SELECT v_portal, v_gl, (v_portal - v_gl)::kernel.money_amount;
END $$;
COMMENT ON FUNCTION vendor_portal_check IS
  'Asserts the realtime portal balance equals the GL control balance.';
