-- ============================================================================
-- Ninja EMP — 37_coa_consignment.sql  (TENANT-SCOPED)
-- Chart-of-accounts additions + posting_map entries for the Consignment domain.
-- Idempotent. Run AFTER 35_coa_seed.sql.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- New accounts for consignment.
INSERT INTO account (code, name, account_type_code, is_control, control_subledger_type_code) VALUES
  ('2110','Consignor Payable',        'liability', true,  'consignor_payable'),
  ('4200','Commission Revenue',       'revenue',   false, NULL),
  ('5100','Consignment COGS',         'expense',   false, NULL)
ON CONFLICT (tenant_id, code) DO NOTHING;

-- Posting roles for consignment.
INSERT INTO posting_map (role_code, account_id)
SELECT v.role_code, a.id
  FROM (VALUES
    ('consignor_payable_control', '2110'),
    ('commission_revenue',        '4200'),
    ('consignment_cogs',          '5100')
  ) AS v(role_code, account_code)
  JOIN account a ON a.code = v.account_code
ON CONFLICT (tenant_id, role_code) DO NOTHING;
