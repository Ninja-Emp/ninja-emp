-- ============================================================================
-- Ninja EMP — close.sql
-- Proves period close, year-end close, financial statements, and AR write-off.
--
-- Uses fiscal year 2027 so it does not collide with the other suites (which
-- post into 2026). Year-end close HARD LOCKS a year, so the suite resets the
-- calendar at both ends — a previous aborted run must not poison this one.
--
-- Assertions are DELTA-BASED (measured against a baseline captured at start)
-- so the suite is re-runnable even though posted data accumulates.
--
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/close.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';
SET app.pii_key   = 'test-pii-key-do-not-use-in-prod';

-- Defensive reset: a prior aborted run may have left periods closed/locked.
UPDATE fiscal_period SET status='open', closed_at=NULL, closed_by=NULL
 WHERE fiscal_year IN (2026,2027);

SELECT floor(random()*1000000000)::text AS run \gset

INSERT INTO party (id, party_type, display_name) VALUES
  ('44444444-4444-7444-8444-444444444444','organization','Close Test Debtor')
ON CONFLICT (id) DO NOTHING;
INSERT INTO organization (party_id, legal_name) VALUES
  ('44444444-4444-7444-8444-444444444444','Close Test Debtor')
ON CONFLICT (party_id) DO NOTHING;

-- ---- Baselines (delta-based assertions) -------------------------------------
CREATE TEMP TABLE _base AS
SELECT net_income('2027-01-01','2027-12-31') AS ni,
       COALESCE((SELECT amount FROM income_statement('2027-01-01','2027-12-31') WHERE account_code='4000'),0) AS rev,
       COALESCE((SELECT amount FROM income_statement('2027-01-01','2027-12-31') WHERE account_code='6100'),0) AS exp,
       COALESCE((SELECT amount FROM cash_basis_income_statement('2027-01-01','2027-12-31') WHERE account_code='4000'),0) AS cash_rev,
       COALESCE((SELECT sum(base_credit - base_debit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id WHERE a.code='3900'),0) AS re;

\echo '=== C1: balance sheet balances before this run''s activity ==='
SELECT CASE WHEN balance_sheet_check('2027-01-01') = 0
            THEN 'PASS: balance sheet balances before activity'
            ELSE 'FAIL: bs_check=' || balance_sheet_check('2027-01-01') END AS c1;

\echo '=== C2: net income moves by exactly +600 (1000 revenue - 400 expense) ==='
SELECT post_journal_entry(
  '2027-03-15','Close test sale','manual','CLOSE-REV', 'close-rev-' || :'run',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',1000.00,'currency','USD'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',1000.00,'currency','USD')
  )) AS rev_entry \gset
SELECT post_journal_entry(
  '2027-03-20','Close test expense','manual','CLOSE-EXP', 'close-exp-' || :'run',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='6100'),'debit',400.00,'currency','USD'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'credit',400.00,'currency','USD')
  )) AS exp_entry \gset
SELECT CASE WHEN net_income('2027-01-01','2027-12-31') - (SELECT ni FROM _base) = 600.00
            THEN 'PASS: net income delta = 600.00'
            ELSE 'FAIL: delta = ' || (net_income('2027-01-01','2027-12-31') - (SELECT ni FROM _base)) END AS c2;

\echo '=== C3: income statement shows revenue and expense in natural (positive) sign ==='
SELECT CASE WHEN (SELECT amount FROM income_statement('2027-01-01','2027-12-31') WHERE account_code='4000')
                 - (SELECT rev FROM _base) = 1000.00
             AND (SELECT amount FROM income_statement('2027-01-01','2027-12-31') WHERE account_code='6100')
                 - (SELECT exp FROM _base) = 400.00
            THEN 'PASS: P&L revenue +1000 / expense +400, both positive'
            ELSE 'FAIL: P&L signs or amounts wrong' END AS c3;

\echo '=== C4: balance sheet balances mid-year WITH unclosed current-year earnings ==='
SELECT CASE WHEN balance_sheet_check('2027-06-30') = 0
            THEN 'PASS: balance sheet balances mid-year (unclosed earnings included)'
            ELSE 'FAIL: bs_check=' || balance_sheet_check('2027-06-30') END AS c4;

\echo '=== C5: Unclosed Earnings appears in equity before close ==='
-- 3999 is all-time unclosed P&L, not just the current year: a closed year nets
-- to zero and drops out on its own, so prior unclosed years must still count.
SELECT CASE WHEN (SELECT amount FROM balance_sheet('2027-06-30') WHERE account_code='3999')
                 = net_income('-infinity'::date,'2027-06-30')
            THEN 'PASS: Unclosed Earnings equals all-time unclosed net income'
            ELSE 'FAIL: 3999=' ||
                 COALESCE((SELECT amount FROM balance_sheet('2027-06-30') WHERE account_code='3999')::text,'null') ||
                 ' net_income=' || net_income('-infinity'::date,'2027-06-30') END AS c5;

\echo '=== C6: cash-basis P&L is DERIVED and excludes accrual-only revenue ==='
SELECT post_journal_entry(
  '2027-04-01','Accrued revenue on account','manual','CLOSE-ACC', 'close-acc-' || :'run',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1100'),'debit',250.00,'currency','USD',
                       'party_id','44444444-4444-7444-8444-444444444444','subledger_type_code','ar'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',250.00,'currency','USD')
  )) AS acc_entry \gset
SELECT CASE WHEN (SELECT amount FROM income_statement('2027-01-01','2027-12-31') WHERE account_code='4000')
                 - (SELECT rev FROM _base) = 1250.00
             AND (SELECT amount FROM cash_basis_income_statement('2027-01-01','2027-12-31') WHERE account_code='4000')
                 - (SELECT cash_rev FROM _base) = 1000.00
            THEN 'PASS: accrual +1250 vs cash +1000 — accrual-only revenue excluded from cash basis'
            ELSE 'FAIL: accrual delta=' ||
                 ((SELECT amount FROM income_statement('2027-01-01','2027-12-31') WHERE account_code='4000') - (SELECT rev FROM _base)) ||
                 ' cash delta=' ||
                 ((SELECT amount FROM cash_basis_income_statement('2027-01-01','2027-12-31') WHERE account_code='4000') - (SELECT cash_rev FROM _base))
       END AS c6;

\echo '=== C7: AR write-off debits bad debt and relieves the open item ==='
SELECT open_item_create('ar','44444444-4444-7444-8444-444444444444','manual',
                        'CLOSE-ACC','INV-CLOSE-' || :'run', 250.00,'USD','2027-04-01','2027-05-01', :'acc_entry') AS oi \gset
SELECT write_off_open_item(:'oi'::uuid, '2027-05-15', NULL, 'Uncollectible', 'close-wo-' || :'run') AS wo_entry \gset
SELECT CASE WHEN (SELECT open_amount FROM open_item WHERE id = :'oi'::uuid) = 0
             AND (SELECT status      FROM open_item WHERE id = :'oi'::uuid) = 'written_off'
             AND (SELECT sum(base_debit) FROM journal_line jl
                    JOIN account a ON a.id=jl.account_id
                   WHERE jl.journal_entry_id = :'wo_entry'::uuid AND a.code='6000') = 250.00
            THEN 'PASS: write-off booked 250.00 to bad debt; item written_off'
            ELSE 'FAIL' END AS c7;

\echo '=== C8: write-off keeps the AR subledger tied to its control account ==='
SELECT CASE WHEN COALESCE((SELECT difference FROM subledger_control_check()
                            WHERE subledger_type_code='ar'), 0) = 0
            THEN 'PASS: AR subledger still ties to control after write-off'
            ELSE 'FAIL: ar difference = ' ||
                 (SELECT difference FROM subledger_control_check() WHERE subledger_type_code='ar') END AS c8;

\echo '=== C9: cannot write off more than the open balance ==='
DO $$
DECLARE v_oi uuid; v_ok boolean := false;
BEGIN
  SELECT open_item_create('ar','44444444-4444-7444-8444-444444444444','manual',
                          'CLOSE-GUARD','INV-G-' || floor(random()*1e9)::text,
                          100.00,'USD','2027-04-01','2027-05-01',NULL) INTO v_oi;
  BEGIN
    PERFORM write_off_open_item(v_oi, '2027-05-16', 999.00, 'too much',
                                'close-guard-' || floor(random()*1e9)::text);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  -- Remove the guard item BEFORE asserting, so a failed assertion cannot leave
  -- an orphan open item behind. This item was created with no journal entry, so
  -- it has no GL counterpart and would break open_item_control_check for every
  -- later suite. Hard-delete rather than void: it never belonged in the ledger.
  DELETE FROM open_item WHERE id = v_oi;

  IF v_ok THEN RAISE NOTICE 'PASS: over-write-off rejected';
  ELSE RAISE EXCEPTION 'FAIL: over-write-off was allowed'; END IF;
END $$;

\echo '=== C9b: open items still tie to the AR control account ==='
SELECT CASE WHEN (SELECT difference FROM open_item_control_check() WHERE subledger_type_code='ar') = 0
            THEN 'PASS: open items tie to AR control (no orphans left by this suite)'
            ELSE 'FAIL: ar open-item difference = ' ||
                 (SELECT difference FROM open_item_control_check() WHERE subledger_type_code='ar') END AS c9b;

\echo '=== C10: close_period refuses to skip an earlier open period ==='
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN PERFORM close_period(2027::smallint, 6::smallint);   -- June, while earlier periods open
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: out-of-order period close rejected';
  ELSE RAISE EXCEPTION 'FAIL: closed a period out of order'; END IF;
END $$;

\echo '=== C11: close in order, then posting into a closed period is blocked ==='
DO $$
DECLARE v_ok boolean := false; p integer;
BEGIN
  FOR p IN 1..12 LOOP PERFORM close_period(2026::smallint, p::smallint); END LOOP;
  PERFORM close_period(2027::smallint, 1::smallint);

  BEGIN
    PERFORM post_journal_entry('2027-01-15','should fail','manual','X',
      'close-blocked-' || floor(random()*1e9)::text,
      jsonb_build_array(
        jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',5.00,'currency','USD'),
        jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',5.00,'currency','USD')));
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: posting into a closed period is blocked';
  ELSE RAISE EXCEPTION 'FAIL: posted into a closed period'; END IF;
END $$;

\echo '=== C12: reopen_period restores posting ==='
SELECT reopen_period(2027::smallint, 1::smallint);
SELECT CASE WHEN (SELECT status FROM fiscal_period WHERE fiscal_year=2027 AND period_no=1) = 'open'
            THEN 'PASS: period reopened' ELSE 'FAIL' END AS c12;

\echo '=== C13: close guard — ledger must balance before a period can close ==='
SELECT CASE WHEN period_balance_check('2027-12-31') = 0
            THEN 'PASS: ledger balanced, close guard satisfied'
            ELSE 'FAIL: out of balance by ' || period_balance_check('2027-12-31') END AS c13;

\echo '=== C14: year-end close rolls net income into Retained Earnings ==='
SELECT net_income('2027-01-01','2027-12-31') AS ni_pre \gset
SELECT close_fiscal_year(2027::smallint, 'close-ye-' || :'run') AS ye_entry \gset
SELECT CASE WHEN COALESCE((SELECT sum(base_credit - base_debit) FROM journal_line jl
                    JOIN account a ON a.id=jl.account_id WHERE a.code='3900'),0)
                 - (SELECT re FROM _base) = :'ni_pre'::numeric
            THEN 'PASS: Retained Earnings moved by exactly the year''s net income'
            ELSE 'FAIL: RE delta = ' ||
                 (COALESCE((SELECT sum(base_credit - base_debit) FROM journal_line jl
                    JOIN account a ON a.id=jl.account_id WHERE a.code='3900'),0) - (SELECT re FROM _base))
                 || ' expected ' || :'ni_pre'::numeric END AS c14;

\echo '=== C15: Income Summary nets to zero after close ==='
SELECT CASE WHEN COALESCE((SELECT sum(base_debit - base_credit) FROM journal_line jl
                    JOIN account a ON a.id=jl.account_id WHERE a.code='3950'),0) = 0
            THEN 'PASS: Income Summary = 0' ELSE 'FAIL' END AS c15;

\echo '=== C16: every P&L account is flat after close (new year starts at zero) ==='
SELECT CASE WHEN NOT EXISTS (
         SELECT 1 FROM journal_line jl
           JOIN journal_entry je ON je.id = jl.journal_entry_id
           JOIN account a ON a.id = jl.account_id
           JOIN kernel.account_type at ON at.code = a.account_type_code
          WHERE at.statement='income_statement'
            AND je.entry_date BETWEEN '2027-01-01' AND '2027-12-31'
          GROUP BY a.id
         HAVING sum(jl.base_debit - jl.base_credit) <> 0)
       THEN 'PASS: all P&L accounts zeroed by the close entry'
       ELSE 'FAIL: a P&L account still carries a balance' END AS c16;

\echo '=== C17: the closed year is hard-locked ==='
SELECT CASE WHEN (SELECT count(*) FROM fiscal_period WHERE fiscal_year=2027 AND status<>'locked') = 0
            THEN 'PASS: all 2027 periods locked' ELSE 'FAIL' END AS c17;

\echo '=== C18: a locked period refuses reopen ==='
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN PERFORM reopen_period(2027::smallint, 1::smallint);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: locked period refuses reopen';
  ELSE RAISE EXCEPTION 'FAIL: reopened a locked period'; END IF;
END $$;

\echo '=== C19: year-end close is idempotent ==='
SELECT CASE WHEN close_fiscal_year(2027::smallint, 'close-ye-' || :'run') = :'ye_entry'::uuid
            THEN 'PASS: re-running year-end close returns the same entry'
            ELSE 'FAIL: close was not idempotent' END AS c19;

\echo '=== C20: balance sheet still balances after the close ==='
SELECT CASE WHEN balance_sheet_check('2027-12-31') = 0
            THEN 'PASS: balance sheet balances post-close'
            ELSE 'FAIL: bs_check=' || balance_sheet_check('2027-12-31') END AS c20;

\echo '=== C21: trial balance still nets to zero ==='
SELECT CASE WHEN (SELECT sum(balance) FROM trial_balance('2027-12-31')) = 0
            THEN 'PASS: trial balance = 0' ELSE 'FAIL' END AS c21;

-- ---- Teardown -------------------------------------------------------------
-- Unlock first, then REVERSE the year-end close entry.
--
-- Reopening alone is not enough: the close entry would remain in the ledger and
-- a second run would roll an already-closed year into Retained Earnings again.
-- Reversing (never deleting) keeps the journal append-only, which is the whole
-- point of the design.
UPDATE fiscal_period SET status='open', closed_at=NULL, closed_by=NULL
 WHERE fiscal_year IN (2026,2027);

SELECT reverse_journal_entry(:'ye_entry'::uuid, '2027-12-31',
         'Teardown: reverse year-end close', 'close-ye-rev-' || :'run');

\echo '=== C22: after reversing the close, the book still balances ==='
SELECT CASE WHEN balance_sheet_check('2027-12-31') = 0
             AND (SELECT sum(balance) FROM trial_balance('2027-12-31')) = 0
            THEN 'PASS: balanced after close reversal (teardown clean)'
            ELSE 'FAIL: bs_check=' || balance_sheet_check('2027-12-31') END AS c22;

\echo '=== close.sql complete ==='
