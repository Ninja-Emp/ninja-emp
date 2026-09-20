-- ============================================================================
-- Ninja EMP — 38_coa_pos.sql  (TENANT-SCOPED)
-- Chart-of-accounts additions + posting_map entries for POS & Payments (Part 5).
-- Idempotent. Run AFTER 35_coa_seed.sql / 37_coa_consignment.sql.
-- Run with: SET search_path = <tenant_schema>, kernel;
--
-- ADR-0029: card tenders debit a CLEARING asset (not cash). Merchant settlement
-- later moves clearing -> bank and books the fee as expense. Drawer differences
-- go to cash over/short, never silently into revenue.
-- ============================================================================
\set ON_ERROR_STOP on

-- New accounts for POS.
INSERT INTO account (code, name, account_type_code, is_control, control_subledger_type_code) VALUES
  ('1020','Undeposited Funds',        'asset',   false, NULL),
  ('1030','Card Clearing',            'asset',   false, NULL),
  ('2510','Tips Payable',             'liability', false, NULL),
  ('4910','Cash Over/Short',          'revenue', false, NULL),
  ('6500','Merchant Fees',            'expense', false, NULL),
  ('6510','Sales Discounts',          'expense', false, NULL)
ON CONFLICT (tenant_id, code) DO NOTHING;

-- Posting roles for POS.
INSERT INTO posting_map (role_code, account_id)
SELECT v.role_code, a.id
  FROM (VALUES
    ('undeposited_funds',  '1020'),
    ('card_clearing',      '1030'),
    ('bank',               '1010'),
    ('tips_payable',       '2510'),
    ('sales_tax_payable',  '2500'),
    ('cash_over_short',    '4910'),
    ('merchant_fees',      '6500'),
    ('sales_discounts',    '6510')
  ) AS v(role_code, account_code)
  JOIN account a ON a.code = v.account_code
ON CONFLICT (tenant_id, role_code) DO NOTHING;
