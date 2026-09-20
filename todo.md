# Ninja EMP — Finish the DB

## Round A — Tier 1: Complete the accounting core
- [x] 3900 Retained Earnings + `retained_earnings` posting role
- [x] `close_period()` / `reopen_period()` / `close_fiscal_year()`
- [x] `income_statement()` / `balance_sheet()`
- [x] `cash_basis_income_statement()` (ADR-0022 derivation)
- [x] `write_off_open_item()` (wire up dead `bad_debt_expense` role)
- [x] Test suite: close + statements (23 assertions)

## Round B — Tier 2 core
- [ ] ADR: inventory valuation method
- [ ] Inventory tables + movements + owned-goods COGS on sale
- [ ] ADR: gift certificate breakage / escheatment
- [ ] Gift certificate + store credit issuance tables & posting
- [ ] Vendor payable draw as tender (+ overdraw guard)
- [ ] Test suite: inventory, stored value

## Round C — Tier 2 remainder
- [ ] 1099-NEC threshold tracking + annual extract
- [ ] Percentage-rent true-up from POS sales
- [ ] CAM reconciliation
- [ ] Lease renewals & escalations
- [ ] Markdown engine + layaway
- [ ] Percentage-commission true-ups
- [ ] Test suites

## Round D — Tier 3 + Ops (user request)
- [ ] Migrations runner (versioned, resumable, idempotent)
- [ ] Fix partition-test schema pollution
- [ ] Per-tenant backup/restore (tenant go-live snapshot)
- [ ] Prod -> local dev sync WITH PII SCRUBBING (raw requires explicit flag)
- [ ] Laragon/Windows dev sync docs

## Round E — Sync & deliver
- [ ] Full test run (all suites green)
- [ ] ERD re-render + SRS/README/ROADMAP/DECISIONS sync
- [ ] Backup + zip + push
