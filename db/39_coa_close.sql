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
