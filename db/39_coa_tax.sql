-- ============================================================================
-- Ninja EMP — 39_coa_tax.sql  (TENANT-SCOPED SEED)
--
-- Accounts and posting roles for Round C: backup withholding, CAM recovery,
-- markdowns and layaway.
--
-- ACCOUNT CODE DISCIPLINE
-- These seeds all use ON CONFLICT (tenant_id, code) DO NOTHING, which means a
-- duplicate code does NOT error -- it silently does nothing, and the role then
-- maps to whatever account already owned that code. That exact bug shipped
-- twice (5100 claimed by both Consignment COGS and Inventory Adjustments;
-- 2400 by both Security Deposits Held and Layaway Deposits). 35_coa_seed.sql
-- now carries an assertion that every posting role resolves to an account
-- whose name matches what the role means, so a future collision fails loudly.
--
-- Codes used here, chosen to not collide with anything already seeded:
--   2150 Backup Withholding Payable   (2100/2110 vendor/consignor payable)
--   2450 Layaway Deposits             (2400 is Security Deposits Held)
--   1250 CAM Recovery Receivable      (1200/1210 inventory, 1100 AR)
--   4300 Markdowns                    (4200 commission revenue)
--
-- Idempotent. Run AFTER 35_coa_seed.sql.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ---- Posting roles ---------------------------------------------------------
INSERT INTO kernel.posting_role (code, name, description) VALUES
  ('backup_withholding_payable', 'Backup Withholding Payable',
   'Tax withheld from reportable payees and owed to the IRS.'),
  ('cam_recovery_receivable',    'CAM Recovery Receivable',
   'CAM reconciliation balance owed by a lessee after annual true-up.'),
  ('markdown_expense',           'Markdowns',
   'Contra-revenue for deliberate price reductions below the original ticket.'),
  ('layaway_deposit_control',    'Layaway Deposit Control',
   'Customer deposits on layaway. A liability until the goods are collected.')
ON CONFLICT (code) DO NOTHING;

-- ---- Accounts --------------------------------------------------------------
--
-- Markdowns is an EXPENSE-typed contra-revenue account rather than a
-- debit-normal revenue account. The account table derives normal balance from
-- account_type (kernel.account_type.normal_balance), so there is no per-account
-- override available: a revenue-typed account is credit-normal by definition,
-- and markdowns are naturally debit. Typing it as expense keeps the sign
-- correct and keeps income_statement() presenting it as a positive figure in
-- its natural direction. Gross-to-net sales presentation is a reporting
-- concern, handled in the P&L layout, not by fighting the type system.
--
-- Layaway Deposits is NOT a control account. A control account must tie to a
-- subledger type (CHECK on account), and layaway balances are tracked by the
-- layaway tables themselves, not by a party-tagged subledger.
INSERT INTO account (code, name, account_type_code, is_control, control_subledger_type_code) VALUES
  ('2150','Backup Withholding Payable', 'liability', false, NULL),
  -- A CONTROL account, tied to the layaway_deposit subledger. This is money
  -- held on trust for identified customers, so every posting to it must name
  -- WHOSE money it is. Modelling it as a plain liability would let deposits
  -- pile up anonymously, and "whose money is this" is the first question
  -- asked in a layaway dispute. Enforced by assert_subledger_tagging().
  ('2450','Layaway Deposits',           'liability', true,  'layaway_deposit'),
  ('1250','CAM Recovery Receivable',    'asset',     false, NULL),
  ('4300','Markdowns',                  'expense',   false, NULL)
ON CONFLICT (tenant_id, code) DO NOTHING;

-- ---- Wire roles to accounts ------------------------------------------------
INSERT INTO posting_map (role_code, account_id)
SELECT v.role_code, a.id
  FROM (VALUES
    ('backup_withholding_payable', '2150'),
    ('layaway_deposit_control',    '2450'),
    ('cam_recovery_receivable',    '1250'),
    ('markdown_expense',           '4300')
  ) AS v(role_code, account_code)
  JOIN account a ON a.code = v.account_code
ON CONFLICT (tenant_id, role_code) DO NOTHING;

-- ---- 1099 thresholds -------------------------------------------------------
-- Seeded in 82_tax_1099.sql, beside the tax_form_threshold table. This seed
-- file runs BEFORE the domain DDL, so the table does not exist yet here.
