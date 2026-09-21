-- ============================================================================
-- Ninja EMP — retail.sql
-- Proves the markdown engine, layaway, and percentage-commission true-ups
-- (ADR-0036, ADR-0037).
--
-- What this suite is really defending:
--
--   MARKDOWNS
--     * a markdown is an EVENT, not a price overwrite — history survives
--     * prices only go DOWN through this door; an increase cannot be smuggled
--       through the markdown table to dodge the approval trail
--     * WHO ABSORBS the reduction is recorded, not assumed, because it has a
--       cash consequence and it is the thing consignors dispute
--     * a store-absorbed markdown keeps the consignor whole; a
--       consignor-absorbed one does not
--     * marking down posts NO journal entry — nothing economic has happened
--
--   LAYAWAY
--     * a deposit is a LIABILITY, never revenue. This is the whole ADR.
--     * goods on layaway are RESERVED and cannot be sold twice
--     * a CANCELLED layaway frees the goods again (they are not bricked)
--     * at pickup the liability becomes revenue and cash is NOT re-counted
--     * a forfeited cancellation fee IS income; the refund is not
--     * the control account equals the sum of open deposits
--
--   COMMISSION TRUE-UP
--     * a tiered schedule can actually be STORED (see R27 — it could not)
--     * tiers are MARGINAL, so the store's commission never falls when sales
--       rise
--     * refunds reduce the base, across BOTH the POS and consignment paths
--     * an adjustment of zero posts nothing
--     * sign discipline: over-charge credits the consignor, under-charge
--       credits the store
--     * re-running a period does not double-adjust
--
-- Delta-based assertions against a baseline, so the suite is re-runnable.
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/retail.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;
SET app.tenant_id = '11111111-1111-7111-8111-111111111111';
SET app.actor_id  = '99999999-9999-7999-8999-999999999999';

SELECT floor(random()*1000000000)::text AS run \gset

-- ---------------------------------------------------------------------------
-- Seed. Every scenario gets its OWN consignor.
--
-- This is not tidiness. complete_layaway() writes a consignment sale_line, and
-- commission_period_actuals() sums sale lines by consignor. Sharing one
-- consignor between the layaway scenarios and the true-up scenarios would make
-- the layaway pickups silently move the commission arithmetic, and the suite
-- would be asserting on numbers it did not intend.
-- ---------------------------------------------------------------------------
INSERT INTO party (party_type, display_name)
VALUES ('person', 'Markdown Consignor ' || :'run') RETURNING id AS pm \gset
INSERT INTO party (party_type, display_name)
VALUES ('person', 'Layaway Consignor ' || :'run') RETURNING id AS pl \gset
INSERT INTO party (party_type, display_name)
VALUES ('person', 'Trueup Consignor A ' || :'run') RETURNING id AS pa \gset
INSERT INTO party (party_type, display_name)
VALUES ('person', 'Trueup Consignor B ' || :'run') RETURNING id AS pb \gset
INSERT INTO party (party_type, display_name)
VALUES ('person', 'Trueup Consignor C ' || :'run') RETURNING id AS pc \gset
INSERT INTO party (party_type, display_name)
VALUES ('person', 'Layaway Customer ' || :'run') RETURNING id AS cust \gset

INSERT INTO consignor_agreement (consignor_party_id, default_commission_rate, start_date)
VALUES (:'pm'::uuid, 0.40, '2026-01-01') RETURNING id AS agm \gset
INSERT INTO consignor_agreement (consignor_party_id, default_commission_rate, start_date)
VALUES (:'pl'::uuid, 0.40, '2026-01-01') RETURNING id AS agl \gset
INSERT INTO consignor_agreement (consignor_party_id, default_commission_rate, start_date)
VALUES (:'pa'::uuid, 0.40, '2026-01-01') RETURNING id AS aga \gset
INSERT INTO consignor_agreement (consignor_party_id, default_commission_rate, start_date)
VALUES (:'pb'::uuid, 0.40, '2026-01-01') RETURNING id AS agb \gset
INSERT INTO consignor_agreement (consignor_party_id, default_commission_rate, start_date)
VALUES (:'pc'::uuid, 0.40, '2026-01-01') RETURNING id AS agc \gset

SELECT coalesce(sum(debit-credit),0) AS tb_before FROM journal_line \gset
SELECT count(*) AS je_before FROM journal_entry \gset

-- psql does NOT interpolate :vars inside dollar-quoted bodies, so anything a
-- DO block needs has to be handed over through a GUC. Several assertions below
-- must be DO blocks because they prove that an operation is REFUSED, and that
-- requires catching the exception.
SELECT set_config('app.t_run',  :'run',        false);
SELECT set_config('app.t_cust', :'cust',       false);
SELECT set_config('app.t_aga',  :'aga',        false);

-- ============================================================================
-- PART 1 — MARKDOWNS
-- ============================================================================

INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'agm'::uuid, 'Store-absorbed jacket', 100.00, 'available', '2026-01-05')
RETURNING id AS mi1 \gset
INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'agm'::uuid, 'Consignor-absorbed lamp', 100.00, 'available', '2026-01-05')
RETURNING id AS mi2 \gset
INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'agm'::uuid, 'Shared clearance rug', 100.00, 'available', '2026-01-05')
RETURNING id AS mi3 \gset
INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'agm'::uuid, 'Twice-marked chair', 100.00, 'available', '2026-01-05')
RETURNING id AS mi4 \gset

SELECT count(*) AS je_pre_md FROM journal_entry \gset
SELECT set_config('app.t_mi1', :'mi1', false);
SELECT set_config('app.t_mi4', :'mi4', false);

\echo '=== R1: a markdown moves the price AND leaves an event plus price history ==='
SELECT apply_markdown(:'mi1'::uuid, 80.00, 'promotion', NULL, NULL, '2026-02-01') AS md1 \gset
SELECT CASE WHEN (SELECT agreed_price FROM consignment_item WHERE id = :'mi1'::uuid) = 80.00
             AND (SELECT count(*) FROM markdown_event WHERE consignment_item_id = :'mi1'::uuid) = 1
             AND (SELECT count(*) FROM item_price_change
                   WHERE item_id = :'mi1'::uuid AND reason = 'markdown:promotion') = 1
            THEN 'PASS: price moved to 80.00, one event and one price-history row recorded'
            ELSE 'FAIL: markdown did not record both the event and the history'
       END AS r1;

\echo '=== R2: a markdown cannot raise a price ==='
-- The lazy implementation is an UPDATE on the price. If that is the only
-- control, "markdown" becomes the unaudited back door for price increases.
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM apply_markdown(current_setting('app.t_mi1')::uuid, 999.00, 'promotion');
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF v_ok THEN RAISE NOTICE 'PASS: a price INCREASE was rejected by apply_markdown';
  ELSE RAISE NOTICE 'FAIL: apply_markdown accepted a price increase';
  END IF;
END $$;

\echo '=== R3: markdown_event is append-only ==='
SELECT set_config('app.t_md1', :'md1', false);
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN
    UPDATE markdown_event SET new_price = 1.00
     WHERE id = current_setting('app.t_md1')::uuid;
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF v_ok THEN RAISE NOTICE 'PASS: editing a markdown event was refused';
  ELSE RAISE NOTICE 'FAIL: a markdown event was edited after the fact';
  END IF;
END $$;

\echo '=== R4: absorption defaults come from the REASON, not from the caller ==='
-- 'promotion' is the store's own decision, so the store pays. 'aged' is a
-- term the consignor already agreed to, so the consignor pays.
SELECT apply_markdown(:'mi2'::uuid, 80.00, 'aged', NULL, NULL, '2026-02-01') AS md2 \gset
SELECT CASE WHEN (SELECT absorbed_by FROM markdown_event WHERE id = :'md1'::uuid) = 'store'
             AND (SELECT absorbed_by FROM markdown_event WHERE id = :'md2'::uuid) = 'consignor'
            THEN 'PASS: promotion defaulted to store, aged defaulted to consignor'
            ELSE 'FAIL: absorption defaults did not follow the reason'
       END AS r4;

\echo '=== R5: a STORE-absorbed markdown keeps the consignor whole ==='
-- Item ticketed 100, sold at 80, store ate the 20. The consignor is still
-- settled on 100. If this returns 80 the store has quietly passed its own
-- promotion on to the consignor.
SELECT CASE WHEN consignor_price_floor(:'mi1'::uuid) = 100.00
            THEN 'PASS: consignor still settled on 100.00 after a store-absorbed cut'
            ELSE 'FAIL: got ' || consignor_price_floor(:'mi1'::uuid)::text
       END AS r5;

\echo '=== R6: a CONSIGNOR-absorbed markdown does NOT keep them whole ==='
SELECT CASE WHEN consignor_price_floor(:'mi2'::uuid) = 80.00
            THEN 'PASS: consignor settled on the reduced 80.00, as agreed'
            ELSE 'FAIL: got ' || consignor_price_floor(:'mi2'::uuid)::text
       END AS r6;

\echo '=== R7: a SHARED markdown splits by the stored rate ==='
-- 100 -> 60 is a 40 gap, split 50/50, so the store absorbs 20 and the
-- consignor floor is 60 + 20 = 80.
SELECT apply_markdown(:'mi3'::uuid, 60.00, 'clearance', 'shared', 0.5, '2026-02-01') AS md3 \gset
SELECT CASE WHEN consignor_price_floor(:'mi3'::uuid) = 80.00
             AND (SELECT share_store_rate FROM markdown_event WHERE id = :'md3'::uuid) = 0.5
            THEN 'PASS: 40.00 gap split 50/50; consignor floor is 80.00'
            ELSE 'FAIL: got floor ' || consignor_price_floor(:'mi3'::uuid)::text
       END AS r7;

\echo '=== R8: shared absorption without a split rate is rejected ==='
-- "Shared" with no ratio is not a policy, it is an argument waiting to happen.
DO $$
DECLARE v_ok boolean := false; v_item uuid := current_setting('app.t_mi4')::uuid;
BEGIN
  BEGIN
    INSERT INTO markdown_event (consignment_item_id, reason_code, old_price, new_price,
                                absorbed_by, share_store_rate)
    VALUES (v_item, 'clearance', 100.00, 90.00, 'shared', NULL);
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF v_ok THEN RAISE NOTICE 'PASS: shared absorption with no split rate was rejected';
  ELSE RAISE NOTICE 'FAIL: a shared markdown was stored without a split';
  END IF;
END $$;

\echo '=== R9: absorption accumulates across SUCCESSIVE markdowns ==='
-- 100 -> 80 (store eats 20), then 80 -> 60 (consignor eats 20). The original
-- ticket price must still be recoverable: this is the number that settles the
-- dispute, and a price-overwrite design has destroyed it by now.
SELECT apply_markdown(:'mi4'::uuid, 80.00, 'promotion', NULL, NULL, '2026-02-01');
SELECT apply_markdown(:'mi4'::uuid, 60.00, 'aged', NULL, NULL, '2026-03-01');
SELECT CASE WHEN original_price = 100.00 AND current_price = 60.00
             AND total_markdown = 40.00
             AND store_absorbed = 20.00 AND consignor_absorbed = 20.00
            THEN 'PASS: original 100 preserved; 40.00 total split 20 store / 20 consignor'
            ELSE 'FAIL: got orig ' || original_price::text || ' store ' || store_absorbed::text
       END AS r9
  FROM markdown_absorption(:'mi4'::uuid);

\echo '=== R10: marking an item down posts NO journal entry ==='
-- Nothing has been bought, sold, or paid. Booking a markdown expense here
-- would expense goods that may never sell AND double-count against the lower
-- revenue actually recognised at sale.
SELECT CASE WHEN (SELECT count(*) FROM journal_entry) = :'je_pre_md'::bigint
            THEN 'PASS: five markdowns produced zero journal entries'
            ELSE 'FAIL: a markdown posted to the ledger'
       END AS r10;

-- ============================================================================
-- PART 2 — LAYAWAY
-- ============================================================================

INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'agl'::uuid, 'Layaway pickup item', 300.00, 'available', '2026-01-05')
RETURNING id AS li1 \gset
INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'agl'::uuid, 'Layaway cancel item', 500.00, 'available', '2026-01-05')
RETURNING id AS li2 \gset
SELECT set_config('app.t_li1', :'li1', false);

\echo '=== R11: opening a layaway RESERVES the goods ==='
SELECT open_layaway(:'cust'::uuid,
  jsonb_build_array(jsonb_build_object(
    'description','Layaway pickup item','quantity',1,'unit_price',300.00,
    'consignment_item_id', :'li1'::text)),
  '2026-06-30', 0, '2026-03-01') AS lay1 \gset
SELECT CASE WHEN (SELECT status FROM consignment_item WHERE id = :'li1'::uuid) = 'reserved'
             AND (SELECT total FROM layaway WHERE id = :'lay1'::uuid) = 300.00
            THEN 'PASS: item is reserved and the layaway totals 300.00'
            ELSE 'FAIL: item was not reserved or the total is wrong'
       END AS r11;
SELECT set_config('app.t_lay1', :'lay1', false);

\echo '=== R12: the same item cannot be put on a second layaway ==='
-- Two customers paying deposits on the same one-of-a-kind item is discovered
-- at pickup, which is the worst possible moment.
DO $$
DECLARE v_ok boolean := false; v_item uuid := current_setting('app.t_li1')::uuid;
BEGIN
  BEGIN
    PERFORM open_layaway(current_setting('app.t_cust')::uuid,
      jsonb_build_array(jsonb_build_object(
        'description','Double booked','quantity',1,'unit_price',300.00,
        'consignment_item_id', v_item::text)),
      NULL, 0, DATE '2026-03-02');
  EXCEPTION WHEN check_violation OR unique_violation THEN v_ok := true; END;
  IF v_ok THEN RAISE NOTICE 'PASS: double-reserving a consigned item was refused';
  ELSE RAISE NOTICE 'FAIL: the same item was reserved on two layaways';
  END IF;
END $$;

\echo '=== R12b: the reservation guard holds even if the status check is bypassed ==='
-- Defence in depth. open_layaway() refuses on status, but status is a column
-- anyone can UPDATE. The trigger is the control that actually cannot be
-- talked around, so it must be tested with the first guard disarmed.
DO $$
DECLARE v_ok boolean := false; v_item uuid := current_setting('app.t_li1')::uuid;
BEGIN
  UPDATE consignment_item SET status = 'available' WHERE id = v_item;
  BEGIN
    PERFORM open_layaway(current_setting('app.t_cust')::uuid,
      jsonb_build_array(jsonb_build_object(
        'description','Sneaked past the status check','quantity',1,'unit_price',300.00,
        'consignment_item_id', v_item::text)),
      NULL, 0, DATE '2026-03-02');
  EXCEPTION WHEN unique_violation THEN v_ok := true; END;
  UPDATE consignment_item SET status = 'reserved' WHERE id = v_item;
  IF v_ok THEN RAISE NOTICE 'PASS: the trigger caught the double reservation on its own';
  ELSE RAISE NOTICE 'FAIL: only the status check was preventing double reservation';
  END IF;
END $$;

\echo '=== R13: a deposit credits the LIABILITY, not revenue ==='
-- This is the entire point of ADR-0036. Recognising deposits as revenue
-- overstates income, overstates tax, and is unlawful in states that regulate
-- layaway.
SELECT post_layaway_payment(:'lay1'::uuid, 100.00, '2026-03-01', 'lay-d1-' || :'run') AS d1 \gset
SELECT CASE WHEN (SELECT sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'d1'::uuid
                     AND account_id = posting_account('layaway_deposit_control')) = 100.00
             AND (SELECT sum(debit) FROM journal_line
                   WHERE journal_entry_id = :'d1'::uuid
                     AND account_id = posting_account('cash')) = 100.00
             AND (SELECT coalesce(sum(credit),0) FROM journal_line
                   WHERE journal_entry_id = :'d1'::uuid
                     AND account_id = posting_account('sales_revenue')) = 0
            THEN 'PASS: deposit debited cash and credited the layaway liability, not revenue'
            ELSE 'FAIL: the deposit did not land in the liability account'
       END AS r13;

\echo '=== R14: replaying a deposit does not take the money twice ==='
SELECT post_layaway_payment(:'lay1'::uuid, 100.00, '2026-03-01', 'lay-d1-' || :'run') AS d1b \gset
SELECT CASE WHEN :'d1'::uuid = :'d1b'::uuid
             AND (SELECT paid_total FROM layaway WHERE id = :'lay1'::uuid) = 100.00
             AND (SELECT count(*) FROM layaway_payment WHERE layaway_id = :'lay1'::uuid) = 1
            THEN 'PASS: replayed deposit returned the original entry; still one payment'
            ELSE 'FAIL: the deposit was recorded twice'
       END AS r14;

\echo '=== R15: a layaway cannot be completed before it is paid off ==='
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM complete_layaway(current_setting('app.t_lay1')::uuid, DATE '2026-04-01',
                             'lay-early-' || current_setting('app.t_run'));
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF v_ok THEN RAISE NOTICE 'PASS: goods were not released on a part-paid layaway';
  ELSE RAISE NOTICE 'FAIL: a part-paid layaway was completed';
  END IF;
END $$;

\echo '=== R16: a layaway cannot be overpaid ==='
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM post_layaway_payment(current_setting('app.t_lay1')::uuid, 500.00,
      DATE '2026-03-15', 'lay-over-' || current_setting('app.t_run'));
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF v_ok THEN RAISE NOTICE 'PASS: a payment exceeding the balance was refused';
  ELSE RAISE NOTICE 'FAIL: the customer was allowed to overpay';
  END IF;
END $$;

\echo '=== R17: layaway_payment is append-only ==='
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN
    DELETE FROM layaway_payment WHERE layaway_id = current_setting('app.t_lay1')::uuid;
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF v_ok THEN RAISE NOTICE 'PASS: deleting a customer payment record was refused';
  ELSE RAISE NOTICE 'FAIL: cash held on trust has an editable record';
  END IF;
END $$;

\echo '=== R18: at pickup the liability becomes revenue and cash is NOT re-counted ==='
-- Cash arrived at deposit time. Debiting cash again here would double-count
-- every layaway the store ever takes.
SELECT post_layaway_payment(:'lay1'::uuid, 200.00, '2026-04-01', 'lay-d2-' || :'run');
SELECT complete_layaway(:'lay1'::uuid, '2026-04-10', 'lay-pick-' || :'run') AS pick \gset
SELECT CASE WHEN (SELECT sum(debit) FROM journal_line
                   WHERE journal_entry_id = :'pick'::uuid
                     AND account_id = posting_account('layaway_deposit_control')) = 300.00
             AND (SELECT sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'pick'::uuid
                     AND account_id = posting_account('sales_revenue')) = 300.00
             AND (SELECT count(*) FROM journal_line
                   WHERE journal_entry_id = :'pick'::uuid
                     AND account_id = posting_account('cash')) = 0
            THEN 'PASS: liability released into revenue; cash untouched at pickup'
            ELSE 'FAIL: pickup posting is wrong'
       END AS r18;

\echo '=== R19: pickup nets the layaway liability for that order to zero ==='
SELECT CASE WHEN (SELECT coalesce(sum(jl.credit - jl.debit),0) FROM journal_line jl
                   JOIN journal_entry je ON je.id = jl.journal_entry_id
                  WHERE je.source = 'layaway' AND je.source_ref = :'lay1'::text
                    AND jl.account_id = posting_account('layaway_deposit_control')) = 0
             AND (SELECT status FROM layaway WHERE id = :'lay1'::uuid) = 'completed'
             AND (SELECT status FROM consignment_item WHERE id = :'li1'::uuid) = 'sold'
            THEN 'PASS: liability fully unwound, layaway completed, item sold'
            ELSE 'FAIL: the layaway liability did not unwind'
       END AS r19;

\echo '=== R20: on cancellation the forfeited fee is income and the refund is not ==='
-- The store earned the fee by holding goods off the floor. The refund is the
-- customer's own money coming back. Lumping them together overstates income.
SELECT open_layaway(:'cust'::uuid,
  jsonb_build_array(jsonb_build_object(
    'description','Layaway cancel item','quantity',1,'unit_price',500.00,
    'consignment_item_id', :'li2'::text)),
  '2026-06-30', 50.00, '2026-03-01') AS lay2 \gset
SELECT post_layaway_payment(:'lay2'::uuid, 200.00, '2026-03-01', 'lay2-d1-' || :'run');
SELECT cancel_layaway(:'lay2'::uuid, '2026-05-01', 'lay2-cxl-' || :'run') AS cxl \gset
SELECT CASE WHEN (SELECT sum(debit) FROM journal_line
                   WHERE journal_entry_id = :'cxl'::uuid
                     AND account_id = posting_account('layaway_deposit_control')) = 200.00
             AND (SELECT sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'cxl'::uuid
                     AND account_id = posting_account('cash')) = 150.00
             AND (SELECT sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'cxl'::uuid
                     AND account_id = posting_account('other_income')) = 50.00
            THEN 'PASS: 200 liability released as 150 refund + 50 fee income'
            ELSE 'FAIL: cancellation split refund and fee incorrectly'
       END AS r20;

\echo '=== R21: cancellation puts the goods back on the floor ==='
SELECT CASE WHEN (SELECT status FROM consignment_item WHERE id = :'li2'::uuid) = 'available'
            THEN 'PASS: the cancelled item is available again'
            ELSE 'FAIL: item stuck at ' ||
                 (SELECT status FROM consignment_item WHERE id = :'li2'::uuid)
       END AS r21;

\echo '=== R22: a previously-cancelled item can go on a NEW layaway ==='
-- Regression guard. A plain unique index on consignment_item_id would satisfy
-- R12 and still brick the item forever after a cancellation: the goods are
-- physically back on the shelf but unsellable through layaway. The guard must
-- be scoped to OPEN layaways or it is worse than nothing.
SELECT open_layaway(:'cust'::uuid,
  jsonb_build_array(jsonb_build_object(
    'description','Second chance','quantity',1,'unit_price',500.00,
    'consignment_item_id', :'li2'::text)),
  '2026-09-30', 0, '2026-06-01') AS lay3 \gset
SELECT post_layaway_payment(:'lay3'::uuid, 50.00, '2026-06-01', 'lay3-d1-' || :'run');
SELECT CASE WHEN (SELECT status FROM layaway WHERE id = :'lay3'::uuid) = 'open'
             AND (SELECT status FROM consignment_item WHERE id = :'li2'::uuid) = 'reserved'
            THEN 'PASS: the freed item was reserved again on a new layaway'
            ELSE 'FAIL: a cancelled layaway permanently blocked the item'
       END AS r22;

\echo '=== R23: the layaway control account equals the sum of OPEN deposits ==='
SELECT CASE WHEN (SELECT difference FROM layaway_liability_check()) = 0
            THEN 'PASS: layaway subledger ties to its control account'
            ELSE 'FAIL: off by ' || (SELECT difference FROM layaway_liability_check())::text
       END AS r23;

-- ============================================================================
-- PART 3 — COMMISSION TRUE-UP
-- ============================================================================

\echo '=== R24: a TIERED commission schedule can actually be stored ==='
-- Regression guard for a constraint bug that made this feature unreachable.
-- The original no-overlap exclusion keyed on (agreement_id, daterange) alone.
-- A tiered schedule IS several concurrently-effective rows -- one per band --
-- so the second band collided with the first and a tiered commission was
-- physically unstorable. Nothing errored at deploy time; the feature simply
-- did not exist, and every tiered code path was dead. See migration 0004.
INSERT INTO commission_rule (agreement_id, rule_type, rate, effective_from)
VALUES (:'aga'::uuid, 'flat', 0.40, '2026-01-01');
INSERT INTO commission_rule (agreement_id, rule_type, rate, breakpoint_amount, effective_from)
VALUES (:'aga'::uuid, 'tiered', 0.30, 5000.00, '2026-01-01');
INSERT INTO commission_rule (agreement_id, rule_type, rate, breakpoint_amount, effective_from)
VALUES (:'aga'::uuid, 'tiered', 0.25, 20000.00, '2026-01-01');
SELECT CASE WHEN (SELECT count(*) FROM commission_rule WHERE agreement_id = :'aga'::uuid) = 3
            THEN 'PASS: a three-band schedule coexists on one agreement'
            ELSE 'FAIL: the tiered schedule could not be stored'
       END AS r24;

\echo '=== R25: two rules for the SAME band on overlapping dates are still rejected ==='
-- Widening the key must not disarm the constraint. Ambiguity about which rate
-- applies is the real error it exists to catch.
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN
    INSERT INTO commission_rule (agreement_id, rule_type, rate, breakpoint_amount, effective_from)
    VALUES (current_setting('app.t_aga')::uuid, 'tiered', 0.20, 5000.00, DATE '2026-06-01');
  EXCEPTION WHEN exclusion_violation THEN v_ok := true; END;
  IF v_ok THEN RAISE NOTICE 'PASS: a duplicate 5000 band over overlapping dates was rejected';
  ELSE RAISE NOTICE 'FAIL: two rates now apply to the same band on the same date';
  END IF;
END $$;

\echo '=== R26: tiers are MARGINAL, not cliff ==='
-- 25,000 of sales: 5,000 @ 40% + 15,000 @ 30% + 5,000 @ 25% = 7,750.
-- A cliff reading re-rates the whole 25,000 at 25% = 6,250.
SELECT CASE WHEN tiered_commission(:'aga'::uuid, 25000.00, '2026-06-30') = 7750.00
            THEN 'PASS: 25,000 rates to 7,750.00 across three marginal bands'
            ELSE 'FAIL: got ' || tiered_commission(:'aga'::uuid, 25000.00, '2026-06-30')::text
       END AS r26;

\echo '=== R27: commission never FALLS when sales rise ==='
-- The point of marginal rating. Under a cliff rule the store earns 2,000 on
-- 5,000 of sales and only 1,800 on 6,000 -- selling more makes the store
-- poorer, which is an incentive no one intends and everyone eventually
-- discovers.
SELECT CASE WHEN tiered_commission(:'aga'::uuid, 6000.00, '2026-06-30')
                 > tiered_commission(:'aga'::uuid, 5000.00, '2026-06-30')
            THEN 'PASS: commission is monotonic across the breakpoint'
            ELSE 'FAIL: crossing the breakpoint REDUCED commission'
       END AS r27;

\echo '=== R28: the dry run computes the adjustment and posts nothing ==='
-- Accrued at the flat 40% on 8,000 = 3,200. Correct marginal = 5,000 @ 40%
-- plus 3,000 @ 30% = 2,900. The store over-charged by 300 and owes it back.
INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'aga'::uuid, 'Trueup item A1', 5000.00, 'available', '2026-01-05')
RETURNING id AS ai1 \gset
INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'aga'::uuid, 'Trueup item A2', 3000.00, 'available', '2026-01-05')
RETURNING id AS ai2 \gset
INSERT INTO consignment_sale (sale_date, status) VALUES ('2026-05-01','completed')
RETURNING id AS csa \gset
INSERT INTO consignment_sale_line (sale_id, item_id, consignor_party_id, sale_price,
                                   commission_rate, commission_amount, net_to_consignor)
VALUES (:'csa'::uuid, :'ai1'::uuid, :'pa'::uuid, 5000.00, 0.40, 2000.00, 3000.00);
INSERT INTO consignment_sale_line (sale_id, item_id, consignor_party_id, sale_price,
                                   commission_rate, commission_amount, net_to_consignor)
VALUES (:'csa'::uuid, :'ai2'::uuid, :'pa'::uuid, 3000.00, 0.40, 1200.00, 1800.00);

SELECT count(*) AS je_pre_dry FROM journal_entry \gset
SELECT CASE WHEN gross_sales = 8000.00 AND accrued_commission = 3200.00
             AND correct_commission = 2900.00 AND adjustment_amount = -300.00
             AND (SELECT count(*) FROM journal_entry) = :'je_pre_dry'::bigint
            THEN 'PASS: dry run reports -300.00 owed back and posts nothing'
            ELSE 'FAIL: got adjustment ' || adjustment_amount::text
       END AS r28
  FROM compute_commission_trueup(:'aga'::uuid, '2026-01-01', '2026-06-30');

\echo '=== R29: an OVER-charge credits the consignor and gives back revenue ==='
SELECT post_commission_trueup(:'aga'::uuid, '2026-01-01', '2026-06-30',
                              '2026-06-30', 'ctu-a-' || :'run') AS ctua \gset
SELECT CASE WHEN (SELECT sum(debit) FROM journal_line
                   WHERE journal_entry_id = :'ctua'::uuid
                     AND account_id = posting_account('commission_revenue')) = 300.00
             AND (SELECT sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'ctua'::uuid
                     AND account_id = posting_account('consignor_payable_control')) = 300.00
             AND (SELECT sum(debit) - sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'ctua'::uuid) = 0
            THEN 'PASS: 300.00 of revenue returned and credited to the consignor'
            ELSE 'FAIL: over-charge true-up posted with the wrong sign'
       END AS r29;

\echo '=== R30: the adjustment appears on the consignor statement, not just the control account ==='
SELECT CASE WHEN (SELECT count(*) FROM open_item
                   WHERE journal_entry_id = :'ctua'::uuid
                     AND party_id = :'pa'::uuid
                     AND subledger_type_code = 'consignor_payable') = 1
            THEN 'PASS: the true-up opened a consignor payable item'
            ELSE 'FAIL: the adjustment is a mystery movement in the control account'
       END AS r30;

\echo '=== R31: re-running the period does not adjust twice ==='
SELECT post_commission_trueup(:'aga'::uuid, '2026-01-01', '2026-06-30',
                              '2026-06-30', 'ctu-a-again-' || :'run');
SELECT CASE WHEN (SELECT count(*) FROM commission_trueup
                   WHERE agreement_id = :'aga'::uuid AND status <> 'voided') = 1
             AND (SELECT count(*) FROM journal_entry
                   WHERE source = 'commission_trueup'
                     AND source_ref = :'aga'::text) = 1
            THEN 'PASS: a fresh key did NOT produce a second adjustment'
            ELSE 'FAIL: the period was trued up twice'
       END AS r31;

\echo '=== R32: refunds reduce the base on the POS path too ==='
-- commission_period_actuals must cover BOTH sale paths. A store that rings
-- consigned goods at the register and also books direct consignment sales
-- would otherwise true up against half its volume -- worse than not truing up
-- at all, because it looks right.
INSERT INTO commission_rule (agreement_id, rule_type, rate, effective_from)
VALUES (:'agb'::uuid, 'flat', 0.40, '2026-01-01');
INSERT INTO commission_rule (agreement_id, rule_type, rate, breakpoint_amount, effective_from)
VALUES (:'agb'::uuid, 'tiered', 0.30, 5000.00, '2026-01-01');
INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'agb'::uuid, 'Trueup item B1', 6000.00, 'available', '2026-01-05')
RETURNING id AS bi1 \gset

INSERT INTO sale (customer_party_id, sale_date, subtotal, discount_total, tax_total, total, status)
VALUES (NULL, '2026-05-10', 6000.00, 0, 0, 6000.00, 'completed') RETURNING id AS sb1 \gset
INSERT INTO sale_line (sale_id, line_no, line_kind, consignment_item_id, consignor_party_id,
                       description, quantity, unit_price, discount_amount, extended_price,
                       commission_rate, commission_amount, net_to_consignor, is_taxable)
VALUES (:'sb1'::uuid, 1, 'consignment', :'bi1'::uuid, :'pb'::uuid,
        'Consigned goods', 1, 6000.00, 0, 6000.00, 0.40, 2400.00, 3600.00, false);

INSERT INTO sale (customer_party_id, sale_date, subtotal, discount_total, tax_total, total,
                  status, is_refund, refunds_sale_id)
VALUES (NULL, '2026-05-20', 1000.00, 0, 0, 1000.00, 'completed', true, :'sb1'::uuid)
RETURNING id AS sb2 \gset
INSERT INTO sale_line (sale_id, line_no, line_kind, consignor_party_id,
                       description, quantity, unit_price, discount_amount, extended_price,
                       commission_rate, commission_amount, net_to_consignor, is_taxable)
VALUES (:'sb2'::uuid, 1, 'consignment', :'pb'::uuid,
        'Partial return', 1, 1000.00, 0, 1000.00, 0.40, 400.00, 600.00, false);

SELECT CASE WHEN gross_sales = 5000.00 AND accrued_commission = 2000.00
            THEN 'PASS: 6,000 sold less 1,000 returned = 5,000 base, 2,000 accrued'
            ELSE 'FAIL: got gross ' || gross_sales::text ||
                 ' accrued ' || accrued_commission::text
       END AS r32
  FROM commission_period_actuals(:'agb'::uuid, '2026-01-01', '2026-06-30');

\echo '=== R33: an adjustment of zero posts nothing at all ==='
-- 5,000 of net sales sits exactly at the breakpoint, so the flat 40% accrual
-- was already correct. A zero-value journal entry is noise in the ledger and
-- an unexplainable line on the consignor's statement.
SELECT count(*) AS je_pre_zero FROM journal_entry \gset
SELECT post_commission_trueup(:'agb'::uuid, '2026-01-01', '2026-06-30',
                              '2026-06-30', 'ctu-b-' || :'run');
SELECT CASE WHEN (SELECT count(*) FROM journal_entry) = :'je_pre_zero'::bigint
             AND (SELECT count(*) FROM commission_trueup
                   WHERE agreement_id = :'agb'::uuid) = 0
            THEN 'PASS: a correct accrual produced no entry and no true-up row'
            ELSE 'FAIL: a zero adjustment was posted anyway'
       END AS r33;

\echo '=== R34: an UNDER-charge moves money the other way ==='
-- Staff optimistically rang an early sale at the 30% tier rate, but the
-- consignor never reached the breakpoint, so 40% was correct. The store
-- under-charged 300 and is owed it: debit the consignor payable, credit
-- commission revenue. Getting this sign backwards pays consignors twice.
INSERT INTO commission_rule (agreement_id, rule_type, rate, effective_from)
VALUES (:'agc'::uuid, 'flat', 0.40, '2026-01-01');
INSERT INTO consignment_item (agreement_id, description, agreed_price, status, received_date)
VALUES (:'agc'::uuid, 'Trueup item C1', 3000.00, 'available', '2026-01-05')
RETURNING id AS ci1 \gset
INSERT INTO consignment_sale (sale_date, status) VALUES ('2026-05-01','completed')
RETURNING id AS csc \gset
INSERT INTO consignment_sale_line (sale_id, item_id, consignor_party_id, sale_price,
                                   commission_rate, commission_amount, net_to_consignor)
VALUES (:'csc'::uuid, :'ci1'::uuid, :'pc'::uuid, 3000.00, 0.30, 900.00, 2100.00);

SELECT post_commission_trueup(:'agc'::uuid, '2026-01-01', '2026-06-30',
                              '2026-06-30', 'ctu-c-' || :'run') AS ctuc \gset
SELECT CASE WHEN (SELECT sum(debit) FROM journal_line
                   WHERE journal_entry_id = :'ctuc'::uuid
                     AND account_id = posting_account('consignor_payable_control')) = 300.00
             AND (SELECT sum(credit) FROM journal_line
                   WHERE journal_entry_id = :'ctuc'::uuid
                     AND account_id = posting_account('commission_revenue')) = 300.00
            THEN 'PASS: under-charge debited the consignor payable and credited the store'
            ELSE 'FAIL: under-charge true-up posted with the wrong sign'
       END AS r34;

\echo '=== R35: both sides of the arithmetic are stored, not just the delta ==='
-- The store has to be able to explain the number to the consignor without
-- re-deriving it from the whole sales history months later.
SELECT CASE WHEN gross_sales = 3000.00 AND accrued_commission = 900.00
             AND correct_commission = 1200.00 AND adjustment_amount = 300.00
            THEN 'PASS: accrued 900, correct 1,200, adjustment +300 all retained'
            ELSE 'FAIL: the true-up row does not explain itself'
       END AS r35
  FROM commission_trueup WHERE agreement_id = :'agc'::uuid AND status = 'posted';

\echo '=== R36: the trial balance is still zero ==='
SELECT CASE WHEN coalesce(sum(debit-credit),0) = 0 AND :'tb_before'::numeric = 0
            THEN 'PASS: every posting in this suite left the books balanced'
            ELSE 'FAIL: trial balance is ' || coalesce(sum(debit-credit),0)::text
       END AS r36
  FROM journal_line;

\echo '=== ALL RETAIL TESTS COMPLETE ==='
