-- ============================================================================
-- Ninja EMP — vendormall.sql
-- Vendor Mall domain + ledger integration tests on real PostgreSQL 18.
-- Proves: lease/space allocation, unique active lease per space, rent invoice
-- posting balances and ties to the AR subledger, deposit posting, idempotency,
-- and delinquency snapshot.
-- Assumes db/provision.sh has run.
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/vendormall.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';

CREATE TEMP TABLE _vm (k text PRIMARY KEY, v uuid);

-- Per-run token so each run creates its own fresh invoice/payment (the journal
-- is append-only, so re-runs must not collide on idempotency keys).
SELECT floor(random()*1000000000)::text AS run \gset

-- ---- Seed: lessee party, location, floor, space ----------------------------
INSERT INTO party (id, party_type, display_name) VALUES
  ('44444444-4444-7444-8444-444444444444','organization','Bella Boutique LLC')
ON CONFLICT (id) DO NOTHING;
INSERT INTO organization (party_id, legal_name) VALUES
  ('44444444-4444-7444-8444-444444444444','Bella Boutique LLC')
ON CONFLICT (party_id) DO NOTHING;

INSERT INTO location (id, code, name, city, region) VALUES
  ('55555555-5555-7555-8555-555555555555','MAIN','Main Street Mall','Springfield','IL')
ON CONFLICT (id) DO NOTHING;
INSERT INTO floor (id, location_id, code, name, level_no) VALUES
  ('66666666-6666-7666-8666-666666666666','55555555-5555-7555-8555-555555555555','L1','Level 1',1)
ON CONFLICT (id) DO NOTHING;
INSERT INTO space (id, floor_id, code, name, space_type_code, area_sqft, status) VALUES
  ('77777777-7777-7777-8777-777777777777','66666666-6666-7666-8666-666666666666','A-101','Corner Booth','booth',120.00,'available')
ON CONFLICT (id) DO NOTHING;

\echo '=== V1: create an active lease for the space ==='
INSERT INTO lease (id, lessee_party_id, location_id, status, start_date, end_date, billing_day)
VALUES ('88888888-8888-7888-8888-888888888888','44444444-4444-7444-8444-444444444444',
        '55555555-5555-7555-8555-555555555555','active','2026-01-01','2026-12-31',1)
ON CONFLICT (id) DO NOTHING;
INSERT INTO lease_space (lease_id, space_id, allocated_area_sqft, from_date)
VALUES ('88888888-8888-7888-8888-888888888888','77777777-7777-7777-8777-777777777777',120.00,'2026-01-01')
ON CONFLICT DO NOTHING;
UPDATE space SET status='leased' WHERE id='77777777-7777-7777-8777-777777777777';
SELECT CASE WHEN (SELECT count(*) FROM v_active_lease WHERE lease_id='88888888-8888-7888-8888-888888888888') = 1
            THEN 'PASS: active lease visible with space' ELSE 'FAIL' END AS v1;

\echo '=== V2: a space cannot be actively leased twice (unique active allocation) ==='
DO $$
BEGIN
  INSERT INTO lease (id, lessee_party_id, location_id, status, start_date)
  VALUES (uuidv7(),'44444444-4444-7444-8444-444444444444','55555555-5555-7555-8555-555555555555','active','2026-02-01');
  INSERT INTO lease_space (lease_id, space_id, from_date)
  SELECT id, '77777777-7777-7777-8777-777777777777', '2026-02-01'
    FROM lease WHERE start_date='2026-02-01' AND lessee_party_id='44444444-4444-7444-8444-444444444444';
  RAISE EXCEPTION 'FAIL: double allocation allowed';
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE 'PASS: unique active lease per space enforced';
END $$;

\echo '=== V3: rent components (base rent + CAM) ==='
DELETE FROM rent_component WHERE lease_id='88888888-8888-7888-8888-888888888888';
INSERT INTO rent_component (lease_id, component_type_code, amount, currency, effective_from)
VALUES
  ('88888888-8888-7888-8888-888888888888','base_rent',1500.00,'USD','2026-01-01'),
  ('88888888-8888-7888-8888-888888888888','cam',      250.00,'USD','2026-01-01');
SELECT CASE WHEN (SELECT sum(amount) FROM rent_component WHERE lease_id='88888888-8888-7888-8888-888888888888') = 1750.00
            THEN 'PASS: rent components total 1750.00' ELSE 'FAIL' END AS v3;

\echo '=== V4: post a rent invoice; entry balances and ties to AR subledger ==='
SELECT post_rent_invoice(
  '88888888-8888-7888-8888-888888888888','2026-06-01','2026-06-30','2026-06-01','rent-2026-06-' || :'run'
) AS id \gset
INSERT INTO _vm VALUES ('rent1', :'id');
-- Entry must balance (debits = credits).
SELECT CASE WHEN (SELECT sum(debit) FROM journal_line WHERE journal_entry_id=(SELECT v FROM _vm WHERE k='rent1'))
              = (SELECT sum(credit) FROM journal_line WHERE journal_entry_id=(SELECT v FROM _vm WHERE k='rent1'))
            THEN 'PASS: rent entry balances' ELSE 'FAIL' END AS v4a;
-- AR line for THIS invoice must equal the invoice total (1750.00).
SELECT CASE WHEN (SELECT sum(base_debit) FROM journal_line
                   WHERE journal_entry_id=(SELECT v FROM _vm WHERE k='rent1')
                     AND subledger_type_code='ar') = 1750.00
            THEN 'PASS: AR line = 1750.00' ELSE 'FAIL' END AS v4b;
-- AR subledger ties to its GL control account.
SELECT CASE WHEN (SELECT difference FROM subledger_control_check() WHERE subledger_type_code='ar') = 0
            THEN 'PASS: AR subledger ties to control account' ELSE 'FAIL' END AS v4c;

\echo '=== V5: rent invoice is idempotent ==='
SELECT CASE WHEN post_rent_invoice(
  '88888888-8888-7888-8888-888888888888','2026-06-01','2026-06-30','2026-06-01','rent-2026-06-' || :'run'
) = (SELECT v FROM _vm WHERE k='rent1')
  THEN 'PASS: rent invoice idempotent' ELSE 'FAIL' END AS v5;

\echo '=== V6: security deposit posts cash / deposit liability and links the entry ==='
INSERT INTO lease_deposit (id, lease_id, deposit_amount, currency)
VALUES ('99999999-9999-7999-8999-999999999999','88888888-8888-7888-8888-888888888888',500.00,'USD')
ON CONFLICT (id) DO NOTHING;
SELECT post_deposit_receipt('99999999-9999-7999-8999-999999999999','2026-06-01','dep-2026-06') AS id \gset
INSERT INTO _vm VALUES ('dep1', :'id');
SELECT CASE WHEN (SELECT status FROM lease_deposit WHERE id='99999999-9999-7999-8999-999999999999') = 'held'
            THEN 'PASS: deposit status = held' ELSE 'FAIL' END AS v6a;
SELECT CASE WHEN (SELECT journal_entry_id FROM lease_deposit WHERE id='99999999-9999-7999-8999-999999999999')
              = (SELECT v FROM _vm WHERE k='dep1')
            THEN 'PASS: deposit linked to ledger entry' ELSE 'FAIL' END AS v6b;
SELECT CASE WHEN (SELECT difference FROM subledger_control_check() WHERE subledger_type_code='security_deposit') = 0
            THEN 'PASS: deposit subledger ties to control account' ELSE 'FAIL' END AS v6c;

\echo '=== V7: delinquency snapshot ==='
INSERT INTO delinquency (lease_id, as_of_date, amount_due, amount_paid, days_past_due, status)
VALUES ('88888888-8888-7888-8888-888888888888','2026-06-30',1750.00,0,30,'delinquent')
ON CONFLICT (tenant_id, lease_id, as_of_date) DO NOTHING;
SELECT CASE WHEN (SELECT status FROM delinquency WHERE lease_id='88888888-8888-7888-8888-888888888888') = 'delinquent'
            THEN 'PASS: delinquency recorded' ELSE 'FAIL' END AS v7;

\echo '=== V8: global trial balance still nets to zero ==='
SELECT CASE WHEN (SELECT sum(balance) FROM trial_balance('2026-12-31')) = 0
            THEN 'PASS: trial balance = 0' ELSE 'FAIL' END AS v8;

\echo '=== V9: rent invoice opened an AR open item (ADR-0023) ==='
SELECT CASE WHEN (SELECT open_amount FROM open_item
                   WHERE journal_entry_id=(SELECT v FROM _vm WHERE k='rent1')) = 1750.00
            THEN 'PASS: AR open item opened at 1750.00' ELSE 'FAIL' END AS v9a;
SELECT CASE WHEN (SELECT status FROM open_item
                   WHERE journal_entry_id=(SELECT v FROM _vm WHERE k='rent1')) = 'open'
            THEN 'PASS: AR open item status = open' ELSE 'FAIL' END AS v9b;
-- Open items must tie to the GL control account.
SELECT CASE WHEN (SELECT difference FROM open_item_control_check() WHERE subledger_type_code='ar') = 0
            THEN 'PASS: open items tie to AR control' ELSE 'FAIL' END AS v9c;

\echo '=== V10: apply a payment; open item settles and ties to control ==='
SELECT apply_payment('44444444-4444-7444-8444-444444444444','ar',1750.00,'2026-06-15','pay-ar-2026-06-' || :'run') AS id \gset
INSERT INTO _vm VALUES ('pay1', :'id');
SELECT CASE WHEN (SELECT status FROM open_item
                   WHERE journal_entry_id=(SELECT v FROM _vm WHERE k='rent1')) = 'settled'
            THEN 'PASS: AR open item settled' ELSE 'FAIL' END AS v10a;
SELECT CASE WHEN (SELECT open_amount FROM open_item
                   WHERE journal_entry_id=(SELECT v FROM _vm WHERE k='rent1')) = 0
            THEN 'PASS: AR open item open_amount = 0' ELSE 'FAIL' END AS v10b;
SELECT CASE WHEN (SELECT difference FROM open_item_control_check() WHERE subledger_type_code='ar') = 0
            THEN 'PASS: open items still tie to AR control after payment' ELSE 'FAIL' END AS v10c;
-- Payment is idempotent (same key returns same entry, no double allocation).
SELECT CASE WHEN apply_payment('44444444-4444-7444-8444-444444444444','ar',1750.00,'2026-06-15','pay-ar-2026-06-' || :'run')
              = (SELECT v FROM _vm WHERE k='pay1')
            THEN 'PASS: payment idempotent' ELSE 'FAIL' END AS v10d;

\echo '=== V11: aging view reflects the settled item ==='
SELECT CASE WHEN (SELECT COALESCE(sum(total_open),0) FROM v_aging
                   WHERE subledger_type_code='ar'
                     AND party_id='44444444-4444-7444-8444-444444444444') = 0
            THEN 'PASS: aging shows no open AR for lessee' ELSE 'FAIL' END AS v11;

\echo '=== ALL VENDOR MALL TESTS COMPLETE ==='
