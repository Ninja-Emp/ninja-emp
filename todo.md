# Ninja EMP — Finish the DB

## Round A — Tier 1: Complete the accounting core
- [x] 3900 Retained Earnings + `retained_earnings` posting role
- [x] `close_period()` / `reopen_period()` / `close_fiscal_year()`
- [x] `income_statement()` / `balance_sheet()`
- [x] `cash_basis_income_statement()` (ADR-0022 derivation)
- [x] `write_off_open_item()` (wire up dead `bad_debt_expense` role)
- [x] Test suite: close + statements (23 assertions)

## Round B — Tier 2 core
- [x] ADR-0031: weighted average cost
- [x] Inventory tables + movements + owned-goods COGS on sale
- [x] ADR-0032: breakage opt-in, default never
- [x] Gift certificate + store credit issuance tables & posting
- [x] Vendor payable draw as tender (+ overdraw guard)
- [x] Test suite: inventory, stored value (30 assertions)

## Round C — Tier 2 remainder
- [ ] 1099-NEC threshold tracking + annual extract
- [ ] Percentage-rent true-up from POS sales
- [ ] CAM reconciliation
- [ ] Lease renewals & escalations
- [ ] Markdown engine + layaway
- [ ] Percentage-commission true-ups
- [ ] Test suites

## Round D — Tier 3 + Ops (user request)
- [x] Migrations runner (versioned, resumable, idempotent)
- [x] Fix partition-test schema pollution (scratch schema + P5 guard)
- [x] Per-tenant backup/restore (tenant go-live snapshot), verified on restore
- [x] Prod -> local dev sync WITH PII SCRUBBING (raw requires explicit flag)
- [x] Leak test: reload the shipped export and diff PII columns vs prod
- [x] Laragon/Windows dev sync docs
- [x] BUG: person/organization missing `updated_by` — every UPDATE failed
      (fixed in 10_party.sql + migration 0002 + invariants T17/T18)
- [x] `scripts/run_tests.sh` — one-command full regression

## Round E — Sync & deliver
- [ ] Full test run (all suites green)
- [ ] ERD re-render + SRS/README/ROADMAP/DECISIONS sync
- [ ] Backup + zip + push
