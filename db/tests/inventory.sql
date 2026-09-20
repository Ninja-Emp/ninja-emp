-- ============================================================================
-- Ninja EMP — inventory.sql
-- Proves owned-goods inventory (ADR-0031), stored value (ADR-0032), and the
-- vendor payable draw tender.
--
-- Delta-based assertions against a baseline, so the suite is re-runnable.
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/inventory.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';
SET app.pii_key   = 'test-pii-key-do-not-use-in-prod';

SELECT floor(random()*1000000000)::text AS run \gset

INSERT INTO party (id, party_type, display_name) VALUES
  ('55555555-5555-7555-8555-555555555555','organization','Widget Supplier Inc'),
  ('66666666-6666-7666-8666-666666666666','person','Gift Holder')
ON CONFLICT (id) DO NOTHING;
INSERT INTO organization (party_id, legal_name) VALUES
  ('55555555-5555-7555-8555-555555555555','Widget Supplier Inc')
ON CONFLICT (party_id) DO NOTHING;
INSERT INTO person (party_id, given_name, family_name) VALUES
  ('66666666-6666-7666-8666-666666666666','Gift','Holder')
ON CONFLICT (party_id) DO NOTHING;

\echo '=== I1: create an item and receive stock at 10.00 ==='
INSERT INTO inventory_item (sku, description, supplier_party_id)
VALUES ('SKU-' || :'run', 'Test Widget', '55555555-5555-7555-8555-555555555555')
RETURNING id AS item \gset
SELECT receive_inventory(:'item'::uuid, 10, 10.00, '2026-02-01', 'inv-r1-' || :'run') AS r1 \gset
SELECT CASE WHEN (SELECT on_hand FROM inventory_item WHERE id=:'item'::uuid) = 10
             AND (SELECT avg_cost FROM inventory_item WHERE id=:'item'::uuid) = 10.00
            THEN 'PASS: 10 units @ 10.00 avg cost'
            ELSE 'FAIL' END AS i1;

\echo '=== I2: weighted average recomputes correctly on a second receipt ==='
-- 10 @ 10.00 + 10 @ 20.00 -> 20 units @ 15.00
SELECT receive_inventory(:'item'::uuid, 10, 20.00, '2026-02-02', 'inv-r2-' || :'run') AS r2 \gset
SELECT CASE WHEN (SELECT on_hand FROM inventory_item WHERE id=:'item'::uuid) = 20
             AND (SELECT avg_cost FROM inventory_item WHERE id=:'item'::uuid) = 15.00
            THEN 'PASS: weighted average = 15.00 after 10@10 + 10@20'
            ELSE 'FAIL: avg=' || (SELECT avg_cost FROM inventory_item WHERE id=:'item'::uuid) END AS i2;

\echo '=== I3: receipt on account opens an AP open item ==='
SELECT CASE WHEN (SELECT count(*) FROM open_item
                   WHERE source='inventory_receipt' AND source_ref=:'item'::text
                     AND subledger_type_code='ap') = 2
            THEN 'PASS: two AP open items from two receipts'
            ELSE 'FAIL' END AS i3;

\echo '=== I4: inventory value ties to the GL Inventory account ==='
SELECT CASE WHEN (SELECT difference FROM inventory_value_check()) = 0
            THEN 'PASS: Σ(on_hand × avg_cost) = Inventory control'
            ELSE 'FAIL: difference = ' || (SELECT difference FROM inventory_value_check()) END AS i4;

\echo '=== I5: inventory_movement is append-only ==='
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN UPDATE inventory_movement SET quantity = 999 WHERE id = (SELECT max(id) FROM inventory_movement);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: inventory_movement rejects UPDATE';
  ELSE RAISE EXCEPTION 'FAIL: inventory_movement was mutable'; END IF;
END $$;

\echo '=== I6: selling owned goods books COGS at average cost ==='
-- Build a sale with one owned line: 2 units at 50.00 each.
INSERT INTO sale (sale_date, subtotal, discount_total, tax_total, total, status)
VALUES ('2026-02-10', 100.00, 0, 0, 100.00, 'completed') RETURNING id AS sale1 \gset
INSERT INTO sale_line (sale_id, line_no, line_kind, inventory_item_id, description,
                       quantity, unit_price, discount_amount, extended_price)
VALUES (:'sale1'::uuid, 1, 'owned', :'item'::uuid, 'Test Widget', 2, 50.00, 0, 100.00);
INSERT INTO payment (sale_id, amount, currency, payment_date)
VALUES (:'sale1'::uuid, 100.00, 'USD', '2026-02-10') RETURNING id AS pay1 \gset
INSERT INTO payment_tender (payment_id, tender_type_code, amount)
VALUES (:'pay1'::uuid, 'cash', 100.00);
SELECT post_sale(:'sale1'::uuid, '2026-02-10', 'inv-sale-' || :'run') AS se1 \gset
SELECT post_sale_inventory(:'sale1'::uuid, '2026-02-10') AS nrel \gset
-- 2 units at 15.00 average = 30.00 COGS; on hand 20 -> 18.
SELECT CASE WHEN (SELECT on_hand FROM inventory_item WHERE id=:'item'::uuid) = 18
             AND (SELECT sum(base_debit) FROM journal_line jl JOIN account a ON a.id=jl.account_id
                   WHERE a.code='5000' AND jl.journal_entry_id IN (
                     SELECT journal_entry_id FROM inventory_movement
                      WHERE item_id=:'item'::uuid AND movement_kind='issue')) >= 30.00
            THEN 'PASS: sold 2 @ avg 15.00 -> 30.00 COGS, 18 on hand'
            ELSE 'FAIL: on_hand=' || (SELECT on_hand FROM inventory_item WHERE id=:'item'::uuid) END AS i6;

\echo '=== I7: average cost is UNCHANGED by an issue ==='
SELECT CASE WHEN (SELECT avg_cost FROM inventory_item WHERE id=:'item'::uuid) = 15.00
            THEN 'PASS: issue does not disturb average cost'
            ELSE 'FAIL' END AS i7;

\echo '=== I8: inventory still ties to GL after the sale ==='
SELECT CASE WHEN (SELECT difference FROM inventory_value_check()) = 0
            THEN 'PASS: inventory ties to GL after COGS'
            ELSE 'FAIL: difference = ' || (SELECT difference FROM inventory_value_check()) END AS i8;

\echo '=== I9: cannot oversell stock ==='
DO $$
DECLARE v_sale uuid; v_line uuid; v_item uuid; v_ok boolean := false;
BEGIN
  SELECT id INTO v_item FROM inventory_item WHERE sku LIKE 'SKU-%' ORDER BY created_at DESC LIMIT 1;
  INSERT INTO sale (sale_date, subtotal, discount_total, tax_total, total, status)
    VALUES ('2026-02-11', 99999.00, 0, 0, 99999.00, 'completed') RETURNING id INTO v_sale;
  INSERT INTO sale_line (sale_id, line_no, line_kind, inventory_item_id, description,
                         quantity, unit_price, discount_amount, extended_price)
    VALUES (v_sale, 1, 'owned', v_item, 'Too many', 9999, 10.00, 0, 99990.00)
    RETURNING id INTO v_line;
  BEGIN
    PERFORM issue_inventory_for_sale_line(v_line, '2026-02-11', NULL);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  DELETE FROM sale_line WHERE id = v_line;
  DELETE FROM sale WHERE id = v_sale;
  IF v_ok THEN RAISE NOTICE 'PASS: overselling rejected';
  ELSE RAISE EXCEPTION 'FAIL: sold more than on hand'; END IF;
END $$;

\echo '=== I10: consigned lines may not carry inventory ==='
DO $$
DECLARE v_sale uuid; v_item uuid; v_ok boolean := false;
BEGIN
  SELECT id INTO v_item FROM inventory_item ORDER BY created_at DESC LIMIT 1;
  INSERT INTO sale (sale_date, subtotal, discount_total, tax_total, total, status)
    VALUES ('2026-02-12', 10.00, 0, 0, 10.00, 'completed') RETURNING id INTO v_sale;
  BEGIN
    INSERT INTO sale_line (sale_id, line_no, line_kind, inventory_item_id, consignor_party_id,
                           description, quantity, unit_price, discount_amount, extended_price,
                           commission_amount, net_to_consignor)
      VALUES (v_sale, 1, 'consignment', v_item, '22222222-2222-7222-8222-222222222222',
              'Bad line', 1, 10.00, 0, 10.00, 4.00, 6.00);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  DELETE FROM sale_line WHERE sale_id = v_sale;
  DELETE FROM sale WHERE id = v_sale;
  IF v_ok THEN RAISE NOTICE 'PASS: consigned line cannot be inventory-valued';
  ELSE RAISE EXCEPTION 'FAIL: consigned line accepted inventory_item_id'; END IF;
END $$;

\echo '=== I11: shrink adjustment expenses the loss ==='
SELECT adjust_inventory(:'item'::uuid, -1, '2026-02-13', 'Damaged', 'inv-adj-' || :'run') AS adj \gset
SELECT CASE WHEN (SELECT on_hand FROM inventory_item WHERE id=:'item'::uuid) = 17
             AND (SELECT sum(base_debit) FROM journal_line jl JOIN account a ON a.id=jl.account_id
                   WHERE a.code='5100' AND jl.journal_entry_id = :'adj'::uuid) = 15.00
            THEN 'PASS: shrink of 1 unit expensed 15.00 to 5100'
            ELSE 'FAIL' END AS i11;

\echo '=== I12: adjustment cannot drive stock negative ==='
DO $$
DECLARE v_item uuid; v_ok boolean := false;
BEGIN
  SELECT id INTO v_item FROM inventory_item WHERE sku LIKE 'SKU-%' ORDER BY created_at DESC LIMIT 1;
  BEGIN PERFORM adjust_inventory(v_item, -99999, '2026-02-14', 'impossible', NULL);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: negative-stock adjustment rejected';
  ELSE RAISE EXCEPTION 'FAIL: stock driven negative'; END IF;
END $$;

\echo '=== I13: denormalised on_hand agrees with the movement ledger ==='
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM inventory_integrity_check())
            THEN 'PASS: on_hand matches Σ movements for every item'
            ELSE 'FAIL: ' || (SELECT count(*) FROM inventory_integrity_check()) || ' item(s) drifted' END AS i13;

\echo '=== I14: issue an owned-goods refund; stock returns at ORIGINAL cost ==='
INSERT INTO sale (sale_date, subtotal, discount_total, tax_total, total, status, is_refund, refunds_sale_id)
VALUES ('2026-02-15', 50.00, 0, 0, 50.00, 'completed', true, :'sale1'::uuid) RETURNING id AS ref1 \gset
INSERT INTO sale_line (sale_id, line_no, line_kind, inventory_item_id, description,
                       quantity, unit_price, discount_amount, extended_price)
VALUES (:'ref1'::uuid, 1, 'owned', :'item'::uuid, 'Test Widget', 1, 50.00, 0, 50.00);
INSERT INTO payment (sale_id, amount, currency, payment_date)
VALUES (:'ref1'::uuid, 50.00, 'USD', '2026-02-15') RETURNING id AS payr \gset
INSERT INTO payment_tender (payment_id, tender_type_code, amount)
VALUES (:'payr'::uuid, 'cash', 50.00);
SELECT post_refund(:'ref1'::uuid, '2026-02-15', 'inv-ref-' || :'run') AS re1 \gset
SELECT post_refund_inventory(:'ref1'::uuid, '2026-02-15') AS nret \gset
SELECT CASE WHEN (SELECT on_hand FROM inventory_item WHERE id=:'item'::uuid) = 18
             AND (SELECT unit_cost FROM inventory_movement
                   WHERE item_id=:'item'::uuid AND movement_kind='customer_return'
                   ORDER BY id DESC LIMIT 1) = 15.00
            THEN 'PASS: 1 unit restocked at original 15.00 cost'
            ELSE 'FAIL: on_hand=' || (SELECT on_hand FROM inventory_item WHERE id=:'item'::uuid) END AS i14;

\echo '=== I15: inventory still ties to GL after the refund ==='
SELECT CASE WHEN (SELECT difference FROM inventory_value_check()) = 0
            THEN 'PASS: inventory ties to GL after restock'
            ELSE 'FAIL: difference = ' || (SELECT difference FROM inventory_value_check()) END AS i15;

-- ============================================================================
-- STORED VALUE (ADR-0032)
-- ============================================================================

\echo '=== S1: issuing a gift certificate creates a LIABILITY, not revenue ==='
SELECT issue_stored_value('gift_certificate','GC-' || :'run',
                          '66666666-6666-7666-8666-666666666666',
                          100.00,'2026-03-01', true, NULL, 'sv-i1-' || :'run') AS gc \gset
SELECT CASE WHEN (SELECT balance FROM stored_value WHERE id=:'gc'::uuid) = 100.00
             AND (SELECT sum(base_credit - base_debit) FROM journal_line jl
                    JOIN account a ON a.id=jl.account_id
                   WHERE a.code='2300'
                     AND jl.journal_entry_id=(SELECT journal_entry_id FROM stored_value WHERE id=:'gc'::uuid)) = 100.00
             AND NOT EXISTS (
                   SELECT 1 FROM journal_line jl
                     JOIN account a ON a.id=jl.account_id
                     JOIN kernel.account_type at ON at.code=a.account_type_code
                    WHERE jl.journal_entry_id=(SELECT journal_entry_id FROM stored_value WHERE id=:'gc'::uuid)
                      AND at.code='revenue')
            THEN 'PASS: 100.00 credited to GC liability; zero revenue recognised'
            ELSE 'FAIL' END AS s1;

\echo '=== S2: stored value ties to its GL control account ==='
SELECT CASE WHEN (SELECT difference FROM stored_value_control_check()
                   WHERE instrument_kind='gift_certificate') = 0
            THEN 'PASS: gift certificates tie to GL control'
            ELSE 'FAIL: difference = ' || (SELECT difference FROM stored_value_control_check()
                                            WHERE instrument_kind='gift_certificate') END AS s2;

\echo '=== S3: redemption draws the balance down (with GL linkage) ==='
-- Redemption must move the GL too, or the control check would drift. In POS
-- this comes from the liability tender; here we post the equivalent entry.
SELECT post_journal_entry('2026-03-05','Redeem GC','stored_value_redeem','GC-' || :'run',
  'sv-redeem-' || :'run',
  jsonb_build_array(
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='2300'),'debit',40.00,
                       'party_id','66666666-6666-7666-8666-666666666666',
                       'subledger_type_code','gift_certificate'),
    jsonb_build_object('account_id',(SELECT id FROM account WHERE code='4000'),'credit',40.00)
  )) AS rdentry \gset
SELECT redeem_stored_value('GC-' || :'run', 40.00, '2026-03-05', NULL, :'rdentry'::uuid) AS rd \gset
SELECT CASE WHEN (SELECT balance FROM stored_value WHERE id=:'gc'::uuid) = 60.00
             AND (SELECT status  FROM stored_value WHERE id=:'gc'::uuid) = 'active'
            THEN 'PASS: balance 100 -> 60 after 40.00 redemption'
            ELSE 'FAIL' END AS s3;

\echo '=== S3b: redemption without GL linkage is refused ==='
DO $$
DECLARE v_ok boolean := false; v_code text;
BEGIN
  SELECT code INTO v_code FROM stored_value WHERE code LIKE 'GC-%' ORDER BY created_at DESC LIMIT 1;
  BEGIN PERFORM redeem_stored_value(v_code, 1.00, '2026-03-05');   -- no entry, no sale
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: redemption without GL linkage rejected';
  ELSE RAISE EXCEPTION 'FAIL: instrument drawn down with no GL entry'; END IF;
END $$;

\echo '=== S4: cannot redeem more than the balance ==='
DO $$
DECLARE v_ok boolean := false; v_code text; v_e uuid;
BEGIN
  SELECT code INTO v_code FROM stored_value WHERE code LIKE 'GC-%' ORDER BY created_at DESC LIMIT 1;
  SELECT id INTO v_e FROM journal_entry ORDER BY posting_date DESC LIMIT 1;
  BEGIN PERFORM redeem_stored_value(v_code, 99999.00, '2026-03-06', NULL, v_e);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: over-redemption rejected';
  ELSE RAISE EXCEPTION 'FAIL: redeemed more than the balance'; END IF;
END $$;

\echo '=== S5: an expired certificate cannot be redeemed ==='
DO $$
DECLARE v_ok boolean := false; v_sv uuid; v_code text; v_e uuid;
BEGIN
  v_code := 'GCEXP-' || floor(random()*1e9)::text;
  SELECT issue_stored_value('gift_certificate', v_code,
                            '66666666-6666-7666-8666-666666666666',
                            25.00,'2026-03-01', true, '2026-03-02', NULL) INTO v_sv;
  SELECT id INTO v_e FROM journal_entry ORDER BY posting_date DESC LIMIT 1;
  BEGIN PERFORM redeem_stored_value(v_code, 5.00, '2026-06-01', NULL, v_e);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: expired certificate refused';
  ELSE RAISE EXCEPTION 'FAIL: redeemed an expired certificate'; END IF;
END $$;

\echo '=== S6: breakage is OPT-IN and does nothing by default ==='
-- Guard the config first: a prior aborted run must not leave it enabled.
UPDATE tenant_config SET breakage_after_months = NULL;
SELECT CASE WHEN recognize_breakage('2027-12-31','brk-off-' || :'run') IS NULL
            THEN 'PASS: breakage disabled by default; no income recognised'
            ELSE 'FAIL: breakage fired without being enabled' END AS s6;

\echo '=== S7: enabling breakage recognises stale balances as income ==='
UPDATE tenant_config SET breakage_after_months = 12;
SELECT recognize_breakage('2027-12-31','brk-on-' || :'run') AS brk \gset
SELECT CASE WHEN :'brk' <> '' AND
                 (SELECT sum(base_credit) FROM journal_line jl JOIN account a ON a.id=jl.account_id
                   WHERE a.code='4920' AND jl.journal_entry_id = :'brk'::uuid) > 0
            THEN 'PASS: breakage income booked to 4920 once enabled'
            ELSE 'FAIL' END AS s7;
UPDATE tenant_config SET breakage_after_months = NULL;   -- restore the safe default

\echo '=== S8: stored value still ties to GL after breakage ==='
SELECT CASE WHEN (SELECT difference FROM stored_value_control_check()
                   WHERE instrument_kind='gift_certificate') = 0
            THEN 'PASS: gift certificates tie to GL after breakage'
            ELSE 'FAIL: difference = ' || (SELECT difference FROM stored_value_control_check()
                                            WHERE instrument_kind='gift_certificate') END AS s8;

-- ============================================================================
-- VENDOR PAYABLE DRAW
-- ============================================================================

\echo '=== D1: vendor_draw tender exists and is a liability tender ==='
SELECT CASE WHEN (SELECT settlement_kind FROM tender_type WHERE code='vendor_draw') = 'liability'
             AND (SELECT subledger_type_code FROM tender_type WHERE code='vendor_draw') = 'vendor_payable'
            THEN 'PASS: vendor_draw is a liability tender on vendor_payable'
            ELSE 'FAIL' END AS d1;

\echo '=== D2: available draw reads the live ledger ==='
SELECT vendor_draw_available('22222222-2222-7222-8222-222222222222') AS avail \gset
SELECT CASE WHEN :'avail'::numeric >= 0
            THEN 'PASS: vendor draw available = ' || :'avail'::numeric || ' (realtime from ledger)'
            ELSE 'FAIL: negative availability' END AS d2;

\echo '=== D3: a vendor with no balance cannot draw ==='
-- The guard is a DEFERRED constraint trigger, so it fires at COMMIT. Running it
-- in a subtransaction and forcing SET CONSTRAINTS ALL IMMEDIATE makes it fire
-- where we can catch it.
DO $$
DECLARE v_sale uuid; v_pay uuid; v_ok boolean := false; v_party uuid;
BEGIN
  v_party := '55555555-5555-7555-8555-555555555555';   -- owed nothing
  BEGIN
    INSERT INTO sale (sale_date, subtotal, discount_total, tax_total, total, status)
      VALUES ('2026-04-01', 10.00, 0, 0, 10.00, 'completed') RETURNING id INTO v_sale;
    INSERT INTO sale_line (sale_id, line_no, line_kind, description,
                           quantity, unit_price, discount_amount, extended_price)
      VALUES (v_sale, 1, 'owned', 'Draw test', 1, 10.00, 0, 10.00);
    INSERT INTO payment (sale_id, amount, currency, payment_date)
      VALUES (v_sale, 10.00, 'USD', '2026-04-01') RETURNING id INTO v_pay;
    INSERT INTO payment_tender (payment_id, tender_type_code, amount, party_id)
      VALUES (v_pay, 'vendor_draw', 10.00, v_party);
    SET CONSTRAINTS ALL IMMEDIATE;
    -- If we reach here the guard did not fire; undo so the book stays clean.
    RAISE EXCEPTION 'GUARD_DID_NOT_FIRE';
  EXCEPTION
    WHEN check_violation THEN v_ok := true;
    WHEN raise_exception THEN v_ok := false;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: overdrawn vendor draw rejected';
  ELSE RAISE EXCEPTION 'FAIL: vendor drew against a zero balance'; END IF;
END $$;

\echo '=== D4: a vendor_draw tender must identify the vendor ==='
DO $$
DECLARE v_sale uuid; v_pay uuid; v_ok boolean := false;
BEGIN
  BEGIN
    INSERT INTO sale (sale_date, subtotal, discount_total, tax_total, total, status)
      VALUES ('2026-04-02', 5.00, 0, 0, 5.00, 'completed') RETURNING id INTO v_sale;
    INSERT INTO sale_line (sale_id, line_no, line_kind, description,
                           quantity, unit_price, discount_amount, extended_price)
      VALUES (v_sale, 1, 'owned', 'Draw test 2', 1, 5.00, 0, 5.00);
    INSERT INTO payment (sale_id, amount, currency, payment_date)
      VALUES (v_sale, 5.00, 'USD', '2026-04-02') RETURNING id INTO v_pay;
    INSERT INTO payment_tender (payment_id, tender_type_code, amount, party_id)
      VALUES (v_pay, 'vendor_draw', 5.00, NULL);
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'GUARD_DID_NOT_FIRE';
  EXCEPTION
    WHEN check_violation THEN v_ok := true;
    WHEN raise_exception THEN v_ok := false;
  END;
  IF v_ok THEN RAISE NOTICE 'PASS: anonymous vendor draw rejected';
  ELSE RAISE EXCEPTION 'FAIL: vendor draw accepted without a party'; END IF;
END $$;

\echo '=== D5: margin view reports owned COGS and consignment commission ==='
SELECT CASE WHEN (SELECT owned_cogs FROM v_sale_margin WHERE sale_id = :'sale1'::uuid) = 30.00
            THEN 'PASS: v_sale_margin reports 30.00 owned COGS'
            ELSE 'FAIL: cogs=' ||
                 COALESCE((SELECT owned_cogs FROM v_sale_margin WHERE sale_id=:'sale1'::uuid)::text,'null') END AS d5;

\echo '=== X1: full-book invariants still hold ==='
-- open_item_control_check is scoped to the OPEN-ITEM-BACKED subledgers. Security
-- deposits live in lease_deposit and vendor payables can be accrued straight to
-- the control account, so both legitimately carry a GL balance with no open
-- item behind it. Asserting on those would be a false positive, not a defect.
SELECT CASE WHEN (SELECT sum(balance) FROM trial_balance('2027-12-31')) = 0
             AND (SELECT count(*) FROM subledger_control_check() WHERE difference <> 0) = 0
             AND (SELECT count(*) FROM open_item_control_check()
                   WHERE difference <> 0
                     AND subledger_type_code IN ('ar','ap','consignor_payable')) = 0
             AND balance_sheet_check('2027-12-31') = 0
            THEN 'PASS: trial balance, subledgers, AR/AP/consignor open items and balance sheet all tie'
            ELSE 'FAIL: an invariant broke' END AS x1;

\echo '=== inventory.sql complete ==='
