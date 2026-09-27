-- Adversarial probe: does the append-only guard actually hold?
-- Run: sudo -u postgres psql -d ninja_emp -v ON_ERROR_STOP=0 -f db/tests/vuln_probe.sql
-- Each attack runs in its own transaction and is rolled back.
\set ON_ERROR_STOP off
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';

\echo '--- VULN 1: replica-mode UPDATE of a posted journal entry ---'
BEGIN;
SELECT post_journal_entry(
  current_date, 'probe memo', 'manual', 'probe-1', 'probe-key-1',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',10),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1010'),'credit',10)
  )
);
SET CONSTRAINTS ALL IMMEDIATE;
SET LOCAL session_replication_role = replica;
UPDATE journal_entry SET memo = 'TAMPERED' WHERE memo = 'probe memo';
ROLLBACK;

\echo '--- VULN 2: plain TRUNCATE of the ledger ---'
BEGIN;
SELECT post_journal_entry(
  current_date, 'probe memo', 'manual', 'probe-2', 'probe-key-2',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',10),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1010'),'credit',10)
  )
);
SET CONSTRAINTS ALL IMMEDIATE;
TRUNCATE journal_line, journal_entry CASCADE;
ROLLBACK;

\echo '--- VULN 3: DROP the append-only trigger, then edit freely ---'
BEGIN;
DROP TRIGGER trg_journal_entry_append_only ON journal_entry;
ROLLBACK;

\echo '=== probe complete ==='
