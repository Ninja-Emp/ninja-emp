-- ============================================================================
-- Ninja EMP — invariants.sql
-- Proves the accounting + enterprise-data invariants hold on real PostgreSQL 18.
-- Assumes db/provision.sh has run (tenant_config, CoA, posting_map, fiscal
-- calendar already seeded).
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/invariants.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';
SET app.pii_key   = 'test-pii-key-do-not-use-in-prod';

CREATE TEMP TABLE _ids (k text PRIMARY KEY, v uuid);

-- ---- Seed parties (CoA + fiscal calendar already exist from provisioning) ----
INSERT INTO party (id, party_type, display_name) VALUES
  ('22222222-2222-7222-8222-222222222222','organization','Acme Consignor LLC'),
  ('33333333-3333-7333-8333-333333333333','person','Jane Customer')
ON CONFLICT (id) DO NOTHING;
INSERT INTO organization (party_id, legal_name) VALUES
  ('22222222-2222-7222-8222-222222222222','Acme Consignor LLC')
ON CONFLICT (party_id) DO NOTHING;
INSERT INTO person (party_id, given_name, family_name) VALUES
  ('33333333-3333-7333-8333-333333333333','Jane','Customer')
ON CONFLICT (party_id) DO NOTHING;

\echo '=== T1: balanced entry posts; trial balance nets to zero ==='
SELECT post_journal_entry(
  '2026-06-01','Cash sale','pos','SALE-1','idem-sale-1',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',100.00,'currency','USD'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',100.00,'currency','USD')
  )
) AS id \gset
INSERT INTO _ids VALUES ('entry1', :'id');
SELECT CASE WHEN (SELECT sum(balance) FROM trial_balance('2026-12-31')) = 0
            THEN 'PASS: trial balance = 0' ELSE 'FAIL' END AS t1;

\echo '=== T2: idempotent posting returns the same entry id ==='
SELECT CASE WHEN post_journal_entry(
  '2026-06-01','Cash sale','pos','SALE-1','idem-sale-1',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',100.00,'currency','USD'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',100.00,'currency','USD')
  )) = (SELECT v FROM _ids WHERE k='entry1')
  THEN 'PASS: idempotent' ELSE 'FAIL' END AS t2;

\echo '=== T3: unbalanced entry is REJECTED (deferred check forced) ==='
DO $$
BEGIN
  PERFORM post_journal_entry('2026-06-02','bad','manual',NULL,'idem-bad',
    jsonb_build_array(
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',50,'currency','USD'),
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',40,'currency','USD')
    ));
  EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
  RAISE EXCEPTION 'FAIL: unbalanced entry was accepted';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: unbalanced entry rejected (%)', SQLERRM;
END $$;

\echo '=== T4: append-only — UPDATE on journal_line is REJECTED ==='
DO $$
BEGIN
  UPDATE journal_line SET debit = 999
    WHERE journal_entry_id = (SELECT v FROM _ids WHERE k='entry1');
  RAISE EXCEPTION 'FAIL: update was allowed';
EXCEPTION WHEN object_not_in_prerequisite_state THEN
  RAISE NOTICE 'PASS: append-only enforced (%)', SQLERRM;
END $$;

\echo '=== T5: reversal posts a mirror entry; trial balance still zero ==='
SELECT reverse_journal_entry((SELECT v FROM _ids WHERE k='entry1'),'2026-06-03','Reversal test','idem-rev-1') AS id \gset
INSERT INTO _ids VALUES ('rev1', :'id');
SELECT CASE WHEN (SELECT sum(balance) FROM trial_balance('2026-12-31')) = 0
            THEN 'PASS: trial balance still 0 after reversal' ELSE 'FAIL' END AS t5;

\echo '=== T6: period lock blocks postings into a closed period ==='
UPDATE fiscal_period SET status='closed'
  WHERE start_date <= '2026-06-04' AND end_date >= '2026-06-04';
DO $$
BEGIN
  PERFORM post_journal_entry('2026-06-04','late','manual',NULL,'idem-late',
    jsonb_build_array(
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',1,'currency','USD'),
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',1,'currency','USD')
    ));
  RAISE EXCEPTION 'FAIL: posting into closed period was allowed';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: closed period blocked posting (%)', SQLERRM;
END $$;
UPDATE fiscal_period SET status='open'
  WHERE start_date <= '2026-06-04' AND end_date >= '2026-06-04';

\echo '=== T7: subledger line must post to its control account ==='
DO $$
BEGIN
  PERFORM post_journal_entry('2026-06-05','bad subledger','manual',NULL,'idem-sub',
    jsonb_build_array(
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',10,'currency','USD'),
      jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',10,'currency','USD',
                         'party_id','22222222-2222-7222-8222-222222222222','subledger_type_code','vendor_payable')
    ));
  RAISE EXCEPTION 'FAIL: subledger line on non-control account was allowed';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: subledger/control mismatch rejected (%)', SQLERRM;
END $$;

\echo '=== T8: vendor payable subledger ties to its GL control account ==='
SELECT post_journal_entry('2026-06-06','consignment sale','pos','SALE-2','idem-sale-2',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='1000'),'debit',100,'currency','USD'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',70,'currency','USD'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='2100'),'credit',30,'currency','USD',
                       'party_id','22222222-2222-7222-8222-222222222222','subledger_type_code','vendor_payable')
  )) AS id \gset
INSERT INTO _ids VALUES ('entry8', :'id');
SELECT CASE WHEN (SELECT difference FROM subledger_control_check() WHERE subledger_type_code='vendor_payable') = 0
            THEN 'PASS: subledger ties to control account' ELSE 'FAIL' END AS t8;

\echo '=== T9: debit XOR credit constraint ==='
DO $$
BEGIN
  INSERT INTO journal_line (journal_entry_id, line_no, account_id, debit, credit, currency)
  VALUES ((SELECT v FROM _ids WHERE k='entry8'), 99, (SELECT id FROM account WHERE code='1000'), 5, 5, 'USD');
  RAISE EXCEPTION 'FAIL: both debit and credit accepted';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: debit XOR credit enforced';
END $$;

\echo '=== T10: RLS hides rows when no tenant is set (as ninja_app) ==='
SET ROLE ninja_app;
RESET app.tenant_id;
SELECT CASE WHEN (SELECT count(*) FROM party) = 0
            THEN 'PASS: RLS hides all rows with no tenant' ELSE 'FAIL' END AS t10a;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SELECT CASE WHEN (SELECT count(*) FROM party
                   WHERE id IN ('22222222-2222-7222-8222-222222222222',
                                '33333333-3333-7333-8333-333333333333')) = 2
            THEN 'PASS: RLS shows tenant rows' ELSE 'FAIL' END AS t10b;
RESET ROLE;

\echo '=== T11: final trial balance nets to zero ==='
SELECT CASE WHEN (SELECT sum(balance) FROM trial_balance('2026-12-31')) = 0
            THEN 'PASS: FINAL trial balance = 0' ELSE 'FAIL' END AS t11;

\echo '=== T12: migrator BYPASSRLS sees rows even with no tenant set (ADR-0007) ==='
SET ROLE ninja_migrator;
RESET app.tenant_id;
SELECT CASE WHEN (SELECT count(*) FROM party
                   WHERE id IN ('22222222-2222-7222-8222-222222222222',
                                '33333333-3333-7333-8333-333333333333')) = 2
            THEN 'PASS: migrator bypasses RLS' ELSE 'FAIL' END AS t12;
RESET ROLE;
-- restore session context for subsequent tests
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';

\echo '=== T13: RESTRICT — a party with ledger history cannot be deleted (ADR-0016) ==='
DO $$
BEGIN
  DELETE FROM party WHERE id = '22222222-2222-7222-8222-222222222222';
  RAISE EXCEPTION 'FAIL: party with journal history was deleted';
EXCEPTION WHEN restrict_violation THEN
  RAISE NOTICE 'PASS: RESTRICT blocked delete of party with history (%)', SQLERRM;
END $$;

\echo '=== T14: optimistic locking — version increments on update (ADR-0017) ==='
SELECT version AS v0 FROM account WHERE code='1000' \gset
UPDATE account SET name = name WHERE code = '1000';
SELECT CASE WHEN (SELECT version FROM account WHERE code='1000') = :v0 + 1
            THEN 'PASS: version incremented by 1' ELSE 'FAIL' END AS t14a;
SELECT CASE WHEN (SELECT updated_by FROM account WHERE code='1000') = '99999999-9999-7999-8999-999999999999'
            THEN 'PASS: updated_by stamped from app.actor_id' ELSE 'FAIL' END AS t14b;

\echo '=== T15: PII encrypted at rest + masked in view (ADR-0018) ==='
SELECT set_party_identifier('33333333-3333-7333-8333-333333333333','ssn','123-45-6789','SSA') AS id \gset
INSERT INTO _ids VALUES ('pii1', :'id');
-- Raw ciphertext must NOT contain the plaintext.
SELECT CASE WHEN encode((SELECT identifier_value_enc FROM party_identifier WHERE id=(SELECT v FROM _ids WHERE k='pii1')),'escape') NOT LIKE '%6789%'
            THEN 'PASS: value encrypted at rest' ELSE 'FAIL' END AS t15a;
-- Masked view exposes only the last 4 characters.
SELECT CASE WHEN (SELECT identifier_masked FROM v_party_identifier_masked WHERE id=(SELECT v FROM _ids WHERE k='pii1')) = '*******6789'
            THEN 'PASS: masked view shows only last 4' ELSE 'FAIL' END AS t15b;

\echo '=== T16: posting_map resolves roles to accounts (ADR-0020) ==='
SELECT CASE WHEN posting_account('rent_revenue') = (SELECT id FROM account WHERE code='4100')
            THEN 'PASS: posting_map resolves rent_revenue -> 4100' ELSE 'FAIL' END AS t16;

\echo '=== T17: every touch_audit table has the columns touch_audit writes ==='
-- Structural test. kernel.touch_audit() assigns updated_at, updated_by and
-- version. If it is attached to a table missing any of them, EVERY update to
-- that table fails at runtime. person and organization shipped that way and it
-- went unnoticed because the suites only INSERT parties, never UPDATE them.
-- This asserts the whole class, not just the two tables that were broken.
SELECT CASE WHEN count(*) = 0
            THEN 'PASS: all touch_audit tables have updated_at/updated_by/version'
            ELSE 'FAIL: missing audit columns on ' || string_agg(relname, ', ')
       END AS t17
  FROM (
    SELECT c.relname
      FROM pg_trigger t
      JOIN pg_class c     ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
                         AND NOT a.attisdropped
     WHERE n.nspname = 'tenant_demo'
       AND t.tgfoid  = 'kernel.touch_audit'::regproc
     GROUP BY c.relname
    HAVING NOT bool_or(a.attname = 'updated_by')
        OR NOT bool_or(a.attname = 'updated_at')
        OR NOT bool_or(a.attname = 'version')
  ) s;

\echo '=== T18: person/organization are actually updatable ==='
-- The regression that T17 generalises: prove a real UPDATE round-trips and is
-- audit-stamped, for both party subtypes.
UPDATE person SET given_name = 'Janet'
 WHERE party_id = '33333333-3333-7333-8333-333333333333';
SELECT CASE WHEN (SELECT updated_by FROM person
                   WHERE party_id='33333333-3333-7333-8333-333333333333')
                 = '99999999-9999-7999-8999-999999999999'
            THEN 'PASS: person update stamped updated_by' ELSE 'FAIL' END AS t18a;

UPDATE organization SET trading_name = 'Acme Trading'
 WHERE party_id = '22222222-2222-7222-8222-222222222222';
SELECT CASE WHEN (SELECT updated_by FROM organization
                   WHERE party_id='22222222-2222-7222-8222-222222222222')
                 = '99999999-9999-7999-8999-999999999999'
            THEN 'PASS: organization update stamped updated_by' ELSE 'FAIL' END AS t18b;

-- Restore the seeded name so the suite stays re-runnable.
UPDATE person SET given_name = 'Jane'
 WHERE party_id = '33333333-3333-7333-8333-333333333333';

\echo '=== ALL INVARIANT TESTS COMPLETE ==='
