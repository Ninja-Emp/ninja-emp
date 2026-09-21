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


-- ----------------------------------------------------------------------------
-- assert_posting_map_sane — guard against silent account-code collisions.
--
-- Every CoA seed file uses ON CONFLICT (tenant_id, code) DO NOTHING so the
-- seeds stay re-runnable. The cost is that a DUPLICATE code does not error:
-- the second seed silently evaporates and any posting role wired to it
-- resolves to the FIRST account that claimed the code. This shipped twice:
--
--   5100 — claimed by Consignment COGS, re-used by Inventory Adjustments, so
--          shrink and write-offs were booked as cost of consigned goods sold.
--   2400 — claimed by Security Deposits Held, re-used by Layaway Deposits, so
--          customer layaway money would have landed in refundable lessee
--          deposits, overstating a liability the store does not owe.
--
-- Both were invisible. The seeds succeeded, the trial balance still netted to
-- zero (a wrong account is still a real account), and only the P&L was wrong.
-- BALANCED DOES NOT MEAN CORRECT.
--
-- The check is deliberately EXACT, not a name-similarity heuristic. A fuzzy
-- matcher flags ar_control -> "Accounts Receivable" and cogs -> "Cost of Goods
-- Sold" as suspicious, and a check that cries wolf is a check that gets
-- ignored. Two precise rules instead:
--
--   1. Two posting roles must never share one account. Roles exist to be
--      independently re-pointable; sharing means one of them lost its own
--      account to a collision. Genuine aliases belong in an explicit
--      allow-list, added consciously.
--   2. An account's type must be compatible with what its role does. A role
--      whose name ends in _revenue wired to a liability account is a
--      collision, whatever the account is called.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assert_posting_map_sane()
RETURNS TABLE (role_code text, account_code text, account_name text, problem text)
LANGUAGE sql STABLE AS $$
  WITH wired AS (
    SELECT pm.role_code, a.code AS account_code, a.name AS account_name,
           a.account_type_code
      FROM posting_map pm
      JOIN account a ON a.id = pm.account_id
  ),
  -- Roles that legitimately point at the same account as another role.
  -- Empty today. Anything added here is a deliberate, reviewed decision.
  allowed_alias AS (
    SELECT * FROM (VALUES (NULL::text, NULL::text)) AS v(role_a, role_b) WHERE false
  )
  -- Rule 1: no two roles on one account.
  SELECT string_agg(w.role_code, ' + ' ORDER BY w.role_code),
         w.account_code, w.account_name,
         'ACCOUNT CODE COLLISION: ' || count(*)::text
           || ' posting roles share this one account'
    FROM wired w
   GROUP BY w.account_code, w.account_name
  HAVING count(*) > 1
     AND NOT EXISTS (
       SELECT 1 FROM allowed_alias aa
        WHERE aa.role_a = min(w.role_code) AND aa.role_b = max(w.role_code))

  UNION ALL

  -- Rule 2: role suffix must agree with the account type.
  SELECT w.role_code, w.account_code, w.account_name,
         'TYPE MISMATCH: role implies ' ||
           CASE
             WHEN w.role_code LIKE '%\_revenue'    THEN 'revenue'
             WHEN w.role_code LIKE '%\_expense'    THEN 'expense'
             WHEN w.role_code LIKE '%\_payable%'   THEN 'liability'
             WHEN w.role_code LIKE '%\_receivable' THEN 'asset'
           END
           || ' but the account is ' || w.account_type_code
    FROM wired w
   WHERE (w.role_code LIKE '%\_revenue'    AND w.account_type_code <> 'revenue')
      OR (w.role_code LIKE '%\_expense'    AND w.account_type_code <> 'expense')
      OR (w.role_code LIKE '%\_payable%'   AND w.account_type_code <> 'liability')
      OR (w.role_code LIKE '%\_receivable' AND w.account_type_code <> 'asset');
$$;
COMMENT ON FUNCTION assert_posting_map_sane IS
  'Detects account-code collisions: two roles sharing an account, or a role wired to an incompatible account type. Empty result = sane.';
