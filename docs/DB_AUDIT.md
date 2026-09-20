# DB Audit — What Is Left

Generated against the live `ninja_emp` database and the repo working tree.
All findings below are **verified by query or file inspection**, not assumed.

## Current state (verified)

| Metric | Count |
| --- | --- |
| Base tables (`tenant_demo`) | 54 (48 real + 6 partition-test leftovers) |
| Views (`tenant_demo`) | 17 |
| Functions (`tenant_demo`) | 31 |
| Kernel tables | 12 |
| Test assertions | 83 across 5 suites — **all green** |
| Posting roles with no `posting_map` entry | **0** (everything is wired) |
| Fiscal periods | 24, all `open` |

Suite results at time of audit: invariants 19, consignment 12, vendormall 20,
pos 27, partition 5. Zero errors.

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
