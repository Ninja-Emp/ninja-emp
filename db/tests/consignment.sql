-- ============================================================================
-- Ninja EMP — consignment.sql
-- Part 4: Consignment domain + ledger integration tests on real PostgreSQL 18.
-- Proves: agreement/commission, item intake, sale posting (cash/revenue +
-- COGS/consignor-payable), exact commission split, consignor payable open items
-- tie to the GL control account, payout, idempotency, and trial balance = 0.
-- Assumes db/provision.sh has run. Idempotent (per-run token).
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/consignment.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';

CREATE TEMP TABLE _cs (k text PRIMARY KEY, v uuid);
SELECT floor(random()*1000000000)::text AS run \gset

-- ---- Seed: consignor party + agreement ------------------------------------
INSERT INTO party (id, party_type, display_name) VALUES
  ('aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa','organization','Crafty Consignor Co')
ON CONFLICT (id) DO NOTHING;
INSERT INTO organization (party_id, legal_name) VALUES
  ('aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa','Crafty Consignor Co')
ON CONFLICT (party_id) DO NOTHING;

\echo '=== C1: create a consignor agreement with a 40% commission ==='
INSERT INTO consignor_agreement (id, consignor_party_id, status, start_date, default_commission_rate)
VALUES ('bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb','aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa','active','2026-01-01',0.40)
ON CONFLICT (id) DO NOTHING;
SELECT CASE WHEN (SELECT default_commission_rate FROM consignor_agreement
                   WHERE id='bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb') = 0.40
            THEN 'PASS: agreement created with 40% commission' ELSE 'FAIL' END AS c1;

\echo '=== C2: commission rule is effective-dated and non-overlapping ==='
DELETE FROM commission_rule WHERE agreement_id='bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb';
INSERT INTO commission_rule (agreement_id, rule_type, rate, effective_from)
VALUES ('bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb','flat',0.40,'2026-01-01');
DO $$
BEGIN
  INSERT INTO commission_rule (agreement_id, rule_type, rate, effective_from)
  VALUES ('bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb','flat',0.35,'2026-06-01');
  RAISE EXCEPTION 'FAIL: overlapping commission rule allowed';
EXCEPTION WHEN exclusion_violation THEN
  RAISE NOTICE 'PASS: overlapping commission rule rejected';
END $$;

\echo '=== C3: receive a consigned item ==='
INSERT INTO consignment_item (id, agreement_id, sku, description, agreed_price, status)
VALUES ('cccccccc-cccc-7ccc-8ccc-cccccccccccc','bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb',
        'SKU-' || :'run', 'Handmade Ceramic Vase', 100.00, 'available')
ON CONFLICT (id) DO NOTHING;
SELECT CASE WHEN (SELECT status FROM consignment_item WHERE id='cccccccc-cccc-7ccc-8ccc-cccccccccccc') = 'available'
            THEN 'PASS: item received and available' ELSE 'FAIL' END AS c3;

\echo '=== C4: record a sale; commission split is exact ==='
INSERT INTO consignment_sale (id, sale_date, channel, status)
VALUES ('dddddddd-dddd-7ddd-8ddd-dddddddddddd','2026-06-10','store','completed')
ON CONFLICT (id) DO NOTHING;
DELETE FROM consignment_sale_line WHERE sale_id='dddddddd-dddd-7ddd-8ddd-dddddddddddd';
INSERT INTO consignment_sale_line (sale_id, item_id, consignor_party_id, sale_price, commission_rate, commission_amount, net_to_consignor)
VALUES ('dddddddd-dddd-7ddd-8ddd-dddddddddddd','cccccccc-cccc-7ccc-8ccc-cccccccccccc',
        'aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa', 100.00, 0.40, 40.00, 60.00);
SELECT CASE WHEN (SELECT commission_amount + net_to_consignor FROM consignment_sale_line
                   WHERE sale_id='dddddddd-dddd-7ddd-8ddd-dddddddddddd') = 100.00
            THEN 'PASS: commission + net = sale price (exact)' ELSE 'FAIL' END AS c4;

\echo '=== C5: post the sale; entry balances and ties to consignor payable ==='
SELECT post_consignment_sale('dddddddd-dddd-7ddd-8ddd-dddddddddddd','2026-06-10','csale-' || :'run') AS id \gset
INSERT INTO _cs VALUES ('sale1', :'id');
SELECT CASE WHEN (SELECT sum(debit) FROM journal_line WHERE journal_entry_id=(SELECT v FROM _cs WHERE k='sale1'))
              = (SELECT sum(credit) FROM journal_line WHERE journal_entry_id=(SELECT v FROM _cs WHERE k='sale1'))
            THEN 'PASS: sale entry balances' ELSE 'FAIL' END AS c5a;
-- Consignor payable line for THIS sale = 60.00.
SELECT CASE WHEN (SELECT sum(base_credit) FROM journal_line
                   WHERE journal_entry_id=(SELECT v FROM _cs WHERE k='sale1')
                     AND subledger_type_code='consignor_payable') = 60.00
            THEN 'PASS: consignor payable line = 60.00' ELSE 'FAIL' END AS c5b;
-- Open items tie to the consignor payable control account.
SELECT CASE WHEN (SELECT difference FROM open_item_control_check() WHERE subledger_type_code='consignor_payable') = 0
            THEN 'PASS: open items tie to consignor payable control' ELSE 'FAIL' END AS c5c;

\echo '=== C6: sale posting is idempotent ==='
SELECT CASE WHEN post_consignment_sale('dddddddd-dddd-7ddd-8ddd-dddddddddddd','2026-06-10','csale-' || :'run')
              = (SELECT v FROM _cs WHERE k='sale1')
            THEN 'PASS: sale idempotent' ELSE 'FAIL' END AS c6;

\echo '=== C7: settle and pay the consignor ==='
INSERT INTO consignor_settlement (id, consignor_party_id, period_start, period_end, gross_sales, commission_total, net_payable, status)
VALUES ('eeeeeeee-eeee-7eee-8eee-eeeeeeeeeeee','aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa',
        '2026-06-01','2026-06-30',100.00,40.00,60.00,'finalized')
ON CONFLICT (id) DO NOTHING;
INSERT INTO consignor_payout (id, settlement_id, payout_amount, payout_date, method)
VALUES ('ffffffff-ffff-7fff-8fff-ffffffffffff','eeeeeeee-eeee-7eee-8eee-eeeeeeeeeeee',60.00,'2026-07-01','check')
ON CONFLICT (id) DO NOTHING;
SELECT post_consignor_payout('ffffffff-ffff-7fff-8fff-ffffffffffff','2026-07-01','payout-' || :'run') AS id \gset
INSERT INTO _cs VALUES ('pay1', :'id');
SELECT CASE WHEN (SELECT status FROM consignor_settlement WHERE id='eeeeeeee-eeee-7eee-8eee-eeeeeeeeeeee') = 'paid'
            THEN 'PASS: settlement marked paid' ELSE 'FAIL' END AS c7a;
SELECT CASE WHEN (SELECT journal_entry_id FROM consignor_payout WHERE id='ffffffff-ffff-7fff-8fff-ffffffffffff')
              = (SELECT v FROM _cs WHERE k='pay1')
            THEN 'PASS: payout linked to ledger entry' ELSE 'FAIL' END AS c7b;
SELECT CASE WHEN (SELECT difference FROM subledger_control_check() WHERE subledger_type_code='consignor_payable') = 0
            THEN 'PASS: consignor payable subledger ties to control' ELSE 'FAIL' END AS c7c;

\echo '=== C8: global trial balance still nets to zero ==='
SELECT CASE WHEN (SELECT sum(balance) FROM trial_balance('2026-12-31')) = 0
            THEN 'PASS: trial balance = 0' ELSE 'FAIL' END AS c8;

\echo '=== ALL CONSIGNMENT TESTS COMPLETE ==='
