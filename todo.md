# Ninja EMP — Round 6: Part 5 (POS & Payments) + Realtime Vendor Portal

Decisions locked: **accrual at sale** (consignor/vendor liability recognized at the moment of
sale, not at settlement) → enables **realtime vendor portal numbers**.

## A. Decisions
- [ ] ADR-0028: accrual at sale confirmed; vendor portal reads realtime from the ledger (no batch)
- [ ] ADR-0029: tender model — split tenders, clearing accounts, over/short

## B. Chart of accounts additions
- [ ] db/38_coa_pos.sql: undeposited funds/card clearing, sales tax payable, merchant fees,
      store credit liability, gift certificate liability, cash over/short, inventory/COGS(owned)
      + posting_map roles

## C. POS schema (DB-first)
- [ ] db/70_pos.sql: tender_type, tax_jurisdiction, tax_rate, register, shift (drawer),
      sale, sale_line, sale_line_tax, payment, payment_tender, store_credit, gift_certificate,
      return/refund linkage
- [ ] Enforce: sale totals = Σ lines; tenders = sale total; line ownership (consignment vs owned)

## D. Posting functions
- [ ] db/75_pos_posting.sql: post_sale (accrual at sale), post_refund (reversal-not-edit),
      post_shift_close (over/short), post_merchant_settlement — idempotent, posting_map-driven

## E. Realtime vendor portal
- [ ] db/80_vendor_portal.sql: v_vendor_balance_realtime, v_vendor_sales_today,
      v_vendor_statement, v_vendor_payout_available — read straight from the ledger

## F. Wire-up + tests
- [ ] Add new tables to 90_rls.sql; update provision.sh
- [ ] db/tests/pos.sql: assertions (totals, tenders, tax, accrual-at-sale, refund, over/short,
      vendor realtime balance ties to control, trial balance = 0, idempotency)
- [ ] Re-provision clean; run ALL suites green

## G. Sync + deliver
- [ ] Update SRS Part 5, DECISIONS, ERD + render, README
- [ ] Backup + zip + commit + push; attach; complete
