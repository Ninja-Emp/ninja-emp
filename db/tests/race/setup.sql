-- ============================================================================
-- Race harness setup. Committed, so both concurrent sessions can see it.
--
-- Two postable accounts (non-control) and one open period in a far-future year
-- no other suite touches. No journals are created here: every race transaction
-- rolls back, so the ledger stays empty and the harness can assert the race keys
-- never persisted.
--
-- The fixed ids are asserted to exist at the end. If a conflicting (code) or
-- (year, period_no) row already existed, ON CONFLICT would skip the insert and
-- the scenario would silently lock nothing -- so this fails loudly instead.
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO account (id, code, name, account_type_code)
VALUES
  ('01900000-0000-7000-8000-00000000f010', 'RACE-CASH', 'Race Cash',    'asset'),
  ('01900000-0000-7000-8000-00000000f012', 'RACE-REV',  'Race Revenue', 'revenue')
ON CONFLICT (tenant_id, code) DO NOTHING;

INSERT INTO fiscal_period (id, fiscal_year, period_no, start_date, end_date, status)
VALUES ('01900000-0000-7000-8000-00000000f021', 2091, 1, '2091-01-01', '2091-12-31', 'open')
ON CONFLICT (tenant_id, fiscal_year, period_no) DO NOTHING;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM account WHERE id = '01900000-0000-7000-8000-00000000f010')
     OR NOT EXISTS (SELECT 1 FROM account WHERE id = '01900000-0000-7000-8000-00000000f012') THEN
    RAISE EXCEPTION 'race setup: fixed-id accounts missing (code conflict?)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM fiscal_period WHERE id = '01900000-0000-7000-8000-00000000f021') THEN
    RAISE EXCEPTION 'race setup: fixed-id period missing (year/period_no conflict?)';
  END IF;
END $$;
