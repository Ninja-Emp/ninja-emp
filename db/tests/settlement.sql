-- ============================================================================
-- Ninja EMP — settlement.sql
--
-- Proves the settlement invariants in docs/SETTLEMENT_INVARIANTS.md, i.e. that
-- the six defects F1-F6 are closed and the three EMP ports B1-B3 hold:
--
--   OI  open-item document model (item_kind, signed contribution)
--   PA  payment_application is an append-only ACTIVITY LEDGER (PA-2, PA-4)
--   AL  ONE allocator: invoices only, FIFO or directed, no silent remainder
--   RV  reversal un-applies settlement and is terminal (RV-4, RV-5)
--   CA  control check compares SIGNED sums (CA-2)
--   MO  no sub-cent amount may be posted (MO-1)
--   JI  the journal is hash-chained and verifies (JI-3)
--
-- Assertions are DELTA-BASED and use a per-run token, so the suite is
-- re-runnable against a database that already carries posted data.
--
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/settlement.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';

-- The suite is wrapped in a transaction that ROLLS BACK at the end. This is
-- what makes it truly re-runnable: the fixed test parties would otherwise
-- ACCUMULATE open items across runs, and the FIFO assertions (S2/S3) would
-- then pick up a previous run's oldest invoice and fail. Rolling back leaves
-- the database exactly as it was found -- no cleanup, no pollution.
BEGIN;

-- Defensive: a prior aborted run (or close.sql) may have closed 2026.
UPDATE fiscal_period SET status='open', closed_at=NULL, closed_by=NULL
 WHERE fiscal_year = 2026;

SELECT floor(random()*1000000000)::text AS run \gset
-- psql \gset variables are not visible inside DO $$ bodies; bridge them into
-- session settings so the DO blocks below can read them.
SELECT set_config('app.run', :'run', false);

-- Three parties, one per scenario, so the scenarios cannot contaminate each
-- other's open-item balances.
INSERT INTO party (id, party_type, display_name) VALUES
  ('5e771e00-0000-7000-8000-000000000001','organization','Settlement FIFO Debtor'),
  ('5e771e00-0000-7000-8000-000000000002','organization','Settlement Reversal Debtor'),
  ('5e771e00-0000-7000-8000-000000000003','organization','Settlement On-Account Debtor')
ON CONFLICT (id) DO NOTHING;
INSERT INTO organization (party_id, legal_name) VALUES
  ('5e771e00-0000-7000-8000-000000000001','Settlement FIFO Debtor'),
  ('5e771e00-0000-7000-8000-000000000002','Settlement Reversal Debtor'),
  ('5e771e00-0000-7000-8000-000000000003','Settlement On-Account Debtor')
ON CONFLICT (party_id) DO NOTHING;

CREATE TEMP TABLE _st (k text PRIMARY KEY, v uuid);

-- ---------------------------------------------------------------------------
-- Helper (temp schema, auto-dropped): open an AR invoice of p_amt for p_party,
-- returning (entry, item). A balanced AR-debit / cash-credit entry, then the
-- open item that documents it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp._st_invoice(
  p_party uuid, p_amt numeric, p_due date, p_doc text, p_key text
) RETURNS TABLE (entry_id uuid, item_id uuid)
LANGUAGE plpgsql AS $$
DECLARE v_entry uuid; v_item uuid;
BEGIN
  v_entry := post_journal_entry(
    DATE '2026-01-01', 'Settlement test invoice ' || p_doc, 'manual', p_doc, p_key,
    jsonb_build_array(
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1100'),
                         'debit', p_amt, 'currency','USD',
                         'party_id', p_party, 'subledger_type_code','ar'),
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),
                         'credit', p_amt, 'currency','USD')));
  v_item := open_item_create('ar', p_party, 'manual', p_doc, p_doc, p_amt, 'USD',
                             DATE '2026-01-01', p_due, v_entry);
  entry_id := v_entry; item_id := v_item; RETURN NEXT;
END $$;

-- ===========================================================================
\echo '=== S1 (OI-1/OI-2): invoices are documents with a positive magnitude ==='
-- ===========================================================================
SELECT entry_id AS e_a, item_id AS i_a FROM pg_temp._st_invoice(
  '5e771e00-0000-7000-8000-000000000001', 100.00, DATE '2026-05-01', 'INV-A', 'st-a-' || :'run') \gset
SELECT entry_id AS e_b, item_id AS i_b FROM pg_temp._st_invoice(
  '5e771e00-0000-7000-8000-000000000001',  50.00, DATE '2026-06-01', 'INV-B', 'st-b-' || :'run') \gset
INSERT INTO _st VALUES ('i_a', :'i_a'), ('i_b', :'i_b'), ('e_a', :'e_a'), ('e_b', :'e_b');

SELECT CASE WHEN (SELECT count(*) FROM open_item
                   WHERE id IN (:'i_a',:'i_b') AND item_kind='invoice'
                     AND open_amount = original_amount AND status='open') = 2
            THEN 'PASS: two invoices opened, positive magnitude, status open'
            ELSE 'FAIL: invoices not opened as expected' END AS s1;

-- ===========================================================================
\echo '=== S2 (AL-2/AL-3): FIFO settles the oldest invoice first ==='
-- ===========================================================================
SELECT apply_payment('5e771e00-0000-7000-8000-000000000001','ar',120.00,
                     DATE '2026-05-20','st-fifo-' || :'run') AS e_fifo \gset
INSERT INTO _st VALUES ('e_fifo', :'e_fifo');

SELECT CASE WHEN (SELECT open_amount FROM open_item WHERE id=:'i_a') = 0
             AND (SELECT status FROM open_item WHERE id=:'i_a') = 'settled'
            THEN 'PASS: oldest invoice (INV-A) fully settled by FIFO'
            ELSE 'FAIL: FIFO did not settle the oldest invoice' END AS s2a;
SELECT CASE WHEN (SELECT open_amount FROM open_item WHERE id=:'i_b') = 30.00
             AND (SELECT status FROM open_item WHERE id=:'i_b') = 'partial'
            THEN 'PASS: next invoice (INV-B) partially settled (30 of 50)'
            ELSE 'FAIL: partial settlement wrong' END AS s2b;

-- ===========================================================================
\echo '=== S3 (AL-4): a directed payment targets a specific invoice ==='
-- ===========================================================================
-- INV-C is the OLDEST (due 2026-04-01); FIFO would pick it, so to prove the
-- direction is honoured we target INV-B (the newer, partially-open one).
SELECT entry_id AS e_c, item_id AS i_c FROM pg_temp._st_invoice(
  '5e771e00-0000-7000-8000-000000000001', 40.00, DATE '2026-04-01', 'INV-C', 'st-c-' || :'run') \gset
INSERT INTO _st VALUES ('i_c', :'i_c'), ('e_c', :'e_c');

SELECT apply_payment('5e771e00-0000-7000-8000-000000000001','ar',20.00,
                     DATE '2026-05-21','st-dir-' || :'run', :'i_b') AS e_dir \gset
INSERT INTO _st VALUES ('e_dir', :'e_dir');

SELECT CASE WHEN (SELECT open_amount FROM open_item WHERE id=:'i_b') = 10.00
            THEN 'PASS: directed payment settled INV-B (30 -> 10), not the oldest'
            ELSE 'FAIL: directed payment ignored the target' END AS s3a;
SELECT CASE WHEN (SELECT open_amount FROM open_item WHERE id=:'i_c') = 40.00
            THEN 'PASS: the oldest invoice (INV-C) was left untouched'
            ELSE 'FAIL: directed payment leaked to another invoice' END AS s3b;

-- ===========================================================================
\echo '=== S4 (AL-5): an unapplied remainder RAISES, it is never swallowed ==='
-- ===========================================================================
DO $$
BEGIN
  PERFORM apply_payment('5e771e00-0000-7000-8000-000000000001','ar',999.00,
                        DATE '2026-05-22','st-over-' || current_setting('app.run'));
  RAISE EXCEPTION 'FAIL: overpayment was accepted (silent remainder)';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: overpayment refused (no silent remainder)';
END $$;

-- ===========================================================================
\echo '=== S5 (AL-5/OI): on_account opt-in records the overpayment as a credit ==='
-- ===========================================================================
-- Party 003 has a single 10.00 invoice. Pay 25.00 on-account (FIFO): the
-- invoice is settled, and because AL-4 lets a directed target fall through to
-- FIFO, the ONLY way a remainder survives is when it exceeds every eligible
-- invoice -- so we give this party exactly one invoice and overpay it.
SELECT entry_id AS e_oai, item_id AS i_oai FROM pg_temp._st_invoice(
  '5e771e00-0000-7000-8000-000000000003', 10.00, DATE '2026-05-19', 'INV-OA', 'st-oai-' || :'run') \gset
INSERT INTO _st VALUES ('i_oai', :'i_oai'), ('e_oai', :'e_oai');

SELECT apply_payment('5e771e00-0000-7000-8000-000000000003','ar',25.00,
                     DATE '2026-05-23','st-oa-' || :'run', NULL, true) AS e_oa \gset
INSERT INTO _st VALUES ('e_oa', :'e_oa');

SELECT CASE WHEN (SELECT open_amount FROM open_item WHERE id=:'i_oai') = 0
            THEN 'PASS: on-account payment settled the invoice'
            ELSE 'FAIL: on-account payment did not settle the invoice' END AS s5a;
SELECT CASE WHEN (SELECT open_amount FROM open_item
                   WHERE party_id='5e771e00-0000-7000-8000-000000000003'
                     AND item_kind='on_account' AND status='open') = 15.00
            THEN 'PASS: the 15.00 remainder is held as an on_account credit'
            ELSE 'FAIL: on-account credit not recorded' END AS s5b;
SELECT CASE WHEN open_item_signed('on_account', 15.00) = -15.00
            THEN 'PASS: on_account is signed negative (a credit)'
            ELSE 'FAIL: on_account sign wrong' END AS s5c;

-- ===========================================================================
\echo '=== S6 (F1/RV-5): reversing a payment restores the open item ==='
-- ===========================================================================
SELECT entry_id AS e_r, item_id AS i_r FROM pg_temp._st_invoice(
  '5e771e00-0000-7000-8000-000000000002', 100.00, DATE '2026-05-10', 'INV-R', 'st-r-' || :'run') \gset
INSERT INTO _st VALUES ('i_r', :'i_r'), ('e_r', :'e_r');
SELECT set_config('app.i_r', :'i_r', false);

SELECT apply_payment('5e771e00-0000-7000-8000-000000000002','ar',100.00,
                     DATE '2026-05-24','st-rpay-' || :'run') AS e_rpay \gset
INSERT INTO _st VALUES ('e_rpay', :'e_rpay');
SELECT set_config('app.e_rpay', :'e_rpay', false);

SELECT CASE WHEN (SELECT open_amount FROM open_item WHERE id=:'i_r') = 0
            THEN 'PASS: receipt settled INV-R'
            ELSE 'FAIL: receipt did not settle INV-R' END AS s6a;

SELECT reverse_journal_entry(:'e_rpay', DATE '2026-05-25', 'reverse receipt',
                             'st-rrev-' || :'run') AS e_rrev \gset
INSERT INTO _st VALUES ('e_rrev', :'e_rrev');

SELECT CASE WHEN (SELECT open_amount FROM open_item WHERE id=:'i_r') = 100.00
             AND (SELECT status FROM open_item WHERE id=:'i_r') = 'open'
            THEN 'PASS: reversal restored INV-R to fully open (F1 closed)'
            ELSE 'FAIL: reversal did not restore the open item (F1)' END AS s6b;
SELECT CASE WHEN EXISTS (SELECT 1 FROM payment_application
                          WHERE open_item_id=:'i_r' AND application_kind='unapply')
            THEN 'PASS: the reversal recorded an unapply activity row'
            ELSE 'FAIL: no unapply row recorded' END AS s6c;

-- ===========================================================================
\echo '=== S7 (B3/RV-4): a reversed entry cannot be reversed again ==='
-- ===========================================================================
DO $$
BEGIN
  PERFORM reverse_journal_entry(current_setting('app.e_rpay')::uuid, DATE '2026-05-26',
                                're-reverse', 'st-rrev2-' || current_setting('app.run'));
  RAISE EXCEPTION 'FAIL: a reversed entry was reversed again';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: re-reversal refused (reversal is terminal)';
END $$;

-- ===========================================================================
\echo '=== S8 (PA-2): payment_application is append-only ==='
-- ===========================================================================
DO $$
BEGIN
  UPDATE payment_application SET applied_amount = applied_amount + 1
   WHERE open_item_id = current_setting('app.i_r')::uuid;
  RAISE EXCEPTION 'FAIL: payment_application UPDATE was allowed';
EXCEPTION WHEN others THEN
  IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
  RAISE NOTICE 'PASS: payment_application UPDATE refused (append-only)';
END $$;
DO $$
BEGIN
  DELETE FROM payment_application WHERE open_item_id = current_setting('app.i_r')::uuid;
  RAISE EXCEPTION 'FAIL: payment_application DELETE was allowed';
EXCEPTION WHEN others THEN
  IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
  RAISE NOTICE 'PASS: payment_application DELETE refused (append-only)';
END $$;

-- ===========================================================================
\echo '=== S9 (PA-4): original - open = net of applications, everywhere ==='
-- ===========================================================================
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM open_item_application_check())
            THEN 'PASS: PA-4 tie-out holds for every open item'
            ELSE 'FAIL: PA-4 tie-out broken' END AS s9;

-- ===========================================================================
\echo '=== S10 (CA-2): signed open items tie to the signed GL control ==='
-- ===========================================================================
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM open_item_control_check() WHERE difference <> 0)
            THEN 'PASS: every open-item subledger ties to its control (signed)'
            ELSE 'FAIL: an open-item subledger does not tie to its control' END AS s10;

-- ===========================================================================
\echo '=== S11 (MO-1): a sub-cent amount cannot be posted ==='
-- ===========================================================================
DO $$
BEGIN
  PERFORM post_journal_entry(DATE '2026-05-27','sub-cent probe','manual','probe',
    'st-sub-' || current_setting('app.run'),
    jsonb_build_array(
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),
                         'debit', 1.005, 'currency','USD'),
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1100'),
                         'credit', 1.005, 'currency','USD',
                         'party_id','5e771e00-0000-7000-8000-000000000001',
                         'subledger_type_code','ar')));
  RAISE EXCEPTION 'FAIL: a sub-cent amount was accepted';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: sub-cent posting refused (MO-1)';
END $$;

-- ===========================================================================
\echo '=== S12 (JI-3): the journal hash chain verifies ==='
-- ===========================================================================
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM verify_journal_chain())
            THEN 'PASS: journal hash chain intact (every link verifies)'
            ELSE 'FAIL: journal hash chain is broken' END AS s12;

\echo '=== ALL SETTLEMENT TESTS COMPLETE ==='

-- Undo everything this suite did (see the note at BEGIN). The assertions above
-- have already been printed; the database is left pristine.
ROLLBACK;
