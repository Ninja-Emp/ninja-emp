# Ninja EMP — Software Requirements Specification (SRS)

**Version:** 0.2 · **Status:** DB-first, pre-build · **Scope of this revision:** Parts 0–3 expanded; Parts 4–8 outlined.

> Pragmatic SRS. We expand a section only when we build it. This document is the
> durable spec; chat is not load-bearing. Decisions live in `docs/DECISIONS.md`;
> cross-cutting data rules live in `docs/DATA_STANDARDS.md` (normative).

---

## Part 0 — Platform & Non-Functionals

### 0.1 Tenancy model
- **Schema-per-tenant** in the `ninja_emp` database (see ADR-0007, ADR-0008).
- **Control plane** (`ninja_control` database, `control` schema): tenant registry, slug→schema routing, pool group. **Separate database** (ADR-0008).
- **Tenant plane** (`tenant_<slug>` schema): all domain + ledger tables.
- **Shared kernel** (`kernel` schema): domains, helper functions, global reference data. Read-only to tenant roles.
- **RLS defense-in-depth:** `FORCE ROW LEVEL SECURITY` with `tenant_id = kernel.current_tenant()` on tenant tables **except `journal_entry`/`journal_line`** (measured ~3× cost; schema isolation suffices there — ADR-0007). Session GUC `app.tenant_id` set per transaction via `SET LOCAL`.
- **Roles:** `ninja_app` (DML, RLS applies, NOBYPASSRLS) and `ninja_migrator` (DDL/maintenance, BYPASSRLS). See ADR-0007.

### 0.2 Connection & search_path strategy
- PgBouncer **transaction mode**; DBAL issues `SET LOCAL search_path = <tenant>, kernel` at transaction start (ADR-0010).
- Prepared-statement strategy must be explicit (emulated vs `max_prepared_statements`).

### 0.3 Migration strategy
- **Resumable, batched, per-schema** runner. Progress tracked in `kernel.migration (schema_name, version, checksum, applied_at)`.
- Migrations are idempotent and re-runnable; each tenant schema migrates independently.

### 0.4 Backup / restore
- Per-tenant logical backup (`pg_dump -n tenant_<slug>`) + PITR for the cluster.
- Control plane backed up separately (ADR-0008).

### 0.5 Security
- Least-privilege roles; RLS; audit columns; append-only journal.
- **PII encrypted at rest** (`pgcrypto`, key from `app.pii_key`) and masked in views (ADR-0018).
- Secrets never in code; connection strings from environment.

### 0.6 Audit (ADR-0017) — **BUILT**
- Journal is the financial audit trail (append-only, reversal-linked).
- Every mutable table carries `created_at/by`, `updated_at/by`, `version` + `kernel.touch_audit()` (optimistic locking).
- High-value tables (party, account, lease, tenant_config) additionally write before/after JSON to the append-only `audit_log` via `kernel.audit_row()`.

### 0.7 RBAC
- Roles map to `party_role` + application permissions (Part 6). Deferred detail.

### 0.8 Performance targets
- Posting a balanced entry: < 5 ms p95 (single entry, < 20 lines).
- Trial balance for a tenant-year: < 200 ms p95.
- RLS cost on `journal_line` measured ~3× → disabled there (ADR-0007).

### 0.9 Data standards (ADR-0015) — **NORMATIVE**
All tables conform to `docs/DATA_STANDARDS.md`: singular snake_case naming; audit block + optimistic locking; soft delete for master data; `timestamptz` everywhere; kernel money domains; data classification registry; `RESTRICT` on financial FKs; partition-ready journal; per-tenant idempotency; identity-based numbering; lookup tables for extensible enums; FK indexing; resumable migrations.

---

## Part 1 — Foundational Data Model

### 1.1 Party Model (ADR-0003) — **BUILT**
`party` (supertype) → `person` | `organization` (subtypes, trigger-enforced).
`party_role` (typed, time-bounded, `is_house` flag), `party_relationship` (directed, typed),
`party_contact_mechanism`, `postal_address`, `party_identifier`.
**Requirement:** the store owner is a Party with an `is_house` role; settlement routes to owner equity/draw.
**Standards applied:** audit block + optimistic locking on all; soft delete on `party`/`party_identifier`; `RESTRICT` on party children (ADR-0016); `party_identifier` values encrypted at rest + masked view (ADR-0018).

### 1.2 Money & Currency (ADR-0002) — **BUILT**
Domains: `money_amount numeric(19,4)`, `currency_code char(3)`, `quantity numeric(19,4)`, `fx_rate numeric(19,10)`, `percent_rate numeric(9,6)`.
`kernel.currency` reference; `tenant_config.functional_currency`; `exchange_rate` + `fx_to_functional()`.
**Requirement:** never PG `money`; never silently round; forced rounding is an explicit adjustment line (ADR-0009).

### 1.3 Time & Periods — **BUILT**
`fiscal_period` (year, period_no, start/end, status open|closed|locked). Postings blocked outside an open period.
**Provisioning requirement:** auto-generate current + next fiscal year of periods at tenant creation (ADR-0014) — implemented by `generate_fiscal_year()` / `ensure_fiscal_calendar()`.

---

## Part 2 — The Ledger (the heart) — **BUILT**

### 2.1 Chart of Accounts
`account`: hierarchical (`parent_id`), typed (`account_type_code`), with `is_control` + `control_subledger_type_code`. A control account must declare its subledger type (CHECK-enforced). Master data: audit block, optimistic locking, soft delete. A standard mall CoA is seeded (`db/35_coa_seed.sql`).

### 2.2 Account determination (ADR-0020) — **BUILT**
`posting_map` maps a `kernel.posting_role` (e.g. `rent_revenue`, `security_deposit_control`) to a concrete `account_id`. Domain posting resolves accounts via `posting_account(role)` — **never** by hard-coded account code. A missing mapping raises a clear error.

### 2.3 Journal Entry + Journal Line
`journal_entry` (append-only header; `entry_no` identity; `idempotency_key`; `reversal_of_id`).
`journal_line` (append-only; debit XOR credit; base amounts in functional currency; `party_id` + `subledger_type_code` for subledger tagging).

### 2.4 Invariants (DB-enforced, verified on PG 18.6)
| # | Invariant | Mechanism | Test |
|---|-----------|-----------|------|
| I1 | Σ debits = Σ credits per entry | deferred constraint trigger | T3 |
| I2 | ≥ 2 lines, non-zero value | deferred constraint trigger | T3 |
| I3 | Append-only (no UPDATE/DELETE) | BEFORE trigger | T4 |
| I4 | Corrections are reversals | `reverse_journal_entry()` | T5 |
| I5 | Idempotent posting | `idempotency_key` unique | T2 |
| I6 | Period locking | `assert_period_open()` | T6 |
| I7 | Subledger ↔ control account | `assert_subledger_control()` | T7 |
| I8 | Subledger ties to GL | `subledger_control_check()` | T8 |
| I9 | Debit XOR credit | CHECK constraint | T9 |
| I10 | Tenant isolation | RLS (non-journal tables) | T10 |
| I11 | Trial balance = 0 | `trial_balance()` | T1, T5, T11 |
| I12 | Migrator bypasses RLS | `ninja_migrator` BYPASSRLS | T12 |
| I13 | Financial FKs are RESTRICT | FK `ON DELETE RESTRICT` | T13 |
| I14 | Optimistic locking | `version` + `touch_audit()` | T14 |
| I15 | PII encrypted + masked | `pgcrypto` + masked view | T15 |
| I16 | Posting roles resolve | `posting_account()` | T16 |

### 2.5 Posting API
`post_journal_entry(entry_date, memo, source, source_ref, idempotency_key, lines jsonb) → uuid` (idempotent).
`reverse_journal_entry(entry_id, reversal_date, memo, idempotency_key) → uuid`.
`trial_balance(as_of) → table`. `subledger_control_check() → table`. `posting_account(role) → uuid`.

### 2.6 Subledgers (ADR-0005)
Views over tagged journal lines: `v_subledger`, `v_ar`, `v_ap`, `v_vendor_payable`, `v_customer_credit`, `v_gift_certificate`. No mutable balances → no drift. `security_deposit` and `consignor_payable` added as subledger types.

### 2.6a Open-item AR/AP (ADR-0023) — **BUILT**
A running-balance subledger answers "how much is owed"; **open-item** accounting answers "which invoices are unpaid, how old, and when did each settle." `open_item` (one row per invoice/charge, with `original_amount`/`open_amount`/`due_date`/`status`) and `payment_application` (FIFO matching of a cash settlement to open items). `apply_payment()` posts the cash entry and allocates it. Views `v_open_item` and `v_aging` (0–30/31–60/61–90/90+ buckets). Invariant `open_item_control_check()` asserts **Σ open items = GL control balance** per subledger type. This is the machinery that makes aging, statements, collections, and cash-basis conversion (ADR-0022) exact.

### 2.7 Partitioning (ADR-0019) — **PROVEN**
The journal is designed so range-partitioning by `entry_date` (yearly) is a migration, not a redesign. Proven in `db/tests/partition.sql`: the deferred balance trigger fires correctly on a partitioned copy and all lines of an entry land in one partition. Enablement threshold: **20M `journal_line` rows/tenant** (ADR-0026).

---

## Part 3 — Domain: Vendor Mall — **BUILT**

### 3.1 Purpose
The mall rents physical space to vendors/lessees and bills periodic rent. This domain owns the physical inventory (locations, floors, spaces), the lease lifecycle, rent billing, deposits, and delinquency.

### 3.2 Physical inventory
- `location` — a mall property (code, name, address, timezone). Master data (soft-deleted).
- `floor` — a level within a location (`level_no`).
- `space` — a rentable unit (`space_type_code` from `kernel.space_type`: kiosk/booth/inline/endcap/cart/office/storage/popup), `area_sqft`, and a `status` (available/reserved/leased/maintenance/inactive).
- `space_attribute` — key/value attributes (child detail, CASCADE).

### 3.3 Waitlist
`waitlist` — a party waiting for a space (optionally a preferred type/location), with a `status` queue (waiting/offered/converted/expired/cancelled).

### 3.4 Lease lifecycle
- `lease` — a contract between a lessee party and the mall for one or more spaces. `lease_no` is human-readable (identity). `status` (draft/active/expired/terminated), `start_date`/`end_date`, `billing_day`. Master data (soft-deleted).
- `lease_space` — time-bounded allocation of spaces to a lease. **A space may be actively leased by at most one lease at a time** (partial unique index on `space_id WHERE thru_date IS NULL`).
- `rent_component` — the periodic charges: `base_rent`, `cam`, `percentage_rent` (rate + breakpoint), `utilities`, `marketing`, `insurance`, `fixed_fee`. Fixed components carry `amount`; percentage rent carries `percent_rate` (CHECK-enforced). Effective-dated: a lease may not have two overlapping charge periods for the same component type (GiST exclusion constraint).
- `lease_deposit` — a refundable security deposit; `journal_entry_id` ties it to the ledger posting that recorded receipt.
- `delinquency` — a point-in-time arrears snapshot per lease (`amount_due`, `amount_paid`, `days_past_due`, `status`).

### 3.5 Posting to the ledger (ADR-0020) — **BUILT**
- `post_rent_invoice(lease, period_start, period_end, entry_date, idempotency_key)` — debits **AR control** (tagged to the lessee on the `ar` subledger) and credits each component's revenue account (`rent_revenue`/`cam_revenue`/`percentage_rent_revenue`/`other_income`), resolved via `posting_map`. Idempotent.
- `post_deposit_receipt(deposit, entry_date, idempotency_key)` — debits **cash** and credits **security deposit liability** (tagged to the lessee on the `security_deposit` subledger); links the entry back to `lease_deposit` and sets `status='held'`. Idempotent.

### 3.6 Requirements
- R1: A space cannot be actively leased twice (enforced).
- R2: A rent invoice must balance and tie to the AR subledger (verified).
- R3: A deposit must tie to the security-deposit subledger (verified).
- R4: All posting is idempotent (verified).
- R5: A lessee with ledger history cannot be deleted (RESTRICT, verified).

### 3.7 Not yet built (future Parts)
Abandoned-property handling, liens, percentage-rent true-up from POS sales, lease renewals/escalations, CAM reconciliation, and vendor statements.

---

## Part 4 — Domain: Consignment — **BUILT**

### 4.1 Purpose
A consignor places goods with the store; the store sells them and owes the consignor the sale price less commission. This domain owns consignor agreements, commission terms, item intake, sales, settlements, and payouts.

### 4.2 Accounting basis (ADR-0022)
**Accrual is the single book of record.** Revenue is recognized when earned (goods sold), regardless of cash timing. **Cash basis is a derived report**, computed from the same journal via the open-item layer (ADR-0023) — never a second ledger. A tenant can produce accrual and cash-basis statements from one source of truth.

### 4.3 Entities
- `consignor_agreement` — the contract: consignor party, status, term, settlement cadence, default commission rate. Master data (soft-deleted).
- `commission_rule` — effective-dated commission terms (flat or tiered with a breakpoint). Non-overlapping per agreement (GiST exclusion, ADR-0021).
- `consignment_item` — a physical item: SKU, description, agreed price, status (received/available/sold/returned/withdrawn/lost). Master data (soft-deleted).
- `item_price_change` — append-only price history.
- `consignment_sale` / `consignment_sale_line` — a sale and its lines. Each line carries `sale_price`, `commission_rate`, `commission_amount`, `net_to_consignor`, with a CHECK that **commission + net = sale price** (exact split, no rounding drift).
- `consignor_settlement` / `settlement_line` — a settlement batch rolling up sale lines over a period.
- `consignor_payout` — the cash paid to a consignor; links the ledger entry.

### 4.4 Posting to the ledger (ADR-0020) — **BUILT**
- `post_consignment_sale(sale, entry_date, idempotency_key)` — debits **cash** and credits **sales revenue** (sale total); debits **consignment COGS** and credits **consignor payable** (net-to-consignor total, tagged per consignor on the `consignor_payable` subledger). The store's margin (commission) is implicit: revenue − COGS = commission. Opens an AP open item per consignor. Idempotent.
- `post_consignor_payout(payout, entry_date, idempotency_key)` — debits **consignor payable** and credits **cash**; settles the consignor's open items FIFO; marks the settlement `paid`. Idempotent.

### 4.5 Requirements
- R1: A commission split must be exact — `commission + net = sale price` (CHECK-enforced, verified).
- R2: A consignment sale must balance and tie to the consignor-payable subledger (verified).
- R3: Open items must tie to the consignor-payable control account, before and after payout (verified).
- R4: All posting is idempotent (verified).
- R5: Commission rules may not overlap in time (exclusion constraint, verified).

### 4.6 Not yet built (future Parts)
Markdown/discount engine, returns, layaway, gift certificates, vendor statements, 1099-NEC reporting, and percentage-commission true-ups.

---

## Part 5 — POS & Payments — **BUILT**

### 5.1 Purpose
Point of sale for both central checkout and vendor-run registers, the money-movement layer behind it, and the **realtime vendor portal** those numbers feed.

### 5.2 Accounting basis (ADR-0028, ADR-0029)
Liability to a consignor/vendor accrues **at the moment of sale**, not at settlement. This is both the correct accrual treatment (the obligation exists the instant the goods sell) and the enabling condition for a **realtime vendor portal**: the portal reads the live ledger, so it cannot drift from the books. Settlement is reduced to a pure grouping-and-payout step.

Tender handling follows ADR-0029. Card receipts debit a **card clearing** asset rather than cash, because the money has not arrived yet; a later merchant settlement moves clearing to bank and books the processor fee as **expense** rather than netting it into revenue. Liability tenders (store credit, gift certificate) **debit the liability control** — redeeming a certificate extinguishes an obligation and is not revenue. Drawer differences are booked to **cash over/short**, never absorbed silently into sales.

### 5.3 Entities
`tender_type` (settlement kind: cash / clearing / liability), `tax_jurisdiction`, `tax_rate` (effective-dated, non-overlapping), `register`, `shift` (drawer session, one open per register), `sale`, `sale_line` (consignment vs owned; consignment lines carry the commission split), `sale_line_tax` (multi-jurisdiction), `payment`, `payment_tender` (split tenders), `merchant_settlement`.

### 5.4 Posting to the ledger (ADR-0020) — **BUILT**
`post_sale` debits each tender to its resolved account, credits sales revenue and sales tax payable, and — for consignment lines — debits consignment COGS and credits consignor payable per consignor while opening an AP open item. `post_refund` is a separate document that mirrors the sale, reverses the consignor accrual, **and relieves the matching open items**. `post_shift_close` compares counted to expected cash and books over/short. `post_merchant_settlement` moves clearing to bank and expenses the fee. All are idempotent and `posting_map`-driven.

### 5.5 Realtime vendor portal
`v_vendor_balance_realtime`, `v_vendor_sales_realtime`, `v_vendor_sales_today`, `v_vendor_payout_available`, and `v_vendor_statement` are **views over the ledger and open-item layer** — no batch tables, no nightly rollups, nothing that can drift. `vendor_portal_check()` asserts the portal total equals the GL control balance and is exercised by the test suite.

### 5.6 Requirements
R1. A sale's header totals must equal the sum of its lines (DB-enforced, deferred).
R2. Captured tenders must sum to the payment amount (DB-enforced, deferred).
R3. Consignment lines must split exactly: commission + net = extended price.
R4. Card tenders must never debit cash; they debit clearing until settled.
R5. Liability tenders must be subledger-tagged to the party whose balance falls.
R6. Refunds must be new documents; the original entry is never mutated.
R7. A refund must relieve both the GL control account and the open items.
R8. The realtime portal balance must equal the GL control balance at all times.

### 5.7 Not yet built (future Parts)
Square/processor API integration, 1099-NEC generation and threshold tracking, vendor payable draw as a tender, gift-certificate issuance flow, and inventory decrement for owned goods.

## Part 6 — Application Layer (outline)
Feature modules, service contracts, routing, middleware, auth, API surface (OpenAPI 3.1), server-rendered UI + map island. **Not built.**

## Part 7 — Integrations & Reporting (outline)
QB/Xero export mapping; reporting depth; dashboards. **Not built.**

## Part 8 — Invariants & Test Strategy
The invariants in §2.4 are the contract. Test pyramid: unit → functional (real PG) → contract (OpenAPI) → E2E → smoke. Mutation testing is the primary gate (ADR-0012).
**Harnesses built:** `db/tests/invariants.sql` (19/19 PASS), `db/tests/vendormall.sql` (20/20 PASS), `db/tests/consignment.sql` (12/12 PASS), `db/tests/pos.sql` (27/27 PASS), `db/tests/partition.sql` (5/5 PASS), `db/tests/rls_benchmark.sql`. **83 assertions total.** All assertion suites are idempotent (safe to re-run against a live tenant) and are verified after a full backup→restore round-trip.
