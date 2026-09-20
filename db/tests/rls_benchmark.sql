-- ============================================================================
-- Ninja EMP — rls_benchmark.sql  (ADR-0007 measurement)
-- Measures the cost of RLS on the hot journal_line path with real data.
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/rls_benchmark.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';

-- Seed minimal config if absent.
INSERT INTO tenant_config (legal_name, functional_currency)
VALUES ('Bench Mall','USD') ON CONFLICT DO NOTHING;
INSERT INTO account (code,name,account_type_code) VALUES
  ('1000','Cash','asset'),('4000','Sales','revenue') ON CONFLICT DO NOTHING;
INSERT INTO fiscal_period (fiscal_year,period_no,start_date,end_date,status)
VALUES (2025,1,'2025-01-01','2025-12-31','open') ON CONFLICT DO NOTHING;

-- Generate 100k balanced entries (200k lines) directly (bypassing the API for speed).
DO $$
DECLARE
  v_cash uuid := (SELECT id FROM account WHERE code='1000');
  v_sales uuid := (SELECT id FROM account WHERE code='4000');
  v_entry uuid;
  i int;
BEGIN
  FOR i IN 1..100000 LOOP
    INSERT INTO journal_entry (entry_date, memo, source, idempotency_key)
    VALUES ('2025-06-01','bench','bench','bench-'||i) RETURNING id INTO v_entry;
    INSERT INTO journal_line (journal_entry_id,line_no,account_id,debit,credit,currency,base_debit,base_credit)
    VALUES (v_entry,1,v_cash,10,0,'USD',10,0),
           (v_entry,2,v_sales,0,10,'USD',0,10);
  END LOOP;
END $$;
ANALYZE journal_line;

\echo '=== Row count ==='
SELECT count(*) AS journal_lines FROM journal_line;

\echo '=== Scan WITH RLS (as ninja_app, tenant set) ==='
SET ROLE ninja_app;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
  SELECT account_id, sum(base_debit), sum(base_credit) FROM journal_line GROUP BY account_id;
RESET ROLE;

\echo '=== Scan WITHOUT RLS (as ninja_migrator, BYPASSRLS) ==='
SET ROLE ninja_migrator;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
  SELECT account_id, sum(base_debit), sum(base_credit) FROM journal_line GROUP BY account_id;
RESET ROLE;

\echo '=== Cleanup bench data ==='
-- Append-only blocks DELETE; truncate via migrator (DDL) to reset.
SET ROLE ninja_migrator;
TRUNCATE journal_line, journal_entry RESTART IDENTITY;
RESET ROLE;
