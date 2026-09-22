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
- [x] Write `docs/SETTLEMENT_INVARIANTS.md` — the exact, testable invariants for
      the settlement layer (open items, payment application, reversal, allocation)
- [x] Write ADR-0039 in `docs/DECISIONS.md` — the decisions that close F1–F6

## 2. Fix F1 (CRITICAL) — reversal must un-apply settlement
- [ ] Invariant: reversing a payment journal restores open_item.open_amount + status
- [ ] Invariant: reversal is a document status, not a silent ledger mirror
- [ ] Implement: reversal-aware un-apply (via reversal-as-status, see B3)
- [ ] Regression test

## 3. Fix F5 — payment_application append-only + tie-out invariant
- [ ] Invariant: payment_application is append-only (no UPDATE/DELETE)
- [ ] Invariant: sum(applied) per open_item == original - open (signed)
- [ ] Implement: forbid_mutation trigger + reconciliation check
- [ ] Regression test

## 4. Fix F3 — one allocator, not four
- [ ] Invariant: every allocator filters item_kind='invoice'
- [ ] Implement: single `allocate_payment()` used by apply_payment / payout / refund
- [ ] Regression test

## 5. Fix F2 — directed payment (pay a specific invoice)
- [ ] Invariant: caller may target a specific open_item; FIFO is the default
- [ ] Implement: optional p_open_item_id on apply_payment
- [ ] Regression test

## 6. Fix F4 — no silent cash drop
- [ ] Invariant: unapplied remainder is either on-account or raises
- [ ] Implement: on-account open item (item_kind='on_account') OR explicit raise
- [ ] Regression test

## 7. Fix F6 — write-off race + sign-masking
- [ ] Invariant: write_off locks the row (FOR UPDATE)
- [ ] Invariant: control check compares signed sums, no abs()
- [ ] Implement + regression test

## 8. Port B1 — hash-chained journal
- [ ] Invariant: each entry's entry_hash chains prev_hash; tamper is detectable
- [ ] Implement: prev_hash/entry_hash + unique indexes + verify function
- [ ] Regression test

## 9. Port B2 — scale CHECK (no sub-cent posting)
- [ ] Invariant: no amount with scale > currency scale can be posted
- [ ] Implement: CHECK on journal_line + open_item + payment_application
- [ ] Regression test

## 10. Port B3 — reversal-as-document-status
- [ ] Invariant: a reversed document cannot be re-reversed; status is authoritative
- [ ] Implement: status + reversal_journal_id + CHECK
- [ ] Regression test

## 11. Verify + deliver
- [ ] Full suite GREEN (222 + new assertions)
- [ ] Update DB_AUDIT.md / DECISIONS.md / README.md
- [ ] Commit
