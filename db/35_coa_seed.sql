-- ============================================================================
-- Ninja EMP — 35_coa_seed.sql  (TENANT-SCOPED)
-- Standard mall chart of accounts + posting_map (account determination, ADR-0020).
-- Idempotent: safe to re-run. Tenants may remap posting roles without code change.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Standard chart of accounts. Codes are conventional; tenants may add accounts.
-- Control accounts declare the subledger they control (enforced by CHECK).
-- ----------------------------------------------------------------------------
INSERT INTO account (code, name, account_type_code, is_control, control_subledger_type_code) VALUES
  -- Assets
  ('1000','Cash on Hand',              'asset',     false, NULL),
  ('1010','Bank',                      'asset',     false, NULL),
  ('1100','Accounts Receivable',       'asset',     true,  'ar'),
  ('1200','Inventory',                 'asset',     false, NULL),
  ('1300','Prepaid Expenses',          'asset',     false, NULL),
  ('1500','Leasehold Improvements',    'asset',     false, NULL),
  -- Liabilities
  ('2000','Accounts Payable',          'liability', true,  'ap'),
  ('2100','Vendor Payable',            'liability', true,  'vendor_payable'),
  ('2200','Customer Store Credit',     'liability', true,  'customer_credit'),
  ('2300','Gift Certificates',         'liability', true,  'gift_certificate'),
  ('2400','Security Deposits Held',    'liability', true,  'security_deposit'),
  ('2500','Sales Tax Payable',         'liability', false, NULL),
  -- Equity
  ('3000','Owner Equity',              'equity',    false, NULL),
  ('3100','Owner Draw',                'equity',    false, NULL),
  -- Revenue
  ('4000','Sales Revenue',             'revenue',   false, NULL),
  ('4100','Rent Revenue',              'revenue',   false, NULL),
  ('4110','CAM Revenue',               'revenue',   false, NULL),
  ('4120','Percentage Rent Revenue',   'revenue',   false, NULL),
  ('4900','Other Income',              'revenue',   false, NULL),
  -- Expenses
  ('5000','Cost of Goods Sold',        'expense',   false, NULL),
  ('6000','Bad Debt Expense',          'expense',   false, NULL),
  ('6100','Rent Expense',              'expense',   false, NULL),
  ('6200','Utilities Expense',         'expense',   false, NULL),
  ('6300','Marketing Expense',         'expense',   false, NULL),
  ('6400','Insurance Expense',         'expense',   false, NULL),
  ('6900','General & Administrative',  'expense',   false, NULL)
ON CONFLICT (tenant_id, code) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Posting map: posting role -> account (ADR-0020). Domain code never hard-codes
-- account codes; it resolves through posting_account(role).
-- ----------------------------------------------------------------------------
INSERT INTO posting_map (role_code, account_id)
SELECT v.role_code, a.id
  FROM (VALUES
    ('cash',                     '1000'),
    ('ar_control',               '1100'),
    ('inventory',                '1200'),
    ('ap_control',               '2000'),
    ('vendor_payable_control',   '2100'),
    ('customer_credit_control',  '2200'),
    ('gift_certificate_control', '2300'),
    ('security_deposit_control', '2400'),
    ('owner_equity',             '3000'),
    ('sales_revenue',            '4000'),
    ('rent_revenue',             '4100'),
    ('cam_revenue',              '4110'),
    ('percentage_rent_revenue',  '4120'),
    ('other_income',             '4900'),
    ('cogs',                     '5000'),
    ('bad_debt_expense',         '6000')
  ) AS v(role_code, account_code)
  JOIN account a ON a.code = v.account_code
ON CONFLICT (tenant_id, role_code) DO NOTHING;
