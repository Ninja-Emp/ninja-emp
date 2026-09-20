-- ============================================================================
-- Ninja EMP — 40_subledger.sql  (TENANT-SCOPED)
-- Subledgers derived from tagged journal lines, tied to GL control accounts.
-- Subledgers are VIEWS over the append-only journal — never separate mutable
-- balances — so they can never drift from the GL.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- Generic subledger: open balance per party for a given subledger type.
-- Sign convention: positive = amount owed TO the store (debit-normal subledger),
-- negative = amount the store owes (credit-normal subledger).
CREATE OR REPLACE VIEW v_subledger AS
  SELECT jl.subledger_type_code,
         jl.party_id,
         p.display_name AS party_name,
         sum(jl.base_debit)  AS total_debit,
         sum(jl.base_credit) AS total_credit,
         sum(jl.base_debit - jl.base_credit) AS balance
    FROM journal_line jl
    JOIN party p ON p.id = jl.party_id
   WHERE jl.subledger_type_code IS NOT NULL
   GROUP BY jl.subledger_type_code, jl.party_id, p.display_name;
COMMENT ON VIEW v_subledger IS 'Open balance per party per subledger type, derived from tagged journal lines.';

-- Convenience views per subledger kind.
CREATE OR REPLACE VIEW v_ar AS
  SELECT * FROM v_subledger WHERE subledger_type_code = 'ar';
CREATE OR REPLACE VIEW v_ap AS
  SELECT * FROM v_subledger WHERE subledger_type_code = 'ap';
CREATE OR REPLACE VIEW v_vendor_payable AS
  SELECT * FROM v_subledger WHERE subledger_type_code = 'vendor_payable';
CREATE OR REPLACE VIEW v_customer_credit AS
  SELECT * FROM v_subledger WHERE subledger_type_code = 'customer_credit';
CREATE OR REPLACE VIEW v_gift_certificate AS
  SELECT * FROM v_subledger WHERE subledger_type_code = 'gift_certificate';

-- ----------------------------------------------------------------------------
-- INVARIANT: every subledger total must equal its GL control account balance.
-- Returns one row per subledger type; difference must be 0.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION subledger_control_check()
RETURNS TABLE (
  subledger_type_code text,
  subledger_total     numeric,
  control_total       numeric,
  difference          numeric
)
LANGUAGE sql STABLE AS $$
  WITH sub AS (
    SELECT jl.subledger_type_code AS st, sum(jl.base_debit - jl.base_credit) AS total
      FROM journal_line jl
     WHERE jl.subledger_type_code IS NOT NULL
     GROUP BY jl.subledger_type_code
  ),
  ctl AS (
    SELECT a.control_subledger_type_code AS st, sum(jl.base_debit - jl.base_credit) AS total
      FROM journal_line jl
      JOIN account a ON a.id = jl.account_id
     WHERE a.is_control
     GROUP BY a.control_subledger_type_code
  )
  SELECT COALESCE(sub.st, ctl.st),
         COALESCE(sub.total, 0),
         COALESCE(ctl.total, 0),
         COALESCE(sub.total, 0) - COALESCE(ctl.total, 0)
    FROM sub FULL OUTER JOIN ctl ON sub.st = ctl.st
   ORDER BY 1;
$$;
COMMENT ON FUNCTION subledger_control_check IS 'Invariant: subledger totals must equal GL control account balances (difference = 0).';
