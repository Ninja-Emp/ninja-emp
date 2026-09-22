# Settlement-Layer Invariants

**Status:** normative. Written **before** the code that enforces them (see
`docs/DECISIONS.md` ADR-0039 and the process note at the end).

This document states, in testable form, exactly what must be true of the
open-item / payment-application / reversal layer. Every invariant below has a
name, a precise statement, and the mechanism that enforces it. If a mechanism
and a statement disagree, the statement wins and the mechanism is a bug.

The layer exists to answer four questions correctly and at all times:

1. **How much is owed?** (per party, per subledger)
2. **Which documents are unpaid, and how old?** (aging)
3. **When did each document settle, and by what?** (application history)
4. **What happens when a settlement is undone?** (reversal)

A defect is any state in which one of those four answers is wrong while the
trial balance still nets to zero. That is the dangerous class: the books
"balance" but the detail lies.

---

## 0. Vocabulary

- **Open item** — a document (`open_item`) that can be settled. `item_kind`
  is `invoice` (the party owes / the store owes) or `credit_memo` (direction
  reversed). `open_amount` is always a **non-negative magnitude**.
- **Signed amount** — `open_item_signed(item_kind, open_amount)`: invoices are
  positive, credit memos negative. This is the only value that may be summed
  into a subledger balance.
- **Application** — a row in `payment_application` matching a cash settlement
  (a journal entry) to an open item.
- **Settlement** — the act of applying cash to open items. It always has a
  journal entry behind it.
- **Reversal** — a mirror journal entry (`reversal_of_id`) that undoes another
  entry. The original is never edited.

---

## 1. Open-item invariants

**OI-1 (magnitude).** `open_amount >= 0` and `original_amount >= 0` for every
open item. A credit is a `credit_memo`, never a negative invoice.
*Enforced by:* `open_item_open_amount_check`, `open_item_original_amount_check`.

**OI-2 (bounded).** `open_amount <= original_amount`.
*Enforced by:* `open_item_open_amount_check` (the `<=` half).

**OI-3 (signed balance).** The contribution of an open item to its subledger
balance is `open_item_signed(item_kind, open_amount)`. No query may sum
`open_amount` raw.
*Enforced by:* convention + `v_open_item.signed_amount`; verified by
`open_item_control_check()`.

**OI-4 (status is derived from amount).** For a live item,
`status = 'settled'` iff `open_amount = 0`; `status = 'partial'` iff
`0 < open_amount < original_amount`; `status = 'open'` iff
`open_amount = original_amount`. `written_off` and `void` are terminal and
carry their own meaning.
*Enforced by:* every writer sets status in the same statement that changes
`open_amount`; verified by a reconciliation check (see PA-4).

**OI-5 (due date sanity).** `due_date IS NULL OR due_date >= issue_date`.
*Enforced by:* `open_item_due_date_check`.

**OI-6 (zero is not a document).** An open item of zero cannot be created.
*Enforced by:* `open_item_create()` raises.

---

## 2. Payment-application invariants

**PA-1 (positive application).** `applied_amount > 0`.
*Enforced by:* `payment_application_applied_amount_check`.

**PA-2 (append-only).** A `payment_application` row is never updated or
deleted. Undoing a settlement is done by reversing the journal entry and
recording the un-application as a new, linked fact — never by mutating history.
*Enforced by:* `trg_payment_application_append_only` (`kernel.forbid_mutation`).

**PA-3 (application is backed by a journal entry).** Every application names
the `journal_entry_id` of the cash settlement that produced it. An application
with no journal entry is a fact with no accounting behind it.
*Enforced by:* `payment_application.journal_entry_id` (nullable today; see
ADR-0039 — the settlement entry points always set it).

**PA-4 (tie-out).** For every open item,
`original_amount - open_amount = Σ applied_amount` over its live applications,
**adjusted for un-applications** (PA-5). Equivalently: the item's outstanding
balance equals its original less everything applied to it, net of reversals.
*Enforced by:* `open_item_application_check()` (new) — a reconciliation
function that must return zero rows on a healthy database.

**PA-5 (reversal un-applies).** If the journal entry behind an application is
reversed, the application is un-applied: the open item's `open_amount` is
restored by the applied amount and its `status` is recomputed. The un-application
is itself recorded (append-only), so the history shows both the application and
its reversal.
*Enforced by:* `reverse_journal_entry()` calling `unapply_for_entry()` (new).

**PA-6 (no double application).** Applying the same settlement twice (same
`journal_entry_id`) is a no-op. Idempotency is by `idempotency_key` at the
journal level and by `journal_entry_id` at the application level.
*Enforced by:* the `IF NOT EXISTS (... WHERE journal_entry_id = v_entry)` guard
in every settlement entry point.

---

## 3. Allocation invariants

**AL-1 (one allocator).** There is exactly **one** function that turns a cash
amount into applications: `allocate_payment()`. `apply_payment`,
`post_consignor_payout`, and `post_refund` all call it. No entry point
re-implements FIFO.
*Enforced by:* code structure; verified by grep in the test suite.

**AL-2 (invoices only).** Allocation considers only `item_kind = 'invoice'`
items. A credit memo is netted at invoicing time, never "paid off" with cash.
*Enforced by:* the `item_kind = 'invoice'` predicate inside `allocate_payment()`.

**AL-3 (FIFO by default).** Absent a directed target, allocation consumes open
invoices oldest-first by `COALESCE(due_date, issue_date), issue_date, id`.
*Enforced by:* the `ORDER BY` inside `allocate_payment()`.

**AL-4 (directed allocation).** A caller may name a specific open item to settle
first. The named item is consumed before FIFO proceeds to the rest.
*Enforced by:* the optional `p_open_item_id` parameter of `allocate_payment()`.

**AL-5 (no silent remainder).** If cash remains after all eligible invoices are
settled, the remainder is **not** silently dropped. It is either recorded as an
**on-account** credit (a new open item of `item_kind = 'on_account'`) or the
call raises. Which one is a per-call decision; the default is to raise, because
silently absorbing cash is how a subledger drifts from its control account.
*Enforced by:* `allocate_payment()`'s `p_on_account` flag; the default raises.

**AL-6 (row locking).** Allocation locks each candidate open item `FOR UPDATE`
before reading its balance, so two concurrent settlements cannot both apply
against the same outstanding amount.
*Enforced by:* `FOR UPDATE` inside `allocate_payment()`.

---

## 4. Reversal invariants

**RV-1 (mirror).** A reversal posts a mirror entry: every debit becomes a credit
of the same amount and vice versa, same accounts, same party/subledger tags.
*Enforced by:* `reverse_journal_entry()`.

**RV-2 (linked, not edited).** The reversal links to the original via
`reversal_of_id`; the original is never modified.
*Enforced by:* `trg_journal_entry_append_only`.

**RV-3 (idempotent).** Reversing with the same `idempotency_key` returns the
same reversal entry.
*Enforced by:* the idempotency guard in `reverse_journal_entry()`.

**RV-4 (reversal is a document status).** An entry that has been reversed is
reported as reversed (`journal_entry_status.is_reversed`), and a reversed entry
**cannot be reversed again** — the status is authoritative, not inferred from
the presence of a mirror.
*Enforced by:* `journal_entry_status` view + a guard in
`reverse_journal_entry()` that refuses to reverse an already-reversed entry.

**RV-5 (reversal un-applies settlement).** Reversing a settlement entry restores
the open items it settled (PA-5). Reversing a non-settlement entry touches no
open items.
*Enforced by:* `unapply_for_entry()` called from `reverse_journal_entry()`.

---

## 5. Control-account invariants

**CA-1 (subledger ties to control).** For every open-item-backed subledger,
`Σ signed open items = GL control balance`. Difference must be zero.
*Enforced by:* `open_item_control_check()`.

**CA-2 (signed comparison).** The control check compares **signed** sums on both
sides. It must not take `abs()` of either side, because `abs()` masks a genuine
sign error (a credit posted as a debit) as a match.
*Enforced by:* `open_item_control_check()` (rewritten — see ADR-0039).

**CA-3 (tagged control postings).** A line hitting a control account must name
the party, unless the subledger is a bearer instrument (`allows_untagged`).
*Enforced by:* `assert_control_account_tagged()`.

**CA-4 (write-off locks).** `write_off_open_item()` reads its target
`FOR UPDATE`, so a concurrent settlement cannot race the write-off.
*Enforced by:* `FOR UPDATE` in `write_off_open_item()`.

---

## 6. Money invariants

**MO-1 (no sub-cent posting).** No amount with more than the currency's scale
may be posted. For USD (scale 2) an amount like `1.005` is rejected at the
database, not silently rounded.
*Enforced by:* a scale `CHECK` on `journal_line`, `open_item`, and
`payment_application` (new — see ADR-0039).

**MO-2 (no floats).** The application layer never constructs money from a float.
*Enforced by:* `Money::of()` / `Money::fromDatabase()` raising on floats.

**MO-3 (base amounts are derived).** `base_debit`/`base_credit` are
`round(amount * fx_rate, 4)`; they are never supplied independently.
*Enforced by:* `post_journal_entry()`.

---

## 7. Journal integrity invariants

**JI-1 (balanced).** `Σ debit = Σ credit` per entry, and the entry is non-zero.
*Enforced by:* `assert_entry_balanced()` (deferred).

**JI-2 (append-only).** `journal_entry` and `journal_line` reject UPDATE/DELETE.
*Enforced by:* `kernel.forbid_mutation()`.

**JI-3 (hash chain).** Each entry carries `prev_hash` (the `entry_hash` of the
previous entry for the tenant) and `entry_hash` (a digest over the entry's
immutable content plus `prev_hash`). Tampering with any historical entry breaks
the chain from that point forward and is detectable by `verify_journal_chain()`.
*Enforced by:* `journal_entry_hash_chain()` trigger + unique indexes (new — see
ADR-0039).

**JI-4 (period lock).** No posting into a closed/locked fiscal period.
*Enforced by:* `assert_period_open()`.

---

## 8. What "done" means

The fix is complete when:

- Every invariant above has a mechanism.
- Every mechanism has at least one regression assertion that **fails before the
  fix and passes after**.
- The full suite is green, and the new assertions are counted.
- The four questions at the top of this document are answered correctly in the
  presence of a reversal, a directed payment, an overpayment, and a concurrent
  write-off.

---

## Process note (why this file exists first)

The settlement defects F1–F6 were not caused by a lack of tests. They were
caused by writing the modules quickly and using the tests as a design review
instead of stating the invariants first. A test written after the code tends to
assert what the code does, not what it must do. This document inverts that
order: the invariants are written down, agreed, and only then enforced. The
tests that follow are written against **this** document, not against the code.
