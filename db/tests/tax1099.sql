-- ============================================================================
-- Ninja EMP — tax1099.sql
-- Proves 1099-NEC / 1099-MISC tracking and the annual extract (ADR-0034).
--
-- What this suite is really defending:
--   * the threshold is DATA and moves by year (OBBBA raises it for 2026)
--   * reportability is CASH basis, never the accrual
--   * exempt payees are never tracked
--   * backup withholding is computed and posted
--   * the extract BLOCKS on a missing TIN / W-9 / address rather than
--     quietly filing a form the IRS will reject
--   * the payment ledger is append-only
--
-- Delta-based assertions against a baseline, so the suite is re-runnable.
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/tax1099.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';
SET app.pii_key   = 'test-pii-key-do-not-use-in-prod';

SELECT floor(random()*1000000000)::text AS run \gset

-- Distinct payees per run so repeated runs never collide on the TIN hash.
INSERT INTO party (party_type, display_name)
VALUES ('person', 'Tax Payee A ' || :'run') RETURNING id AS pa \gset
INSERT INTO party (party_type, display_name)
VALUES ('person', 'Tax Payee B ' || :'run') RETURNING id AS pb \gset
INSERT INTO party (party_type, display_name)
VALUES ('organization', 'Exempt Corp ' || :'run') RETURNING id AS pc \gset
INSERT INTO party (party_type, display_name)
VALUES ('person', 'No Paperwork ' || :'run') RETURNING id AS pd \gset

\echo '=== X1: thresholds are data — 600 through 2025, 2000 from 2026 (OBBBA) ==='
-- The whole design rests on this. If the threshold were hard-coded at 600,
-- tax year 2026 would over-report every payee between 600 and 2000.
SELECT CASE WHEN form_1099_threshold_for('1099-NEC','nec',2025::smallint) = 600.00
             AND form_1099_threshold_for('1099-NEC','nec',2026::smallint) = 2000.00
            THEN 'PASS: threshold moves by year (600 -> 2000 at 2026)'
            ELSE 'FAIL: got ' || form_1099_threshold_for('1099-NEC','nec',2025::smallint)::text
                 || ' / ' || form_1099_threshold_for('1099-NEC','nec',2026::smallint)::text
       END AS x1;

\echo '=== X2: an unseeded future year falls back to the last known rule ==='
-- Not zero (everyone reportable) and not NULL (nobody reportable). Both of
-- those are silent, and both are wrong in a way nobody notices until April.
SELECT CASE WHEN form_1099_threshold_for('1099-NEC','nec',2035::smallint) = 2000.00
            THEN 'PASS: unseeded 2035 falls back to the latest prior year (2000)'
            ELSE 'FAIL: got ' || COALESCE(form_1099_threshold_for('1099-NEC','nec',2035::smallint)::text,'NULL')
       END AS x2;

\echo '=== X3: payments accumulate to a cash-basis annual total ==='
SELECT record_reportable_payment(:'pa'::uuid, '2025-03-15', 400.00,
                                 'consignor_payout', NULL, NULL, 'tx-a1-' || :'run') AS a1 \gset
SELECT record_reportable_payment(:'pa'::uuid, '2025-09-20', 350.00,
                                 'consignor_payout', NULL, NULL, 'tx-a2-' || :'run') AS a2 \gset
SELECT CASE WHEN party_1099_total(:'pa'::uuid, 2025::smallint) = 750.00
            THEN 'PASS: two payments total 750.00 for 2025'
            ELSE 'FAIL: got ' || party_1099_total(:'pa'::uuid, 2025::smallint)::text
       END AS x3;

\echo '=== X4: payments are attributed to the year they were PAID ==='
-- Cash basis. A payment in January 2026 for goods sold in 2025 belongs to
-- 2026, whatever the accrual says (ADR-0022).
SELECT record_reportable_payment(:'pa'::uuid, '2026-01-10', 900.00,
                                 'consignor_payout', NULL, NULL, 'tx-a3-' || :'run') AS a3 \gset
SELECT CASE WHEN party_1099_total(:'pa'::uuid, 2025::smallint) = 750.00
             AND party_1099_total(:'pa'::uuid, 2026::smallint) = 900.00
            THEN 'PASS: January payment lands in 2026, not 2025'
            ELSE 'FAIL: 2025=' || party_1099_total(:'pa'::uuid, 2025::smallint)::text
                 || ' 2026=' || party_1099_total(:'pa'::uuid, 2026::smallint)::text
       END AS x4;

\echo '=== X5: tax_year must agree with payment_date (CHECK constraint) ==='
-- A mismatch here is a misfiled form, so the database refuses it outright
-- rather than trusting the caller to pass a consistent pair.
DO $$
BEGIN
  INSERT INTO tax_year_payment (party_id, tax_year, payment_date, amount, source)
  SELECT id, 2024::smallint, '2025-06-01'::date, 100.00, 'test'
    FROM party WHERE display_name LIKE 'Tax Payee A %' LIMIT 1;
  RAISE EXCEPTION 'FAILED_NO_ERROR';
EXCEPTION
  WHEN check_violation THEN RAISE NOTICE 'PASS: tax_year/payment_date mismatch rejected';
  WHEN OTHERS THEN
    IF SQLERRM = 'FAILED_NO_ERROR' THEN RAISE NOTICE 'FAIL: mismatched tax_year was accepted';
    ELSE RAISE NOTICE 'FAIL: unexpected %', SQLERRM; END IF;
END $$;

\echo '=== X6: exempt payees are never recorded at all ==='
-- Recording corporations and filtering them at filing time means the filter
-- eventually gets forgotten. Better to never capture the row.
INSERT INTO payee_tax_profile (party_id, is_exempt, exempt_reason)
VALUES (:'pc'::uuid, true, 'C-corporation; exempt from 1099-NEC')
ON CONFLICT (party_id) DO NOTHING;
SELECT CASE WHEN record_reportable_payment(:'pc'::uuid, '2025-05-01', 50000.00,
                                           'consignor_payout', NULL, NULL,
                                           'tx-c1-' || :'run') IS NULL
             AND party_1099_total(:'pc'::uuid, 2025::smallint) = 0
            THEN 'PASS: 50,000 to an exempt corporation records nothing'
            ELSE 'FAIL: exempt payee was recorded'
       END AS x6;

\echo '=== X7: idempotent capture — replaying a payment does not double it ==='
SELECT record_reportable_payment(:'pa'::uuid, '2025-03-15', 400.00,
                                 'consignor_payout', NULL, NULL, 'tx-a1-' || :'run') AS a1b \gset
SELECT CASE WHEN party_1099_total(:'pa'::uuid, 2025::smallint) = 750.00
            THEN 'PASS: replayed idempotency key did not double the total'
            ELSE 'FAIL: got ' || party_1099_total(:'pa'::uuid, 2025::smallint)::text
       END AS x7;

\echo '=== X8: backup withholding is computed at the stored rate ==='
INSERT INTO payee_tax_profile (party_id, backup_withholding, backup_withholding_rate)
VALUES (:'pb'::uuid, true, 0.24)
ON CONFLICT (party_id) DO UPDATE
  SET backup_withholding = true, backup_withholding_rate = 0.24;
SELECT record_reportable_payment(:'pb'::uuid, '2025-04-01', 1000.00,
                                 'consignor_payout', NULL, NULL, 'tx-b1-' || :'run') AS b1 \gset
SELECT CASE WHEN (SELECT withheld_amount FROM tax_year_payment WHERE id = :'b1'::uuid) = 240.00
            THEN 'PASS: 24% backup withholding on 1000.00 = 240.00'
            ELSE 'FAIL: got ' ||
                 (SELECT withheld_amount FROM tax_year_payment WHERE id = :'b1'::uuid)::text
       END AS x8;

\echo '=== X9: the payment ledger is append-only ==='
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM tax_year_payment ORDER BY created_at DESC LIMIT 1;
  UPDATE tax_year_payment SET amount = 1.00 WHERE id = v_id;
  RAISE EXCEPTION 'FAILED_NO_ERROR';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = 'FAILED_NO_ERROR' THEN RAISE NOTICE 'FAIL: tax_year_payment was updatable';
    ELSIF SQLERRM LIKE '%append-only%' THEN RAISE NOTICE 'PASS: UPDATE on tax_year_payment blocked';
    ELSE RAISE NOTICE 'FAIL: unexpected %', SQLERRM; END IF;
END $$;

\echo '=== X10: corrections are negative rows, not edits ==='
SELECT record_reportable_payment(:'pa'::uuid, '2025-09-20', -350.00,
                                 'correction', NULL, NULL, 'tx-a2r-' || :'run') AS a2r \gset
SELECT CASE WHEN party_1099_total(:'pa'::uuid, 2025::smallint) = 400.00
            THEN 'PASS: negative correction reduced the 2025 total to 400.00'
            ELSE 'FAIL: got ' || party_1099_total(:'pa'::uuid, 2025::smallint)::text
       END AS x10;

\echo '=== X11: reportability respects the year threshold ==='
-- 750 paid in 2025 (threshold 600) is reportable. The SAME 750 in 2026
-- (threshold 2000) is not. Same money, different year, different duty.
SELECT record_reportable_payment(:'pd'::uuid, '2025-07-01', 750.00,
                                 'consignor_payout', NULL, NULL, 'tx-d1-' || :'run') AS d1 \gset
SELECT record_reportable_payment(:'pd'::uuid, '2026-07-01', 750.00,
                                 'consignor_payout', NULL, NULL, 'tx-d2-' || :'run') AS d2 \gset
SELECT CASE WHEN (SELECT is_reportable FROM form_1099_extract(2025::smallint)
                   WHERE party_id = :'pd'::uuid) = true
             AND (SELECT is_reportable FROM form_1099_extract(2026::smallint)
                   WHERE party_id = :'pd'::uuid) = false
            THEN 'PASS: 750 is reportable in 2025 but not in 2026'
            ELSE 'FAIL: reportability did not follow the year threshold'
       END AS x11;

\echo '=== X12: a reportable payee with no TIN is BLOCKED, not filed ==='
SELECT CASE WHEN (SELECT blocker FROM form_1099_extract(2025::smallint)
                   WHERE party_id = :'pd'::uuid) = 'NO TIN ON FILE'
            THEN 'PASS: missing TIN blocks the filing'
            ELSE 'FAIL: got ' || COALESCE((SELECT blocker FROM form_1099_extract(2025::smallint)
                                            WHERE party_id = :'pd'::uuid),'NULL')
       END AS x12;

\echo '=== X13: blockers advance as paperwork arrives (TIN -> W-9 -> address) ==='
-- Each fix must reveal the NEXT problem, not report "ready to file" early.
SELECT set_party_identifier(:'pd'::uuid, 'ssn', '123-45-' || lpad((:'run'::bigint % 10000)::text,4,'0')) AS sid \gset
SELECT CASE WHEN (SELECT blocker FROM form_1099_extract(2025::smallint)
                   WHERE party_id = :'pd'::uuid) = 'NO W-9 ON FILE'
            THEN 'PASS: with a TIN on file the blocker advances to the W-9'
            ELSE 'FAIL: got ' || COALESCE((SELECT blocker FROM form_1099_extract(2025::smallint)
                                            WHERE party_id = :'pd'::uuid),'NULL')
       END AS x13;

INSERT INTO payee_tax_profile (party_id, w9_received_date, tin_type)
VALUES (:'pd'::uuid, '2025-01-15', 'ssn')
ON CONFLICT (party_id) DO UPDATE SET w9_received_date = '2025-01-15', tin_type = 'ssn';
SELECT CASE WHEN (SELECT blocker FROM form_1099_extract(2025::smallint)
                   WHERE party_id = :'pd'::uuid) = 'NO RECIPIENT ADDRESS'
            THEN 'PASS: with a W-9 on file the blocker advances to the address'
            ELSE 'FAIL: got ' || COALESCE((SELECT blocker FROM form_1099_extract(2025::smallint)
                                            WHERE party_id = :'pd'::uuid),'NULL')
       END AS x13b;

UPDATE payee_tax_profile SET recipient_address = '1 Test Street, Testville TX 75001'
 WHERE party_id = :'pd'::uuid;
SELECT CASE WHEN (SELECT blocker FROM form_1099_extract(2025::smallint)
                   WHERE party_id = :'pd'::uuid) IS NULL
            THEN 'PASS: complete paperwork clears all blockers'
            ELSE 'FAIL: still blocked on ' || (SELECT blocker FROM form_1099_extract(2025::smallint)
                                                WHERE party_id = :'pd'::uuid)
       END AS x13c;

\echo '=== X14: form_1099_exceptions lists only reportable payees that are blocked ==='
-- A blocked payee UNDER the threshold is not an exception: there is nothing
-- to file, so chasing their paperwork is wasted effort.
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM form_1099_exceptions(2026::smallint)
                              WHERE party_id = :'pd'::uuid)
            THEN 'PASS: sub-threshold payee is not an exception'
            ELSE 'FAIL: sub-threshold payee reported as an exception'
       END AS x14;

\echo '=== X15: exempt payees never appear in the extract ==='
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM form_1099_extract(2025::smallint)
                              WHERE party_id = :'pc'::uuid)
            THEN 'PASS: exempt corporation absent from the extract'
            ELSE 'FAIL: exempt corporation present in the extract'
       END AS x15;

\echo '=== X16: v_1099_summary agrees with the detail rows ==='
SELECT CASE WHEN (SELECT total_paid FROM v_1099_summary
                   WHERE tax_year = 2025 AND form_code = '1099-NEC')
            = (SELECT sum(amount) FROM tax_year_payment
                WHERE tax_year = 2025 AND form_code = '1099-NEC')
            THEN 'PASS: summary view ties to the payment detail'
            ELSE 'FAIL: summary view does not tie to detail'
       END AS x16;

\echo '=== X17: zero-amount payments record nothing ==='
SELECT CASE WHEN record_reportable_payment(:'pa'::uuid, '2025-06-01', 0,
                                           'consignor_payout', NULL, NULL,
                                           'tx-zero-' || :'run') IS NULL
            THEN 'PASS: a zero payment is not recorded'
            ELSE 'FAIL: zero payment created a row'
       END AS x17;
