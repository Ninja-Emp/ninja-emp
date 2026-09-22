# Ninja EMP — Settlement Defect Fixes (A) + EMP Idea Ports (B)

> **CONTINUING IN A NEW CHAT?** Read `HANDOFF_SETTLEMENT.md` first — it is
> self-contained (environment, defect map, mutation map, design, order, gotchas).
> Then read `docs/SETTLEMENT_INVARIANTS.md` and ADR-0039 in `docs/DECISIONS.md`.

Governing lesson: **state the invariants BEFORE writing code.** No module is written
until its invariants are written down and agreed.

## 0. Environment
- [x] Install PostgreSQL 18.6 (PGDG) — native `uuidv7()`
- [x] Provision `ninja_emp` + `ninja_control` (tenant_demo)
- [x] Establish GREEN baseline: 222/222 assertions

## 1. Invariants (write first, code second)
- [x] Write `docs/SETTLEMENT_INVARIANTS.md`
- [x] Write ADR-0039 in `docs/DECISIONS.md`

## 1b. Git reconciliation + design-docs push
- [x] Reconcile HEAD to origin/main (9b35bfd); working tree matched origin
- [x] Commit + push design docs (89b8b87)

## 2. Migration `db/migrations/0007_settlement_integrity.sql`
- [x] F5: payment_application append-only + activity ledger (application_kind)
- [x] F3/AL-1: one allocator `allocate_payment()`
- [x] F1/PA-5/RV-5: `unapply_for_entry()` + reversal calls it
- [x] F2/AL-4: directed payment (p_open_item_id)
- [x] F4/AL-5: no silent remainder (raise default; on_account opt-in)
- [x] F6/CA-4: write_off FOR UPDATE + records application
- [x] F5-adjacent: redeem_stored_value + recognize_breakage record applications
- [x] F6/CA-2: open_item_control_check signed (no abs)
- [x] PA-4: `open_item_application_check()`
- [x] B1/JI-3: hash chain (prev_hash/entry_hash + trigger + verify)
- [x] B2/MO-1: scale CHECK (no sub-cent posting)
- [x] B3/RV-4: reversal-as-document-status (cannot re-reverse)
- [x] Applied to live DB; in-transaction VERIFY passed
- [x] F3 GAP: `post_refund` rewritten to call `allocate_payment()`
- [x] PA-4 backfill (PART 2b) reconciles legacy open items

## 3. Write the regression suite
- [x] `db/tests/settlement.sql` — assertions for OI/PA/AL/RV/CA/MO/JI
- [x] Wire `settlement` into `scripts/run_tests.sh` DEFAULT_SUITES

## 4. Mirror the fix into base schema files (fresh provision correct)
- [x] db/00_kernel.sql (money_scale_ok)
- [x] db/45_openitem.sql (on_account, activity ledger, allocator, unapply, checks)
- [x] db/30_ledger.sql (reversal rewrite, hash chain, scale checks)
- [x] db/65_consignment_posting.sql (post_consignor_payout)
- [x] db/75_pos_posting.sql (post_refund)
- [x] db/78_stored_value.sql (redeem/breakage record applications)
- [x] db/85_close.sql (write_off FOR UPDATE + application)

## 5. Verify
- [x] Re-provision from base files (fresh build correct)
- [x] Run migrate.sh (idempotent no-op on fresh build)
- [x] settlement.sql GREEN; full suite GREEN (241 = 222 + 19)
- [x] Commit + push code

---

# Quality Gate (Part 6, Step 9) — Task A

> Continuation handoff: `HANDOFF_QUALITY_GATE.md`. Definition of Done: `HANDOFF.md` §4.

## 6. PHPStan level 10
- [x] src/ library: 0 errors
- [x] app/ logic: fix remaining errors (controllers/support)
- [x] Decide Views/ scope (exclude app/tenant-ui/src/Views)
- [x] src + app: 0 errors

## 7. Author missing tool configs
- [x] phpmd.xml
- [x] deptrac.yaml
- [x] phpunit.xml (bridge to custom harness)
- [x] infection.json5 (MSI >= 80%)
- [x] .github/workflows/ci.yml

## 8. Run every tool to GREEN
- [x] php-cs-fixer
- [x] phpstan
- [x] phpmd
- [x] deptrac
- [x] unit tests (876 assertions)
- [ ] infection (MSI >= 80%) — currently 66.96% scoped; hardening in progress

## 9. Commit + push final A
- [ ] Commit and push
