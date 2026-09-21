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
- [x] Wire 39_coa_tax / 82_tax_1099 / 83_lease_trueup into provision.sh + 90_rls.sql
- [x] 1099-NEC threshold tracking + annual extract  (82_tax_1099.sql)
- [x] Percentage-rent true-up from POS sales        (83_lease_trueup.sql)
- [x] CAM reconciliation                            (83_lease_trueup.sql)
- [x] Lease renewals & escalations                  (83_lease_trueup.sql)
- [x] Markdown engine + layaway                     (84_markdown_layaway.sql)
- [x] Percentage-commission true-ups                (86_commission_trueup.sql)
- [x] Test suite: tax1099   (19 assertions)
- [x] Test suite: lease     (20 assertions)
- [x] Test suite: retail    (37 assertions)
- [x] Register tax1099/lease/retail in scripts/run_tests.sh
- [x] ADR-0034 (1099), ADR-0035 (lease true-up), ADR-0036 (markdown/layaway),
      ADR-0037 (commission true-up), ADR-0038 (control-account tagging) in docs/DECISIONS.md

## Round C.1 — Bugs found while testing (all fixed + regression-guarded)
- [x] 5100 account-code collision: Consignment COGS vs Inventory Adjustments.
      Shrink was expensed to Consignment COGS. -> 5200 + assert_posting_map_sane()
- [x] 2400 collision: Security Deposits vs Layaway Deposits -> 2450
- [x] 83_lease_trueup read je.reversed_by_id off the BASE table (view-only column)
- [x] open_item could not hold a credit balance -> item_kind + migration 0003
- [x] commission_rule exclusion key made TIERED schedules unstorable.
      The whole ADR-0037 feature was dead code. -> migration 0004 + retail R24/R25
- [x] Untagged postings to a CONTROL account were legal -> orphaned money that
      balances but is owed by nobody. -> assert_control_account_tagged(),
      migration 0005, invariants T21/T22/T23
- [x] post_commission_trueup only wrote an open item for ONE direction, so
      under-charge true-ups broke open_item_control_check permanently
- [x] open_item_control_check reported non-open-item subledgers as imbalances
      (permanent false positives) -> subledger_type.uses_open_items
- [x] lease.sql CAM-estimate fixture posted AR with no open item behind it
- [x] Migrations 0003/0004 verification probes assumed app.tenant_id was set
- [x] Migration 0005's verify block was a VACUOUS TEST: it probed with
      `INSERT ... SELECT FROM journal_entry LIMIT 1`, which inserts ZERO rows
      on a fresh tenant -> no exception -> reported "untagged line was accepted"
      when nothing was ever attempted. It failed clean-room and would have
      passed a build with a BROKEN guard but no journal history. Rewritten to
      manufacture its own fixture, assert BOTH directions (untagged refused AND
      tagged accepted, so an over-broad guard cannot pass either), and unwind
      via deliberate exception since journal_* are append-only. Proven
      non-vacuous by disabling the guard (fails) and by stubbing an over-broad
      guard (fails the positive control).
- [x] Same probe then hit audit_log.tenant_id NOT NULL: passing tenant_id
      explicitly is insufficient because kernel.audit_row() resolves the tenant
      from the GUC independently. Fixed by setting LOCAL tenant context.

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
- [x] Full test run (all suites green) — 222 assertions, 10 suites, GREEN
      from a clean provision -> migrate -> test
- [x] ERD re-render (erd.mmd + erd.png + ERD.md rebuilt from source)
- [x] SRS / README / ROADMAP / DB_AUDIT / DECISIONS sync
- [x] Backup (backups/20260921T014903Z-round-c) + zip (dist/) + push to origin/main
