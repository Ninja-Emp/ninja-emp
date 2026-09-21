-- ============================================================================
-- 39_coa_close.sql — Chart of accounts additions for period/year-end close.
--
-- ADR-0030: year-end close rolls revenue & expense into Retained Earnings via
-- an Income Summary clearing account. Income Summary must always net to zero
-- after a close; a non-zero balance means the close is incomplete.
--
-- Idempotent. Safe to re-run.
-- ============================================================================

INSERT INTO account (code, name, account_type_code, is_control, control_subledger_type_code) VALUES
  ('3900','Retained Earnings',          'equity',  false, NULL),
  ('3950','Income Summary',             'equity',  false, NULL)
ON CONFLICT (tenant_id, code) DO NOTHING;

INSERT INTO posting_map (role_code, account_id)
SELECT v.role_code, a.id
  FROM (VALUES
    ('retained_earnings', '3900'),
    ('income_summary',    '3950')
  ) AS v(role_code, account_code)
  JOIN account a ON a.code = v.account_code
ON CONFLICT (tenant_id, role_code) DO NOTHING;

COMMENT ON COLUMN fiscal_period.status IS
  'open = postings allowed; closed = soft lock (reopenable); locked = hard lock after year-end close.';

-- ----------------------------------------------------------------------------
-- Inventory & stored-value accounts (ADR-0031, ADR-0032).
-- ----------------------------------------------------------------------------
INSERT INTO account (code, name, account_type_code, is_control, control_subledger_type_code) VALUES
  ('1210','Goods Received Not Invoiced','asset',   false, NULL),
  -- 5200, NOT 5100. 5100 is Consignment COGS (37_coa_consignment.sql). This
  -- previously read 5100, and because these seeds use ON CONFLICT DO NOTHING
  -- the duplicate insert silently vanished and inventory_adjustment resolved
  -- to the Consignment COGS account -- shrink and write-offs were being booked
  -- as cost of consigned goods sold. Silent, and wrong on the P&L.
  ('5200','Inventory Adjustments',      'expense', false, NULL),
  ('4920','Gift Certificate Breakage',  'revenue', false, NULL)
ON CONFLICT (tenant_id, code) DO NOTHING;

INSERT INTO posting_map (role_code, account_id)
SELECT v.role_code, a.id
  FROM (VALUES
    ('purchase_clearing',         '1210'),
    ('inventory_adjustment',      '5200'),
    ('gift_certificate_breakage', '4920')
  ) AS v(role_code, account_code)
  JOIN account a ON a.code = v.account_code
ON CONFLICT (tenant_id, role_code) DO NOTHING;
