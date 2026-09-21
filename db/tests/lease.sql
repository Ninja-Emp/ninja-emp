-- ============================================================================
-- Ninja EMP — lease.sql
-- Proves percentage-rent true-up, CAM reconciliation, renewals and
-- escalations (ADR-0035).
--
-- What this suite is really defending:
--   * percentage rent applies only ABOVE the breakpoint, and never refunds
--   * refunds REDUCE the sales base (or the tenant is billed on returned goods)
--   * re-running a true-up does not double-bill
--   * the CAM pro-rata denominator excludes VACANT space, so occupied tenants
--     do not silently subsidise the landlord's empty units
--   * non-recoverable costs stay out of the pool
--   * over-recovery is credited back, not quietly kept
--   * escalations are EFFECTIVE-DATED, never overwrites
--   * every posting leaves the trial balance at zero
--
-- Delta-based assertions against a baseline, so the suite is re-runnable.
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/lease.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';

SELECT floor(random()*1000000000)::text AS run \gset

-- ---- Seed: an isolated location so pro-rata maths is not polluted by the
-- ---- spaces other suites create.
INSERT INTO location (code, name, city, region)
VALUES ('CAM-' || :'run', 'CAM Test Center', 'Springfield', 'IL')
RETURNING id AS loc \gset
INSERT INTO floor (location_id, code, name, level_no)
VALUES (:'loc'::uuid, 'L1', 'Level 1', 1) RETURNING id AS flr \gset

-- Two leased spaces (1000 + 3000 sqft) and one VACANT space (6000 sqft).
-- The vacant unit is the whole point of L8.
INSERT INTO space (floor_id, code, name, space_type_code, area_sqft, status)
VALUES (:'flr'::uuid, 'S1-' || :'run', 'Unit 1', 'inline', 1000.00, 'available')
RETURNING id AS sp1 \gset
INSERT INTO space (floor_id, code, name, space_type_code, area_sqft, status)
VALUES (:'flr'::uuid, 'S2-' || :'run', 'Unit 2', 'inline', 3000.00, 'available')
RETURNING id AS sp2 \gset
INSERT INTO space (floor_id, code, name, space_type_code, area_sqft, status)
VALUES (:'flr'::uuid, 'S3-' || :'run', 'Vacant Unit', 'inline', 6000.00, 'available')
RETURNING id AS sp3 \gset

INSERT INTO party (party_type, display_name)
VALUES ('organization', 'Pct Rent Tenant ' || :'run') RETURNING id AS t1 \gset
INSERT INTO party (party_type, display_name)
VALUES ('organization', 'CAM Tenant Two ' || :'run') RETURNING id AS t2 \gset

INSERT INTO lease (lessee_party_id, location_id, status, start_date, end_date, billing_day)
VALUES (:'t1'::uuid, :'loc'::uuid, 'active', '2026-01-01', '2026-12-31', 1)
RETURNING id AS l1 \gset
-- Tenant two's term runs through 2027 so it is still in scope for the 2027
-- CAM pool used by L14. cam_reconciliation() correctly excludes leases whose
-- term does not overlap the pool period.
INSERT INTO lease (lessee_party_id, location_id, status, start_date, end_date, billing_day)
VALUES (:'t2'::uuid, :'loc'::uuid, 'active', '2026-01-01', '2027-12-31', 1)
RETURNING id AS l2 \gset

INSERT INTO lease_space (lease_id, space_id, allocated_area_sqft, from_date)
VALUES (:'l1'::uuid, :'sp1'::uuid, 1000.00, '2026-01-01');
INSERT INTO lease_space (lease_id, space_id, allocated_area_sqft, from_date)
VALUES (:'l2'::uuid, :'sp2'::uuid, 3000.00, '2026-01-01');

-- Percentage rent: 5% of sales above a 50,000 annual breakpoint.
INSERT INTO rent_component (lease_id, component_type_code, percent_rate,
                            breakpoint_amount, billing_frequency, effective_from)
VALUES (:'l1'::uuid, 'percentage_rent', 0.05, 50000.00, 'annual', '2026-01-01');
INSERT INTO rent_component (lease_id, component_type_code, amount,
                            billing_frequency, effective_from)
VALUES (:'l1'::uuid, 'base_rent', 2000.00, 'monthly', '2026-01-01');

SELECT coalesce(sum(debit-credit),0) AS tb_before FROM journal_line \gset

\echo '=== L1: below the breakpoint, nothing is due ==='
-- A tenant under the breakpoint owes zero, not a negative. Percentage rent is
-- not a rebate on base rent.
SELECT CASE WHEN percentage_rent_due(:'l1'::uuid, '2026-01-01', '2026-12-31', 40000.00) = 0
            THEN 'PASS: 40,000 of sales against a 50,000 breakpoint owes nothing'
            ELSE 'FAIL: got ' ||
                 percentage_rent_due(:'l1'::uuid,'2026-01-01','2026-12-31',40000.00)::text
       END AS l1;

\echo '=== L2: only the EXCESS over the breakpoint is charged ==='
-- 80,000 sales - 50,000 breakpoint = 30,000 excess @ 5% = 1,500.
-- Charging 5% of the full 80,000 (4,000) is the classic error.
SELECT CASE WHEN percentage_rent_due(:'l1'::uuid, '2026-01-01', '2026-12-31', 80000.00) = 1500.00
            THEN 'PASS: 5% of the 30,000 excess = 1,500.00 (not 5% of gross)'
            ELSE 'FAIL: got ' ||
                 percentage_rent_due(:'l1'::uuid,'2026-01-01','2026-12-31',80000.00)::text
       END AS l2;

\echo '=== L3: posting the true-up balances and hits percentage rent revenue ==='
SELECT post_percentage_rent_trueup(:'l1'::uuid, '2026-01-01', '2026-12-31',
         '2026-12-31', 'pct-' || :'run', 80000.00) AS pct \gset
SELECT CASE WHEN (SELECT sum(jl.credit) FROM journal_line jl
                   WHERE jl.journal_entry_id = :'pct'::uuid
                     AND jl.account_id = posting_account('percentage_rent_revenue')) = 1500.00
             AND (SELECT sum(debit) - sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'pct'::uuid) = 0
            THEN 'PASS: 1,500.00 credited to percentage rent revenue, entry balances'
            ELSE 'FAIL: true-up did not post correctly'
       END AS l3;

\echo '=== L4: the true-up opens an AR item for the lessee ==='
SELECT CASE WHEN (SELECT count(*) FROM open_item
                   WHERE journal_entry_id = :'pct'::uuid
                     AND party_id = :'t1'::uuid
                     AND subledger_type_code = 'ar') = 1
            THEN 'PASS: percentage rent opened one AR item'
            ELSE 'FAIL: no AR open item created'
       END AS l4;

\echo '=== L5: re-running the SAME period does not double-bill ==='
-- Two defences must both hold: the idempotency key, and the already-billed
-- subtraction inside percentage_rent_due().
SELECT post_percentage_rent_trueup(:'l1'::uuid, '2026-01-01', '2026-12-31',
         '2026-12-31', 'pct-' || :'run', 80000.00) AS pct2 \gset
SELECT CASE WHEN :'pct'::uuid = :'pct2'::uuid
             AND (SELECT count(*) FROM journal_entry
                   WHERE source = 'percentage_rent'
                     AND source_ref = :'l1'::text) = 1
            THEN 'PASS: replay returned the original entry; only one posting exists'
            ELSE 'FAIL: the true-up was billed twice'
       END AS l5;

\echo '=== L6: a NEW idempotency key still does not re-bill an already-billed period ==='
-- This is the assertion that matters operationally. An operator re-running
-- year end with a fresh key must not be able to bill the tenant twice.
-- Asserted on the observable effect (no second entry, no extra revenue)
-- rather than on the returned NULL: psql's \gset UNSETS a variable when the
-- value is NULL, so :'pct3' would not substitute at all.
SELECT post_percentage_rent_trueup(:'l1'::uuid, '2026-01-01', '2026-12-31',
         '2026-12-31', 'pct-again-' || :'run', 80000.00);
SELECT CASE WHEN (SELECT count(*) FROM journal_entry
                   WHERE source = 'percentage_rent'
                     AND source_ref = :'l1'::text) = 1
             AND (SELECT sum(jl.credit) FROM journal_line jl
                    JOIN journal_entry je ON je.id = jl.journal_entry_id
                   WHERE je.source = 'percentage_rent'
                     AND je.source_ref = :'l1'::text
                     AND jl.account_id = posting_account('percentage_rent_revenue')) = 1500.00
            THEN 'PASS: a new key did NOT re-bill the already-billed period'
            ELSE 'FAIL: a new key re-billed the same period'
       END AS l6;

\echo '=== L7: refunds reduce the POS sales base ==='
-- Without this, a tenant who sells 10,000 and refunds 10,000 is billed
-- percentage rent on goods that came back.
INSERT INTO sale (customer_party_id, sale_date, subtotal, discount_total, tax_total, total, status)
VALUES (NULL, '2026-06-01', 1000.00, 0, 0, 1000.00, 'completed') RETURNING id AS s1 \gset
INSERT INTO sale_line (sale_id, line_no, line_kind, vendor_party_id, description,
                       quantity, unit_price, discount_amount, extended_price, is_taxable)
VALUES (:'s1'::uuid, 1, 'owned', :'t1'::uuid, 'Vendor goods', 1, 1000.00, 0, 1000.00, false);

INSERT INTO sale (customer_party_id, sale_date, subtotal, discount_total, tax_total, total,
                  status, is_refund, refunds_sale_id)
VALUES (NULL, '2026-06-02', 400.00, 0, 0, 400.00, 'completed', true, :'s1'::uuid)
RETURNING id AS s2 \gset
INSERT INTO sale_line (sale_id, line_no, line_kind, vendor_party_id, description,
                       quantity, unit_price, discount_amount, extended_price, is_taxable)
VALUES (:'s2'::uuid, 1, 'owned', :'t1'::uuid, 'Returned goods', 1, 400.00, 0, 400.00, false);

SELECT CASE WHEN lease_pos_sales(:'l1'::uuid, '2026-01-01', '2026-12-31') = 600.00
            THEN 'PASS: 1000 sold less 400 refunded = 600 net sales base'
            ELSE 'FAIL: got ' ||
                 lease_pos_sales(:'l1'::uuid,'2026-01-01','2026-12-31')::text
       END AS l7;

\echo '=== L8: CAM pro-rata EXCLUDES vacant space ==='
-- 1000 leased of 4000 LEASED sqft = 25%. If the 6000 sqft vacant unit were in
-- the denominator it would be 10%, and the landlord would eat the difference
-- on their own empty space by accident rather than by decision.
SELECT CASE WHEN round(lease_pro_rata_share(:'l1'::uuid, :'loc'::uuid, '2026-12-31'), 4) = 0.2500
            THEN 'PASS: share is 25% of LEASED area, vacant unit excluded'
            ELSE 'FAIL: got ' ||
                 round(lease_pro_rata_share(:'l1'::uuid,:'loc'::uuid,'2026-12-31'),4)::text
       END AS l8;

\echo '=== L9: non-recoverable costs stay out of the pool ==='
INSERT INTO cam_pool (location_id, pool_year, period_start, period_end, admin_fee_rate)
VALUES (:'loc'::uuid, 2026, '2026-01-01', '2026-12-31', 0.10) RETURNING id AS pool \gset
INSERT INTO cam_pool_expense (cam_pool_id, expense_date, category, amount)
VALUES (:'pool'::uuid, '2026-03-01', 'landscaping', 10000.00);
INSERT INTO cam_pool_expense (cam_pool_id, expense_date, category, amount)
VALUES (:'pool'::uuid, '2026-04-01', 'security', 10000.00);
-- A new roof is a capital improvement, not a recoverable operating cost.
INSERT INTO cam_pool_expense (cam_pool_id, expense_date, category, amount,
                              is_recoverable, exclusion_reason)
VALUES (:'pool'::uuid, '2026-05-01', 'roof replacement', 50000.00,
        false, 'Capital improvement, excluded per lease s.7.2');

SELECT CASE WHEN (SELECT recoverable_pool FROM cam_reconciliation(:'pool'::uuid)
                   WHERE lease_id = :'l1'::uuid) = 20000.00
            THEN 'PASS: 50,000 capital item excluded; pool is 20,000'
            ELSE 'FAIL: got ' || COALESCE((SELECT recoverable_pool FROM cam_reconciliation(:'pool'::uuid)
                                            WHERE lease_id = :'l1'::uuid)::text,'NULL')
       END AS l9;

\echo '=== L10: admin fee is applied on the recoverable pool only ==='
-- 20,000 recoverable + 10% admin = 22,000 total; 25% share = 5,500.
SELECT CASE WHEN (SELECT admin_fee FROM cam_reconciliation(:'pool'::uuid)
                   WHERE lease_id = :'l1'::uuid) = 2000.00
             AND (SELECT share_of_pool FROM cam_reconciliation(:'pool'::uuid)
                   WHERE lease_id = :'l1'::uuid) = 5500.00
            THEN 'PASS: admin fee 2,000 on recoverable only; 25% share = 5,500'
            ELSE 'FAIL: admin fee or share incorrect'
       END AS l10;

\echo '=== L11: shares across all leases sum to the whole pool ==='
-- 25% + 75% must be 100%. A rounding or denominator bug shows up here as the
-- landlord under- or over-recovering against themselves.
SELECT CASE WHEN (SELECT round(sum(pro_rata_share),4) FROM cam_reconciliation(:'pool'::uuid)) = 1.0000
            THEN 'PASS: pro-rata shares sum to exactly 100%'
            ELSE 'FAIL: shares sum to ' ||
                 (SELECT round(sum(pro_rata_share),4) FROM cam_reconciliation(:'pool'::uuid))::text
       END AS l11;

\echo '=== L12: under-recovery is billed to AR and balances ==='
-- No CAM estimates were billed during the year, so the whole 5,500 is owed.
SELECT post_cam_reconciliation(:'pool'::uuid, :'l1'::uuid, '2026-12-31',
                               'cam-' || :'run') AS cam \gset
SELECT CASE WHEN (SELECT sum(jl.credit) FROM journal_line jl
                   WHERE jl.journal_entry_id = :'cam'::uuid
                     AND jl.account_id = posting_account('cam_revenue')) = 5500.00
             AND (SELECT sum(debit) - sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'cam'::uuid) = 0
            THEN 'PASS: 5,500 CAM under-recovery billed, entry balances'
            ELSE 'FAIL: CAM true-up did not post correctly'
       END AS l12;

\echo '=== L13: re-running the CAM true-up is idempotent ==='
SELECT post_cam_reconciliation(:'pool'::uuid, :'l1'::uuid, '2026-12-31',
                               'cam-' || :'run') AS cam2 \gset
SELECT CASE WHEN :'cam'::uuid = :'cam2'::uuid
            THEN 'PASS: CAM re-run returned the original entry'
            ELSE 'FAIL: CAM true-up posted twice'
       END AS l13;

\echo '=== L14: over-recovery is CREDITED back, not kept ==='
-- Tenant two has a 75% share (16,500) but we simulate estimates already
-- billed well above it, so the reconciliation must move money the other way.
-- Uses 2027 because the seeded fiscal calendar covers 2026-2027 only, and
-- post_journal_entry() correctly refuses an entry_date with no open period.
INSERT INTO cam_pool (location_id, pool_year, period_start, period_end, admin_fee_rate)
VALUES (:'loc'::uuid, 2027, '2027-01-01', '2027-12-31', 0) RETURNING id AS pool27 \gset
INSERT INTO cam_pool_expense (cam_pool_id, expense_date, category, amount)
VALUES (:'pool27'::uuid, '2027-03-01', 'landscaping', 1000.00);
-- Bill an estimate far above the eventual actual.
SELECT post_journal_entry('2027-06-01', 'CAM estimate', 'rent', :'l2'::text,
  'camest-' || :'run',
  jsonb_build_array(
    jsonb_build_object('account_id', posting_account('ar_control'),
                       'debit', 5000.00, 'party_id', :'t2'::text,
                       'subledger_type_code','ar','memo','CAM estimate'),
    jsonb_build_object('account_id', posting_account('cam_revenue'),
                       'credit', 5000.00, 'memo','CAM estimate'))) AS est \gset

-- The estimate debits AR CONTROL, so it MUST have an open item behind it.
-- Without this the fixture leaves 5,000 of receivable in the GL that appears
-- on no customer statement, and open_item_control_check() is permanently out
-- by 5,000 -- a test fixture manufacturing the exact orphaned-balance defect
-- the suite exists to catch. A fixture that breaks an invariant is not a
-- shortcut, it is a false negative waiting to hide a real bug.
SELECT open_item_create('ar', :'t2'::uuid, 'rent', :'l2'::text,
                        'CAMEST-' || :'run', 5000.00, 'USD',
                        '2027-06-01', '2027-07-01', :'est'::uuid) AS estoi \gset

SELECT post_cam_reconciliation(:'pool27'::uuid, :'l2'::uuid, '2027-12-31',
                               'camcr-' || :'run') AS camcr \gset
SELECT CASE WHEN (SELECT sum(jl.debit) FROM journal_line jl
                   WHERE jl.journal_entry_id = :'camcr'::uuid
                     AND jl.account_id = posting_account('cam_revenue')) > 0
             AND (SELECT sum(debit) - sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'camcr'::uuid) = 0
            THEN 'PASS: over-recovery debited CAM revenue back to the tenant'
            ELSE 'FAIL: over-recovery was not credited back'
       END AS l14;

\echo '=== L15: renewal extends the term in place ==='
-- In place, so AR history, the deposit and the space allocation stay attached
-- to one continuous agreement.
SELECT renew_lease(:'l1'::uuid, '2027-12-31') AS rn \gset
SELECT CASE WHEN (SELECT end_date FROM lease WHERE id = :'l1'::uuid) = '2027-12-31'
             AND (SELECT count(*) FROM lease WHERE lessee_party_id = :'t1'::uuid) = 1
            THEN 'PASS: term extended to 2027-12-31 on the same lease row'
            ELSE 'FAIL: renewal did not extend in place'
       END AS l15;

\echo '=== L16: a renewal cannot move the end date BACKWARDS ==='
DO $$
DECLARE v_lease uuid;
BEGIN
  SELECT id INTO v_lease FROM lease WHERE end_date = '2027-12-31' ORDER BY created_at DESC LIMIT 1;
  PERFORM renew_lease(v_lease, '2026-06-30');
  RAISE NOTICE 'FAIL: a backwards renewal was accepted';
EXCEPTION
  WHEN check_violation THEN RAISE NOTICE 'PASS: backwards renewal rejected';
  WHEN OTHERS THEN RAISE NOTICE 'FAIL: unexpected %', SQLERRM;
END $$;

\echo '=== L17: escalation EFFECTIVE-DATES rather than overwriting ==='
-- The old 2000.00 row must survive with a closed end date, or last year's
-- invoices become unreproducible.
SELECT apply_rent_escalation(:'l1'::uuid, 0.03, '2027-01-01') AS esc \gset
SELECT CASE WHEN (SELECT count(*) FROM rent_component
                   WHERE lease_id = :'l1'::uuid AND component_type_code = 'base_rent') = 2
             AND (SELECT amount FROM rent_component
                   WHERE lease_id = :'l1'::uuid AND component_type_code = 'base_rent'
                     AND effective_from = '2027-01-01') = 2060.00
             AND (SELECT effective_thru FROM rent_component
                   WHERE lease_id = :'l1'::uuid AND component_type_code = 'base_rent'
                     AND effective_from = '2026-01-01') = '2026-12-31'
            THEN 'PASS: old row closed at 2026-12-31, new row 2,060.00 from 2027-01-01'
            ELSE 'FAIL: escalation did not effective-date correctly'
       END AS l17;

\echo '=== L18: escalation leaves percentage_rent alone ==='
-- Escalating a fixed amount and escalating a rate are different negotiations.
SELECT CASE WHEN (SELECT count(*) FROM rent_component
                   WHERE lease_id = :'l1'::uuid
                     AND component_type_code = 'percentage_rent') = 1
             AND (SELECT percent_rate FROM rent_component
                   WHERE lease_id = :'l1'::uuid
                     AND component_type_code = 'percentage_rent') = 0.05
            THEN 'PASS: percentage rent rate untouched by escalation'
            ELSE 'FAIL: escalation altered the percentage rent clause'
       END AS l18;

\echo '=== L19: an escalation that would make rent negative is refused ==='
DO $$
DECLARE v_lease uuid;
BEGIN
  SELECT id INTO v_lease FROM lease WHERE end_date = '2027-12-31' ORDER BY created_at DESC LIMIT 1;
  PERFORM apply_rent_escalation(v_lease, -1.5, '2028-01-01');
  RAISE NOTICE 'FAIL: a rate below -100%% was accepted';
EXCEPTION
  WHEN check_violation THEN RAISE NOTICE 'PASS: escalation below -100%% rejected';
  WHEN OTHERS THEN RAISE NOTICE 'FAIL: unexpected %', SQLERRM;
END $$;

\echo '=== L20: the ledger still balances after every lease posting ==='
SELECT CASE WHEN coalesce(sum(debit-credit),0) = 0
            THEN 'PASS: trial balance is zero after all lease postings'
            ELSE 'FAIL: trial balance drifted to ' || coalesce(sum(debit-credit),0)::text
       END AS l20
  FROM journal_line;
