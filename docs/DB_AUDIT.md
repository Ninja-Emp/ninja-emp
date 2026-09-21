# DB Audit — What Is Left

Generated against the live `ninja_emp` database and the repo working tree.
All findings below are **verified by query or file inspection**, not assumed.

> **Updated after Rounds A, B, C and D.** Tier 1 is closed, Tier 2 is closed,
> and the Tier 3 operational gaps are closed. The original audit text is
> preserved below for traceability; items now done are marked as such.

## Current state (verified, post Round C)

| Metric | Count |
| --- | --- |
| Base tables (`tenant_demo`) | 64 (partition scaffolding no longer leaks) |
| Views (`tenant_demo`) | 23 |
| Functions (`tenant_demo`) | 85 |
| Kernel tables | 13 |
| Test assertions | **222 across 10 suites — all green** |
| Posting roles with no `posting_map` entry | **0** (everything is wired) |
| Fiscal periods | 24, all `open` |

Suite results: invariants 28, consignment 12, vendormall 20, pos 27,
partition 6, close 23, inventory 30, tax1099 19, lease 20, retail 37. Zero
failures, zero errors, from a clean `db/provision.sh` → `scripts/migrate.sh` →
`scripts/run_tests.sh`, and stable across repeated runs without reprovisioning.

### Closed since the original audit

- **Tier 1, all of it.** `income_statement()`, `balance_sheet()`,
  `cash_basis_income_statement()`, `close_period()` / `reopen_period()` /
  `close_fiscal_year()`, Retained Earnings + Income Summary,
  `write_off_open_item()`. (Round A, ADR-0030)
- **Tier 2 core.** Inventory with moving weighted-average cost and COGS on sale
  (ADR-0031), stored value issuance as a liability with opt-in breakage
  (ADR-0032), vendor draw as a tender with an overdraw guard. (Round B)
- **Tier 3 operations.** Migrations runner with checksum drift detection,
  per-tenant backup, verified restore, scrubbed prod→dev sync with a leak test,
  and the partition-test schema pollution. (Round D, ADR-0033)
- **A latent schema bug.** `person` and `organization` carried a
  `kernel.touch_audit()` trigger but no `updated_by` column, so every `UPDATE`
  to either table failed. Found while building the scrubber — the first code to
  update a person. Fixed, migrated, and guarded by a structural test that
  asserts the whole class rather than the two tables that happened to be broken.

### Round C — Tier 2 remainder (closed)

- **1099-NEC reporting** (`82_tax_1099.sql`, ADR-0034): `tax_form_threshold`
  (year-keyed, so the OBBBA 600→2,000 change is data not code),
  `payee_tax_profile` (TIN type, W-9 date, backup withholding), and an
  append-only `tax_year_payment` accumulated as payments happen. Reporting is
  derived from **cash**, not accrual, and an exception report surfaces missing
  TIN / W-9 / address.
- **Percentage rent + CAM true-up** (`83_lease_trueup.sql`, ADR-0035):
  `lease_sales_report` (reported vs. POS-measured sales), `cam_pool` +
  `cam_pool_expense` with recoverable/excluded classification, excess-only
  true-up, over-recovery credited back, effective-dated escalations.
- **Markdown engine + layaway** (`84_markdown_layaway.sql`, ADR-0036):
  `markdown_reason` (reason-driven absorption defaults), append-only
  `markdown_event` (a markdown is an event, never an overwrite; price can only
  fall), and `layaway` / `layaway_line` / `layaway_payment` where deposits are
  a **liability** (`2450`), not revenue, until pickup.
- **Percentage-commission true-up** (`86_commission_trueup.sql`, ADR-0037):
  `commission_trueup` rated **marginally** per period (not cliff), so the
  effective rate is monotonic in sales.

### Round C.1 — Defects found while testing (all fixed + regression-guarded)

Testing the new modules surfaced ten defects, several in code that had already
shipped. Each is fixed at the model level and guarded by a test:

1. **Tiered commission schedules were physically unstorable.** The
   `commission_rule` no-overlap exclusion keyed only on `(agreement_id,
   daterange)`, so several concurrent bands — the entire ADR-0037 feature —
   could not be inserted. Nothing errored at deploy time; the feature was dead
   code. Widened the key to include `rule_type` and `breakpoint_amount`
   (migration 0004, regression-guarded by retail R24/R25).
2. **Untagged postings to a control account were legal.** Debiting `ar_control`
   with no party balanced fine and orphaned the money — owed to nobody, never
   collectable. Added the preventive trigger `assert_control_account_tagged()`
   (migration 0005, invariants T21/T22/T23).
3. **`post_commission_trueup` wrote an open item for only one direction**, so
   every under-charge true-up permanently broke `open_item_control_check()`.
4. **`open_item_control_check()` reported permanent false positives** for
   subledgers whose detail lives elsewhere; fixed at the model level with
   `subledger_type.uses_open_items`.
5. **`2450` was modelled as a plain liability**, so layaway deposits violated
   `journal_line_check4`; promoted to a control account with a new
   `layaway_deposit` subledger type.
6. **`5100` account-code collision** (Consignment COGS vs. Inventory
   Adjustments) sent shrink to the wrong expense; moved to `5200` and added
   `assert_posting_map_sane()`.
7. **`83_lease_trueup` read `je.reversed_by_id` off the base table** — that
   column exists only on the status view.
8. **`open_item` could not hold a credit balance**; added `item_kind` +
   migration 0003.
9. **`lease.sql`'s CAM-estimate fixture posted AR with no open item behind it**,
   manufacturing the exact orphaned-balance defect the suite exists to catch.
10. **Migration verification probes assumed `app.tenant_id` was set** (0003,
    0004) and **0005's probe was vacuous** — it inserted zero rows on a fresh
    tenant and reported a failure that never happened. Rewritten to manufacture
    its own fixture and assert **both** directions (untagged refused *and*
    tagged accepted), proven non-vacuous by disabling the guard and by stubbing
    an over-broad guard.

### Still open

Nothing in the database is blocking. The remaining work is the **application
layer** (Part 6) and **integrations/reporting** (Part 7) — see `ROADMAP.md`.
Deferred, non-blocking follow-ons: Square/processor API integration, formal
vendor statements, abandoned-property/liens, and journal partitioning at the
20M-row threshold (ADR-0026).

---

## Original audit (for traceability)

**SRS parts:** 0–5 built. Part 6 (Application Layer) and Part 7 (Integrations &
Reporting) remain outlines.

---

## Tier 1 — Gaps that block calling the accounting "world-class"

These are the ones worth pushing back on. The ledger is sound but it cannot yet
produce a financial statement or close a book.

### 1.1 No financial statement functions
Verified: `income_statement | balance_sheet | cash_flow | pnl | profit` matches = **0**.
Only `trial_balance()` exists.

A double-entry system that cannot emit a P&L or Balance Sheet is incomplete. Needed:
- `income_statement(from_date, to_date)` — revenue/expense rollup by account type
- `balance_sheet(as_of_date)` — assets = liabilities + equity, must tie to zero
- `cash_basis_income_statement(...)` — ADR-0022 says cash basis is *derived*; the
  derivation does not exist yet
- Comparative/period-over-period variants

### 1.2 No period close / year-end close routine
Verified: `fiscal_period` has `status`, `closed_at`, `closed_by` columns and
`assert_period_open()` enforces posting locks — but **0 periods are closed** and
there is no function to close one. `%close%` matches only `post_shift_close`.

Needed:
- `close_period(fiscal_year, period_no)` — lock, assert trial balance = 0, stamp `closed_at`
- `reopen_period(...)` — privileged, audited
- `close_fiscal_year(year)` — roll revenue/expense into retained earnings

### 1.3 No Retained Earnings account
Verified: equity accounts are only `3000 Owner Equity` and `3100 Owner Draw`.
Year-end close has nowhere to post the net income roll-up. Needs `3900 Retained
Earnings` + a `retained_earnings` posting role.

### 1.4 No AR write-off / bad debt routine
Verified: `%write%` and `%bad_debt%` function matches = **0**, despite a
`bad_debt_expense` posting role existing and being mapped. The role is wired to an
account no code ever uses. Needed: `write_off_open_item(...)` that relieves the open
item, debits bad debt expense, credits AR control, and is reversible.

---

## Tier 2 — Functional gaps the SRS already flags as "not yet built"

### 2.1 Inventory for owned goods (§5.7)
Verified: **0** tables matching `inventory | stock | receipt`.

`sale_line.line_kind` accepts `'owned'` and the POS will happily sell owned goods,
but nothing decrements stock and no COGS is booked for them. Consignment COGS posts
correctly; owned goods do not. Needed: `inventory_item`, `inventory_movement`,
purchase receipt, valuation method decision (FIFO vs. weighted average — **this is an
ADR you need to make**), and COGS posting on owned-line sales.

### 2.2 Gift certificate & store credit issuance (§4.6, §5.7)
Verified: `v_gift_certificate` and `v_customer_credit` **views** exist, but there is
no issuance table. Both are currently redeemable as tenders (liability tenders work)
with no way to *create* the liability. Needed: issuance tables + posting functions,
and breakage policy (another ADR).

### 2.3 Vendor payable draw as a tender (§5.7)
Vendors should be able to spend against their payable balance. `tender_type` supports
`settlement_kind='liability'` so the mechanism exists — needs the tender row, the
posting path, and a guard against overdrawing.

### 2.4 1099-NEC reporting (§4.6, §5.7)
Verified: **0** tables matching `1099 | tax_form`. Needed: threshold tracking per
consignor per tax year, TIN capture (the party model has `party_identifier` with
masking already), and an annual extract.

### 2.5 Vendor Mall deferred items (§3.7)
- Percentage-rent true-up from POS sales (POS data now exists, so this is unblocked)
- CAM reconciliation
- Lease renewals & escalations
- Abandoned property handling / liens
- Vendor statements (the realtime portal covers live balances; formal statements differ)

### 2.6 Consignment deferred items (§4.6)
- Markdown / discount engine
- Returns handling beyond the POS refund path
- Layaway
- Percentage-commission true-ups

---

## Tier 3 — Hygiene / infrastructure

### 3.1 No migrations runner — `db/migrations/` does not exist
Verified: directory absent. `provision.sh` does a full build-from-scratch, which is
correct for greenfield but **will not survive first production deploy**. Once real
data exists you cannot re-provision. Needed before any app work ships: versioned,
resumable, idempotent migration files + a runner that records applied versions.

This is the single highest-risk infrastructure gap.

### 3.2 Partition-test leftovers in the live schema
Verified: `je_p`, `je_p_2026`, `je_p_2027`, `jl_p`, `jl_p_2026`, `jl_p_2027` are real
base tables created by `db/tests/partition.sql`. They pollute the schema and the
backups. The test should create them in a scratch schema and drop them, or the
provision should exclude them.

### 3.3 Reporting indexes not yet tuned
No statement functions exist yet, so no reporting access patterns have been measured.
Revisit after Tier 1.1 — index to the actual query plans, not to guesses.

---

## Recommended order

1. **Retained Earnings account + period close + year-end close** (1.3, 1.2) — small, and
   everything else in reporting depends on a closable book.
2. **Financial statements** (1.1) — P&L, Balance Sheet, cash-basis derivation.
3. **Migrations runner** (3.1) — must land before application code.
4. **AR write-off** (1.4) — small, closes a wired-but-dead posting role.
5. **Inventory + owned-goods COGS** (2.1) — largest remaining domain; needs an ADR first.
6. Everything in Tier 2 by business priority.
7. **Partition-test cleanup** (3.2) — quick win, do it alongside anything.

Items 1, 2 and 4 together are roughly one build round and would make the accounting
core genuinely complete.
