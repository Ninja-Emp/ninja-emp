-- ============================================================================
-- Ninja EMP — pos.sql
-- Part 5: POS & Payments + realtime vendor portal, on real PostgreSQL 18.
-- Proves: sale totals invariant, split tenders, card clearing (not cash),
-- sales tax, accrual-at-sale (ADR-0028), realtime portal ties to GL control,
-- liability tender (store credit), refund (reversal-not-edit), drawer
-- over/short, merchant settlement + fees, idempotency, trial balance = 0.
-- Assumes db/provision.sh has run. Idempotent (per-run token).
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/pos.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';

SELECT floor(random()*1000000000)::text AS run \gset

-- ---- Seed: consignor, customer, register ----------------------------------
INSERT INTO party (id, party_type, display_name) VALUES
  ('dddddddd-dddd-7ddd-8ddd-dddddddddddd','organization','POS Test Consignor'),
  ('eeeeeeee-eeee-7eee-8eee-eeeeeeeeeeee','person','POS Test Customer')
ON CONFLICT (id) DO NOTHING;

INSERT INTO register (id, code, name)
VALUES ('f1f1f1f1-f1f1-7f1f-8f1f-f1f1f1f1f1f1','REG1','Front Counter')
ON CONFLICT (tenant_id, code) DO NOTHING;

\echo '=== P1: tender types seeded with correct settlement kinds ==='
SELECT CASE WHEN (SELECT settlement_kind FROM tender_type WHERE code='card') = 'clearing'
             AND (SELECT settlement_kind FROM tender_type WHERE code='cash') = 'cash'
             AND (SELECT settlement_kind FROM tender_type WHERE code='store_credit') = 'liability'
            THEN 'PASS: tender types seeded (card=clearing, not cash)' ELSE 'FAIL' END AS p1;

\echo '=== P2: liability tenders must carry a subledger type (CHECK) ==='
DO $$
BEGIN
  INSERT INTO tender_type (code, name, settlement_kind, debit_role_code, subledger_type_code)
  VALUES ('bogus_'||floor(random()*100000)::text,'Bogus','liability','cash',NULL);
  RAISE EXCEPTION 'FAIL: liability tender without subledger was allowed';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: liability tender requires a subledger type';
END $$;

\echo '=== P3: sale header totals must equal the sum of its lines ==='
DO $$
DECLARE v_sale uuid;
BEGIN
  INSERT INTO sale (register_id, customer_party_id, sale_date, subtotal, discount_total, tax_total, total, status)
  VALUES ('f1f1f1f1-f1f1-7f1f-8f1f-f1f1f1f1f1f1','eeeeeeee-eeee-7eee-8eee-eeeeeeeeeeee',
          '2026-03-10', 100.00, 0, 0, 100.00, 'draft')
  RETURNING id INTO v_sale;
  -- Deliberately insert a line that does NOT match the header (50 <> 100).
  INSERT INTO sale_line (sale_id, line_no, line_kind, description, quantity, unit_price, extended_price)
  VALUES (v_sale, 1, 'owned', 'Mismatched', 1, 50.00, 50.00);
  -- The totals trigger is DEFERRED (fires at commit); force it to fire now.
  SET CONSTRAINTS ALL IMMEDIATE;
  RAISE EXCEPTION 'FAIL: mismatched sale totals were allowed';
EXCEPTION
  WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS: sale totals invariant enforced';
END $$;

-- ---- Build a real sale: 1 consignment line + 1 owned line, tax, split tender
\echo '=== P4: build a completed sale with split tenders ==='
CREATE TEMP TABLE _p (k text PRIMARY KEY, v uuid);

DO $$
DECLARE
  v_sale uuid;
  v_pay  uuid;
BEGIN
  -- Lines: consignment 100.00 (40% commission -> 60 net), owned 50.00. Tax 8% on 150 = 12.00
  INSERT INTO sale (register_id, customer_party_id, sale_date,
                    subtotal, discount_total, tax_total, total, status)
  VALUES ('f1f1f1f1-f1f1-7f1f-8f1f-f1f1f1f1f1f1','eeeeeeee-eeee-7eee-8eee-eeeeeeeeeeee',
          '2026-03-10', 150.00, 0, 12.00, 162.00, 'completed')
  RETURNING id INTO v_sale;
  INSERT INTO _p VALUES ('sale', v_sale);

  INSERT INTO sale_line (sale_id, line_no, line_kind, consignor_party_id, sku, description,
                         quantity, unit_price, extended_price,
                         commission_rate, commission_amount, net_to_consignor, tax_amount)
  VALUES (v_sale, 1, 'consignment','dddddddd-dddd-7ddd-8ddd-dddddddddddd',
          'POS-SKU-1','Consigned Lamp', 1, 100.00, 100.00, 0.40, 40.00, 60.00, 8.00);

  INSERT INTO sale_line (sale_id, line_no, line_kind, sku, description,
                         quantity, unit_price, extended_price, unit_cost, tax_amount)
  VALUES (v_sale, 2, 'owned', 'POS-SKU-2','Store Mug', 1, 50.00, 50.00, 20.00, 4.00);

  -- Split tender: 62.00 cash + 100.00 card
  INSERT INTO payment (sale_id, payment_date, amount, status)
  VALUES (v_sale, '2026-03-10', 162.00, 'captured') RETURNING id INTO v_pay;
  INSERT INTO payment_tender (payment_id, tender_type_code, amount)
  VALUES (v_pay, 'cash', 62.00), (v_pay, 'card', 100.00);
END $$;

SELECT CASE WHEN (SELECT count(*) FROM sale_line WHERE sale_id=(SELECT v FROM _p WHERE k='sale')) = 2
            THEN 'PASS: sale built with 2 lines' ELSE 'FAIL' END AS p4a;
SELECT CASE WHEN (SELECT sum(pt.amount) FROM payment_tender pt
                   JOIN payment p ON p.id=pt.payment_id
                  WHERE p.sale_id=(SELECT v FROM _p WHERE k='sale')) = 162.00
            THEN 'PASS: split tenders sum to sale total' ELSE 'FAIL' END AS p4b;

\echo '=== P5: post the sale — balanced, accrual at sale (ADR-0028) ==='
SELECT post_sale((SELECT v FROM _p WHERE k='sale'), '2026-03-10', 'pos-sale-' || :'run') AS entry \gset
SELECT CASE WHEN (SELECT sum(debit) - sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'entry'::uuid) = 0
            THEN 'PASS: sale entry balances' ELSE 'FAIL' END AS p5a;

-- Card money must land in CLEARING, not cash (ADR-0029).
SELECT CASE WHEN (SELECT sum(jl.debit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id
                  WHERE jl.journal_entry_id = :'entry'::uuid AND a.code='1030') = 100.00
            THEN 'PASS: card tender debited Card Clearing (not cash)' ELSE 'FAIL' END AS p5b;

-- Cash tender to undeposited funds.
SELECT CASE WHEN (SELECT sum(jl.debit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id
                  WHERE jl.journal_entry_id = :'entry'::uuid AND a.code='1020') = 62.00
            THEN 'PASS: cash tender debited Undeposited Funds' ELSE 'FAIL' END AS p5c;

-- Sales tax credited to the tax liability.
SELECT CASE WHEN (SELECT sum(jl.credit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id
                  WHERE jl.journal_entry_id = :'entry'::uuid AND a.code='2500') = 12.00
            THEN 'PASS: sales tax credited to Sales Tax Payable' ELSE 'FAIL' END AS p5d;

-- ACCRUAL AT SALE: consignor payable credited 60.00 immediately.
SELECT CASE WHEN (SELECT sum(jl.credit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id
                  WHERE jl.journal_entry_id = :'entry'::uuid
                    AND a.code='2110'
                    AND jl.party_id='dddddddd-dddd-7ddd-8ddd-dddddddddddd') = 60.00
            THEN 'PASS: consignor payable accrued AT SALE (60.00)' ELSE 'FAIL' END AS p5e;

\echo '=== P6: posting is idempotent ==='
SELECT post_sale((SELECT v FROM _p WHERE k='sale'), '2026-03-10', 'pos-sale-' || :'run') AS entry2 \gset
SELECT CASE WHEN :'entry'::uuid = :'entry2'::uuid
            THEN 'PASS: sale posting idempotent' ELSE 'FAIL' END AS p6;

\echo '=== P7: REALTIME vendor portal ties to the GL control account ==='
SELECT CASE WHEN (SELECT difference FROM vendor_portal_check('consignor_payable')) = 0
            THEN 'PASS: realtime portal balance = GL control balance' ELSE 'FAIL' END AS p7a;
SELECT CASE WHEN (SELECT balance_owed FROM v_vendor_balance_realtime
                   WHERE party_id='dddddddd-dddd-7ddd-8ddd-dddddddddddd'
                     AND subledger_type_code='consignor_payable') >= 60.00
            THEN 'PASS: vendor sees realtime balance' ELSE 'FAIL' END AS p7b;
SELECT CASE WHEN (SELECT available_amount FROM v_vendor_payout_available
                   WHERE party_id='dddddddd-dddd-7ddd-8ddd-dddddddddddd'
                     AND subledger_type_code='consignor_payable') >= 60.00
            THEN 'PASS: vendor payout-available reflects the sale' ELSE 'FAIL' END AS p7c;

\echo '=== P8: refund is a separate document that reverses (reversal-not-edit) ==='
DO $$
DECLARE v_ref uuid; v_pay uuid; v_orig uuid;
BEGIN
  SELECT v INTO v_orig FROM _p WHERE k='sale';
  INSERT INTO sale (register_id, customer_party_id, sale_date,
                    subtotal, discount_total, tax_total, total, status,
                    is_refund, refunds_sale_id)
  VALUES ('f1f1f1f1-f1f1-7f1f-8f1f-f1f1f1f1f1f1','eeeeeeee-eeee-7eee-8eee-eeeeeeeeeeee',
          '2026-03-11', 100.00, 0, 8.00, 108.00, 'completed', true, v_orig)
  RETURNING id INTO v_ref;
  INSERT INTO _p VALUES ('refund', v_ref);

  -- Refund only the consignment line.
  INSERT INTO sale_line (sale_id, line_no, line_kind, consignor_party_id, sku, description,
                         quantity, unit_price, extended_price,
                         commission_rate, commission_amount, net_to_consignor, tax_amount)
  VALUES (v_ref, 1, 'consignment','dddddddd-dddd-7ddd-8ddd-dddddddddddd',
          'POS-SKU-1','Consigned Lamp (refund)', 1, 100.00, 100.00, 0.40, 40.00, 60.00, 8.00);

  INSERT INTO payment (sale_id, payment_date, amount, status)
  VALUES (v_ref, '2026-03-11', 108.00, 'captured') RETURNING id INTO v_pay;
  INSERT INTO payment_tender (payment_id, tender_type_code, amount)
  VALUES (v_pay, 'cash', 108.00);
END $$;

SELECT post_refund((SELECT v FROM _p WHERE k='refund'), '2026-03-11', 'pos-refund-' || :'run') AS rentry \gset
SELECT CASE WHEN (SELECT sum(debit) - sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'rentry'::uuid) = 0
            THEN 'PASS: refund entry balances' ELSE 'FAIL' END AS p8a;

-- Refund must REDUCE the consignor payable (debit 60.00).
SELECT CASE WHEN (SELECT sum(jl.debit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id
                  WHERE jl.journal_entry_id = :'rentry'::uuid
                    AND a.code='2110') = 60.00
            THEN 'PASS: refund reverses the consignor accrual' ELSE 'FAIL' END AS p8b;

-- Original sale is untouched (append-only ledger): its entry still exists.
SELECT CASE WHEN (SELECT count(*) FROM journal_line WHERE journal_entry_id = :'entry'::uuid) > 0
            THEN 'PASS: original entry untouched (reversal-not-edit)' ELSE 'FAIL' END AS p8c;

\echo '=== P9: portal + open items still tie to GL after the refund ==='
SELECT CASE WHEN (SELECT difference FROM vendor_portal_check('consignor_payable')) = 0
            THEN 'PASS: portal still ties to GL after refund' ELSE 'FAIL' END AS p9a;
-- A refund must also relieve the OPEN ITEMS, not just the control account.
SELECT CASE WHEN (SELECT difference FROM open_item_control_check()
                   WHERE subledger_type_code='consignor_payable') = 0
            THEN 'PASS: open items relieved by refund (tie to control)' ELSE 'FAIL' END AS p9b;

\echo '=== P10: drawer close books over/short ==='
DO $$
DECLARE v_shift uuid; v_sale uuid; v_pay uuid;
BEGIN
  INSERT INTO shift (register_id, opening_float, status)
  VALUES ('f1f1f1f1-f1f1-7f1f-8f1f-f1f1f1f1f1f1', 100.00, 'open')
  RETURNING id INTO v_shift;
  INSERT INTO _p VALUES ('shift', v_shift);

  -- One cash sale of 25.00 in this shift.
  INSERT INTO sale (register_id, shift_id, sale_date, subtotal, tax_total, total, status)
  VALUES ('f1f1f1f1-f1f1-7f1f-8f1f-f1f1f1f1f1f1', v_shift, '2026-03-12', 25.00, 0, 25.00, 'completed')
  RETURNING id INTO v_sale;
  INSERT INTO sale_line (sale_id, line_no, line_kind, description, quantity, unit_price, extended_price)
  VALUES (v_sale, 1, 'owned', 'Shift Item', 1, 25.00, 25.00);
  INSERT INTO payment (sale_id, payment_date, amount, status)
  VALUES (v_sale, '2026-03-12', 25.00, 'captured') RETURNING id INTO v_pay;
  INSERT INTO payment_tender (payment_id, tender_type_code, amount)
  VALUES (v_pay, 'cash', 25.00);
END $$;

-- Expected = 100 float + 25 cash = 125. Count 123 => short 2.00.
SELECT post_shift_close((SELECT v FROM _p WHERE k='shift'), 123.00, '2026-03-12',
                        'pos-shift-' || :'run') AS sentry \gset
SELECT CASE WHEN (SELECT over_short FROM shift WHERE id=(SELECT v FROM _p WHERE k='shift')) = -2.00
            THEN 'PASS: drawer short of 2.00 detected' ELSE 'FAIL' END AS p10a;
SELECT CASE WHEN (SELECT sum(jl.debit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id
                  WHERE jl.journal_entry_id = :'sentry'::uuid AND a.code='4910') = 2.00
            THEN 'PASS: shortage booked to Cash Over/Short' ELSE 'FAIL' END AS p10b;
SELECT CASE WHEN (SELECT status FROM shift WHERE id=(SELECT v FROM _p WHERE k='shift')) = 'closed'
            THEN 'PASS: shift closed' ELSE 'FAIL' END AS p10c;

\echo '=== P11: merchant settlement moves clearing -> bank and expenses the fee ==='
DO $$
DECLARE v_ms uuid;
BEGIN
  INSERT INTO merchant_settlement (settlement_date, gross_amount, fee_amount, net_amount)
  VALUES ('2026-03-13', 100.00, 2.90, 97.10) RETURNING id INTO v_ms;
  INSERT INTO _p VALUES ('ms', v_ms);
END $$;

SELECT post_merchant_settlement((SELECT v FROM _p WHERE k='ms'), '2026-03-13',
                                'pos-ms-' || :'run') AS msentry \gset
SELECT CASE WHEN (SELECT sum(debit) - sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'msentry'::uuid) = 0
            THEN 'PASS: merchant settlement balances' ELSE 'FAIL' END AS p11a;
SELECT CASE WHEN (SELECT sum(jl.debit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id
                  WHERE jl.journal_entry_id = :'msentry'::uuid AND a.code='6500') = 2.90
            THEN 'PASS: merchant fee expensed (not netted into revenue)' ELSE 'FAIL' END AS p11b;
SELECT CASE WHEN (SELECT sum(jl.credit) FROM journal_line jl
                   JOIN account a ON a.id=jl.account_id
                  WHERE jl.journal_entry_id = :'msentry'::uuid AND a.code='1030') = 100.00
            THEN 'PASS: card clearing released' ELSE 'FAIL' END AS p11c;

\echo '=== P12: subledgers still tie + trial balance = 0 ==='
SELECT CASE WHEN (SELECT count(*) FROM subledger_control_check() WHERE difference <> 0) = 0
            THEN 'PASS: all subledgers tie to their control accounts' ELSE 'FAIL' END AS p12a;
SELECT CASE WHEN (SELECT sum(balance) FROM trial_balance('2026-12-31')) = 0
            THEN 'PASS: trial balance = 0' ELSE 'FAIL' END AS p12b;
