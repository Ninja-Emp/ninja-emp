# Ninja EMP — Decision Record (ADRs)

> Durable memory. Chat is volatile; this file is not. Every locked decision and
> every pushback lives here. Format: Context → Decision → Consequences → Pushback.

Status legend: **ACCEPTED** (locked), **PROPOSED** (needs your call), **PUSHBACK** (I disagree / recommend change).

---

## ADR-0001 — PostgreSQL 18, one version everywhere
**Status:** ACCEPTED (verified)
**Context:** Need native `uuidv7()` for append-only journal keys and a single version across Laragon/Docker/CI/prod.
**Decision:** Pin PostgreSQL **18** (exact minor) everywhere. Verified in this workspace: `PostgreSQL 18.6`, `SELECT uuidv7()` returns a time-ordered UUID.
**Consequences:** Time-ordered UUIDs give good index locality without a separate sequence. No `pg_uuidv7` extension needed (native). Must pin the minor and upgrade deliberately.
**Pushback:** None on the version. But see ADR-0006 on whether *every* table needs a UUID key.

---

## ADR-0002 — Money as `NUMERIC(19,4)` + `currency CHAR(3)`; never PG `money`
**Status:** ACCEPTED
**Context:** Money must never lose value; multi-currency-ready; USD base.
**Decision:** Domain `kernel.money_amount = numeric(19,4)`; `kernel.currency_code = char(3)`; rates `numeric(19,10)`. PG `money` type is banned (locale-dependent, 2 dp, no currency).
**Consequences:** Max ~999 trillion; 4 dp is the storage rounding boundary.
**Pushback (important):** The handoff says *"never round silently."* A `numeric(19,4)` column **will** silently round anything with >4 dp on insert — the DB is not a guard here, it is the rounding boundary. So the invariant must be enforced **in the application** by computing exact allocations (largest-remainder) and emitting explicit adjustment lines. The DB scale is a *backstop*, not the guarantee. Recommend we (a) keep 4 dp, (b) add a functional test that asserts no line ever carries >4 dp before insert, and (c) treat any forced rounding as a first-class `journal_line` with `memo='rounding adjustment'`. See ADR-0009.

---

## ADR-0003 — Party Model Architecture
**Status:** ACCEPTED
**Context:** One actor can be customer, vendor, consignor, employee, and the store owner simultaneously.
**Decision:** Silverston Party Model: `party` supertype → `person`/`organization` subtypes; `party_role` (with `is_house`), `party_relationship`, `party_contact_mechanism`, `postal_address`, `party_identifier`.
**Consequences:** The store owner is a Party with an `is_house` role, so settlement routes to owner equity/draw, not a third-party payable. Subtype integrity enforced by trigger.
**Pushback:** None — this is the correct model. One refinement: `is_house` is on the *role*, not the party, which is right (the owner could also be a customer). Keep it.

---

## ADR-0004 — Double-entry ledger is the single source of truth; append-only
**Status:** ACCEPTED (verified)
**Context:** No competitor has true double-entry; the ledger must be authoritative.
**Decision:** `journal_entry` + `journal_line`, append-only (UPDATE/DELETE blocked by trigger). Corrections are **reversals** (`reverse_journal_entry`), never edits. Balance enforced by a **deferred constraint trigger** (Σ debits = Σ credits per entry). Idempotent posting via `idempotency_key`. Period locking via `fiscal_period.status`.
**Consequences:** Verified on PG 18.6 — all 11 invariant tests pass (see `db/tests/invariants.sql`).
**Pushback (performance):** The deferred constraint trigger re-aggregates the *entire* entry on every line insert → O(n²) for an n-line entry. Fine for typical entries (<100 lines). For bulk imports, batch into one entry and accept the cost, or add a statement-level fast path later. Documented, not blocking.

---

## ADR-0005 — Subledgers are views over the journal, tied to GL control accounts
**Status:** ACCEPTED (verified)
**Context:** AR/AP/vendor-payable/customer-credit/gift-cert must tie to GL control accounts and never drift.
**Decision:** Subledgers are **views** (`v_subledger`, `v_ar`, `v_ap`, `v_vendor_payable`, `v_customer_credit`, `v_gift_certificate`) derived from `journal_line` rows tagged with `party_id` + `subledger_type_code`. A tagged line **must** post to the matching control account (trigger-enforced). `subledger_control_check()` proves the tie (difference = 0).
**Consequences:** No separate mutable balance tables → no drift possible. Verified.
**Pushback:** None. This is strictly better than materialized subledger balances.

---

## ADR-0006 — `uuidv7()` primary keys everywhere
**Status:** ACCEPTED, with **PUSHBACK** on the highest-volume table
**Context:** Append-only journal keys; distributed-friendly; time-ordered.
**Decision:** `uuidv7()` PKs on all entities.
**Pushback:** For a **single-database-per-tenant** SaaS, `uuidv7` costs 16 bytes vs 8 for `bigint`, and every secondary index carries the PK. The highest-volume table by far is `journal_line` (millions of rows/tenant). Recommend: keep `uuidv7` for externally-referenced entities (`party`, `journal_entry`, `account`), but switch **`journal_line.id` to `bigint GENERATED ALWAYS AS IDENTITY`**. It is never referenced externally; it only needs to be unique within its entry. This is cheap to change now (pre-build) and expensive later. **Your call — I recommend the switch.**

---

## ADR-0007 — Schema-per-tenant + RLS as defense-in-depth
**Status:** **IMPLEMENTED** (pushback accepted, with measurement)
**Context:** Strong isolation; RLS as belt-and-suspenders.
**Decision:** One schema per tenant. `FORCE ROW LEVEL SECURITY` with a `tenant_id = kernel.current_tenant()` policy on tenant tables **except `journal_entry` and `journal_line`**, where RLS is intentionally disabled.
**Measurement (real PG 18.6, 200k journal lines):**
| Access pattern | With RLS | Without RLS | Overhead |
|---|---|---|---|
| Full scan (no parallel) | 231 ms | 73 ms | ~3.2× |
| Index-driven per-account balance | 207 ms | 72 ms | ~2.9× |
**Rationale:** Schema-per-tenant already physically isolates tables, so RLS is redundant for isolation on the hot path; the measured ~3× cost is not worth paying there. RLS remains on all other tenant tables as a `search_path`-bug guard. **If we ever move to shared-schema multi-tenancy, RLS MUST be re-enabled on the journal tables.**
**Operational guard (implemented):** `FORCE RLS` subjects the table owner to policies, so migrations would silently see zero rows. We added a dedicated **`ninja_migrator` role with `BYPASSRLS`** (for DDL/maintenance) and `ninja_app` **without** it. Proven by invariant T12.

---

## ADR-0008 — Control plane in the same database as tenant schemas
**Status:** **IMPLEMENTED** (pushback accepted)
**Context:** `control.tenant` registry originally lived in the same DB as tenant schemas.
**Decision:** Split into **two databases**: `ninja_control` (control plane) and `ninja_emp` (kernel + tenant schemas). `provision.sh` creates both.
**Rationale:** A tenant-plane restore/backup no longer carries control data; a control-plane migration cannot lock tenant traffic; blast radius is reduced. The tenant→schema router reads control data once per connection — a small latency cost for a large safety gain.
**Consequences:** The app needs two connection strings (control + tenant). The router caches tenant→schema mappings.

---

## ADR-0009 — Exact allocation (largest-remainder) for splits
**Status:** ACCEPTED
**Context:** Commission splits, tax splits, percentage allocations must sum to the whole.
**Decision:** All splits use largest-remainder allocation; parts always sum to the whole. Any mathematically forced rounding is recorded as an explicit `journal_line` adjustment so the entry balances to the penny.
**Consequences:** Requires a shared-kernel allocator (to be built in the App layer). The DB enforces balance; the allocator guarantees exactness.
**Pushback:** None. This is the correct approach and should be a unit-tested shared-kernel primitive.

---

## ADR-0010 — PgBouncer transaction mode + `SET LOCAL search_path`
**Status:** ACCEPTED, with **PUSHBACK** on prepared statements
**Context:** Connection pooling with per-tenant `search_path`.
**Decision:** PgBouncer **transaction mode**; DBAL issues `SET LOCAL search_path = <tenant>, kernel` at the start of each transaction.
**Pushback:** Transaction-mode pooling is **incompatible with server-side prepared statements** unless PgBouncer ≥1.21 with `max_prepared_statements` is configured. PDO by default uses emulated prepares (client-side) — which is *safe* here but loses server-side plan caching. Recommend: explicitly set `PDO::ATTR_EMULATE_PREPARES = true` for pooled connections, **or** configure `max_prepared_statements` and use native prepares. Do not leave this implicit — it is a classic production outage. Also: `SET LOCAL` only works inside a transaction, so the DBAL must guarantee every unit of work is transactional.

---

## ADR-0011 — "No frameworks" + hand-rolled DBAL
**Status:** ACCEPTED, with **PUSHBACK** on scope
**Context:** No frameworks; PDO with named parameters; DBAL design deferred.
**Pushback:** A hand-rolled DBAL is a large, subtle surface: named-parameter rewriting (PDO named params can't be reused), placeholder uniqueness, type mapping (numeric→string in PHP!), `SET LOCAL` injection, transaction/unit-of-work, and PgBouncer interaction. This is where bugs that *lose money* live. Recommend: build a **thin, owned** DBAL (not a framework) with an explicit, small contract, and treat it as a first-class bounded context with its own test suite. Do **not** let it grow into an ORM. The deferred "DBAL talk" should happen **before** any domain code, because every domain module depends on it.

---

## ADR-0012 — Quality gate: 100% coverage + mutation as the real gate
**Status:** **PROPOSED** — recommend adopting MSI gate (awaiting your call)
**Context:** User wants 100% coverage everywhere, mutation testing as the real gate.
**Pushback:** Literal 100% line coverage is a vanity metric that incentivizes assertion-free tests and `@codeCoverageIgnore` abuse. The handoff already concedes equivalent mutants make 100% MSI impossible. Recommend: **drop the literal 100% coverage target**; set a high-but-honest coverage floor (e.g. 90% on the shared kernel and ledger) and make **MSI the gate** (e.g. ≥90% MSI on ledger/domain, with documented equivalent-mutant exceptions). This is stricter in practice, not looser.

---

## ADR-0013 — PHP 8.5
**Status:** ACCEPTED, with **PUSHBACK** on toolchain readiness
**Context:** PHP 8.5 released 2025-11-20.
**Pushback:** PHP 8.5 is very new. PHPStan level 10, Infection, Codeception, and PHP-CS-Fixer may lag in full 8.5 support. Recommend: verify each tool's 8.5 support **before** pinning CI to 8.5, and keep a documented fallback to 8.4 if a gate tool is not ready. Do not let a toolchain gap block the ledger work — the DB is version-independent.

---

## ADR-0014 — Fiscal period must exist for every posting date
**Status:** ACCEPTED (self-pushback noted)
**Context:** Period locking requires knowing which period a date falls in.
**Decision:** `assert_period_open()` rejects any posting whose `entry_date` is not covered by a `fiscal_period` row.
**Pushback (on myself):** This makes the fiscal calendar a **hard dependency** — you cannot post a single entry until periods are generated. That is intentional (forces a real fiscal calendar) but must be handled by tenant provisioning: **auto-generate the current + next fiscal year of periods at tenant creation.** Documented as a provisioning requirement.

---

## ADR-0015 — Enterprise data standards are normative
**Status:** ACCEPTED
**Context:** Round 1 built a correct ledger but left cross-cutting concerns (audit, concurrency, soft-delete, PII, RI policy, partitioning) implicit and inconsistent between tables.
**Decision:** Adopt `docs/DATA_STANDARDS.md` as **normative**. Every table/column/migration MUST conform; deviations require an ADR. The standard fixes: singular snake_case naming; a single audit block (`created_at/by`, `updated_at/by`, `version`) + `kernel.touch_audit()` trigger on every mutable table; soft-delete for master data; `timestamptz` everywhere; kernel money domains only; a data-classification registry; `RESTRICT` for financial FKs; partition-ready journal; per-tenant idempotency keys; identity-based human-readable numbering; lookup tables for extensible enums; FK indexing; resumable migrations.
**Consequences:** The retrofit (ADR-0016/0017/0018) brings round-1 tables into conformance. New domains (Vendor Mall) are born conformant.
**Pushback (on myself):** Round 1 was internally inconsistent — `party` had `updated_at` but no `updated_by`/`version`; `account` had `updated_at` but no audit trigger; `party_identifier` had no soft delete. The standard exists precisely to stop this drift. Adopting it means **rewriting** those tables, which is cheap now and expensive later.

---

## ADR-0016 — Referential integrity: `RESTRICT` for financial/master data (corrects round-1 `CASCADE`)
**Status:** ACCEPTED — **PUSHBACK on my own round-1 choice**
**Context:** Round 1 declared `ON DELETE CASCADE` on `party` children (`person`, `organization`, `party_role`, `party_relationship`, `party_contact_mechanism`, `postal_address`, `party_identifier`).
**Pushback:** `CASCADE` on a **party** is a financial-integrity hazard. A party is referenced by `journal_line.party_id` (subledger history). If someone deletes a party, `CASCADE` would silently delete its roles/identifiers — and, worse, the *intent* is that a party with ledger history can never be deleted at all. `CASCADE` also destroys the audit trail of who a party was. This is exactly the class of bug that loses money and breaks audits.
**Decision:**
- **Master/financial references → `ON DELETE RESTRICT`** (the default): `party` children, `journal_line.journal_entry_id`, `journal_line.account_id`, `journal_line.party_id`, `account.parent_id`, `lease` references, etc. You may never delete a party/account/lease/entry that has history.
- **Pure child detail with no independent identity** (subtypes `person`/`organization`, contact mechanisms, attributes) may keep `CASCADE` **from their parent** — but the parent itself is `RESTRICT`-protected, so the cascade can only fire when the parent is genuinely deletable.
- Master data is **soft-deleted** (ADR-0017), so hard deletes are the exception, not the rule.
**Consequences:** Deleting a party with history now raises `23503` instead of silently destroying subledger history. Verified by a new invariant test.

---

## ADR-0017 — Audit, optimistic concurrency, and soft delete are mandatory
**Status:** ACCEPTED
**Context:** Two clerks editing the same lease must not silently overwrite each other; every change must be attributable; master data must be recoverable.
**Decision:**
- Every mutable table carries `created_at/by`, `updated_at/by`, `version` and a `BEFORE UPDATE` trigger `kernel.touch_audit()` that stamps `updated_at`/`updated_by` and increments `version`.
- Updates MUST be optimistic: `UPDATE … WHERE id = :id AND version = :expected`; zero rows ⇒ `ConflictException`.
- Master data is soft-deleted (`deleted_at`, `deleted_by`); read paths filter `deleted_at IS NULL`.
- `db/05_audit.sql` adds an append-only `audit_log` (who/what/when/before/after) written by a generic `kernel.audit_row()` trigger on high-value tables (party, account, lease, tenant_config).
**Consequences:** `updated_by`/`created_by` default to `kernel.current_actor()` (the `app.actor_id` GUC the DBAL sets per transaction). Append-only journal tables are exempt (they carry `created_at/by` only).
**Pushback:** A full before/after audit log on *every* table is expensive and noisy. We scope row-history to **high-value** tables and rely on `version`+`updated_by` elsewhere. This is the pragmatic enterprise norm.

---

## ADR-0018 — PII classification, encryption at rest, and masking
**Status:** ACCEPTED
**Context:** Tax ids, SSNs, and dates of birth are PII; storing them in clear text is a compliance failure.
**Decision:**
- `kernel.data_classification` registry maps `(schema, table, column) → class` (`public|internal|confidential|pii|pii_sensitive`).
- `pii_sensitive` values are **encrypted at rest** with `pgcrypto` (`pgp_sym_encrypt`) using a key from a session GUC (`app.pii_key`), and exposed only through a **masked view** (`v_party_identifier_masked`).
- `person.date_of_birth` is `pii_sensitive`.
**Consequences:** The app must set `app.pii_key` per transaction (from a KMS/secret store) to read/write sensitive identifiers. Masking is enforced at the view layer so application code cannot accidentally leak.
**Pushback:** Column-level encryption in the DB is a *defense-in-depth* control, not a substitute for disk encryption and access control. It also breaks `LIKE`/range queries on the encrypted column — acceptable, because we never search tax ids by prefix. Documented trade-off.

---

## ADR-0019 — Partition-ready journal (range by `entry_date`)
**Status:** ACCEPTED (design), **PROPOSED** (enablement threshold)
**Context:** `journal_line` is the highest-volume table; a single tenant can reach tens of millions of rows.
**Decision:** Design `journal_entry`/`journal_line` so that **range-partitioning by `entry_date` (yearly)** is a migration, not a redesign. All lines of an entry share the entry's `entry_date`, so the deferred balance trigger operates within one partition. The partition key is part of the PK where required.
**Pushback / open question:** Enabling partitioning changes the PK shape (`(id, entry_date)`) and the FK from `journal_line` to `journal_entry` must include the partition key. We will **prove** the deferred constraint trigger still fires correctly on a partitioned copy before committing to enablement. Enablement is gated on a documented row-count threshold in the migration runner. **Your call on the threshold** (proposal: 20M lines/tenant).

---

## ADR-0020 — Posting is driven by a `posting_map`, not hard-coded account codes
**Status:** ACCEPTED
**Context:** Domain code (rent invoicing, settlement, POS) must not hard-code GL account codes; tenants have different charts of accounts.
**Decision:** Each tenant has a `posting_map` (a.k.a. "account determination") table mapping a **posting role** (e.g. `rent_revenue`, `security_deposit_liability`, `ar_control`, `cash`) to a concrete `account_id`. Domain posting functions resolve accounts through `posting_map`, never by code literal. `kernel.posting_role` seeds the known roles.
**Consequences:** A tenant can remap accounts without code changes. A missing mapping raises a clear error at posting time. This is the standard ERP "account determination" pattern.
**Pushback:** None — hard-coding account codes in domain SQL is the single most common ERP customization failure. This is the correct abstraction.

---

## ADR-0021 — Effective-dated rows must not overlap (GiST exclusion constraints)
**Status:** ACCEPTED
**Context:** Effective-dated master data (e.g. `rent_component` charge periods) can silently accumulate overlapping rows, producing double-billing and non-deterministic reads. A plain unique index cannot express "no two rows for the same key may have overlapping date ranges."
**Decision:** Where a table is effective-dated on a business key, enforce non-overlap with a PostgreSQL **exclusion constraint** using `btree_gist`: `EXCLUDE USING gist (key WITH =, daterange(effective_from, effective_thru, '[]') WITH &&)`. First applied to `rent_component` (`lease_id`, `component_type_code`). `btree_gist` is installed into the `kernel` schema.
**Consequences:** The database — not application code — guarantees a single active charge per component type per lease at any point in time. `ON CONFLICT` cannot be used with exclusion constraints, so seeds/tests must delete-then-insert (documented in the test harnesses).
**Pushback:** None — this is the canonical temporal-integrity pattern; relying on application checks alone is a known source of billing defects.

---

## ADR-0022 — Accrual is the book of record; cash basis is a DERIVED report
**Status:** ACCEPTED
**Context:** The user asked whether a company choosing accrual vs cash basis changes the plan. It does not change the *core* schema — but it does require an explicit decision, because the two bases answer different questions and a mall/consignment business needs both.
**Decision:**
- **Accrual is the single book of record.** Revenue is recognized when earned (rent billed, goods sold) and expenses when incurred, regardless of cash timing. The journal already does this: `post_rent_invoice` debits AR and credits revenue on the invoice date; the cash receipt is a *separate* entry (debit cash / credit AR).
- **Cash basis is a derived report, never a second ledger.** It is computed from the same journal by recognizing revenue/expense only when the related cash settles. Because we keep **open-item** AR/AP (ADR-0023), the conversion is exact: a cash-basis P&L recognizes an invoice's revenue on the date its open item is fully settled.
- **No core schema change.** The only new machinery is the open-item layer (ADR-0023), which is required anyway for aging, statements, and collections.
**Consequences:** One source of truth; no dual-ledger reconciliation. A tenant can produce accrual and cash-basis statements from the same data. Tax basis (cash) and management basis (accrual) coexist without divergence.
**Pushback:** Building a *separate* cash-basis ledger is a classic ERP mistake — it doubles the reconciliation surface and always drifts. Deriving cash basis from open items is the correct, world-class approach. If a tenant ever needs a modified-cash or tax-basis variant, it is another *report*, not another ledger.

---

## ADR-0023 — Open-item AR/AP subledger (invoice ↔ payment matching)
**Status:** ACCEPTED
**Context:** A running-balance subledger (sum of tagged journal lines) answers "how much is owed" but not "which invoices are unpaid, how old, and when did each settle." Aging, statements, collections, and cash-basis conversion all require **open-item** accounting.
**Decision:**
- Add `ar_item` and `ap_item` (one row per invoice/charge, carrying `original_amount`, `open_amount`, `due_date`, `status`), and `payment_application` (many-to-many matching of a cash receipt to open items, with `applied_amount`).
- `apply_payment(party, subledger_type, amount, entry_date, idempotency_key)` posts the cash entry **and** allocates it across the party's oldest open items (FIFO), updating `open_amount`/`status`.
- Open-item tables are **operational detail**; the GL control account remains the source of truth. A DB invariant asserts **Σ open items = control-account balance** per subledger type (extends `subledger_control_check`).
- `post_rent_invoice` now also opens an `ar_item`; `post_consignment_sale` opens an `ap_item` (consignor payable).
**Consequences:** Aging buckets, customer/vendor statements, and cash-basis reports become trivial. The running-balance views (`v_ar`, `v_ap`) remain for quick totals.
**Pushback:** Open-item is more work than a running balance, but a running balance alone cannot produce an aging report or a statement — both are table stakes for a mall/consignment business. This is the standard AR/AP design in every serious ERP.

---

## ADR-0024 — Quality gate: mutation score, not literal 100% line coverage (resolves ADR-0012)
**Status:** ACCEPTED
**Context:** ADR-0012 proposed dropping a literal 100% line-coverage requirement. The user delegated the call ("pushbacks are your choice if you use world-class application as the standard").
**Decision:** Gate on **mutation score (MSI)**, not line coverage. Target **MSI ≥ 80%** on domain/ledger code, with **100% of the DB invariants (I1–I16) covered by functional tests**. Line coverage is reported but not gated.
**Consequences:** Tests must *assert behavior*, not merely execute lines. Mutation testing (Infection) becomes the primary gate; it is slower, so it runs on the domain/ledger packages, not the whole tree.
**Pushback:** Literal 100% line coverage is a vanity metric — it rewards executing lines without asserting outcomes. Mutation score measures whether the tests would *catch a defect*. This is the world-class standard.

---

## ADR-0025 — DBAL: `bcmath` money, savepoints supported, emulated prepares (resolves ADR-0011)
**Status:** ACCEPTED
**Context:** Three DBAL questions were open (see `docs/DBAL.md` §11).
**Decision:**
1. **Decimal arithmetic:** use PHP **`bcmath`** with money carried as **strings** end-to-end (never PHP `float`). We own the rounding (largest-remainder allocation, ADR-0009).
2. **Savepoints:** **support** nested transactions via savepoints. Rationale: a service may need to attempt an optional sub-operation and roll it back without aborting the outer transaction (e.g. "try to auto-apply a payment; if it fails, keep the invoice"). Forbidding nesting pushes this complexity into application code, which is worse.
3. **Native prepares:** default **emulated** prepares, because PgBouncer transaction mode (ADR-0010) does not support server-side prepared statements across pooled connections. Revisit only if we move to session mode.
**Consequences:** Money math is exact and dependency-free. Savepoint support requires the DBAL to track nesting depth and emit `SAVEPOINT`/`ROLLBACK TO`. Emulated prepares keep PgBouncer compatibility.
**Pushback:** On savepoints I reverse my earlier lean (forbid). The real-world need to attempt-and-recover inside a transaction outweighs the simplicity of forbidding nesting, provided the DBAL manages depth correctly.

---

## ADR-0026 — Partition-enablement threshold = 20M `journal_line` rows/tenant (resolves ADR-0019)
**Status:** ACCEPTED
**Context:** ADR-0019 proved the journal is partition-ready but left the enablement threshold open.
**Decision:** Enable range-partitioning by `entry_date` (yearly) when a tenant's `journal_line` exceeds **20,000,000 rows** (or when any single year exceeds ~5M). The migration runner checks this and partitions automatically; the design is already proven (`db/tests/partition.sql`).
**Consequences:** Small tenants stay on a single table (simpler); large tenants get partition pruning and cheaper maintenance. The PK/FK shape change is a migration, not a redesign.
**Pushback:** Partitioning too early adds operational overhead for no benefit; too late causes painful online migrations. 20M rows is the point where index maintenance and vacuum cost on a single table become material for this workload.

---

## ADR-0027 — PII key management: envelope encryption (resolves ADR-0018)
**Status:** ACCEPTED
**Context:** ADR-0018 encrypts PII with `pgcrypto` using a key from `app.pii_key`, but left key management open.
**Decision:** Use **envelope encryption**. A KMS/secret-store **master key** wraps a **per-tenant data key**; the data key is what is passed to the session as `app.pii_key` (via `SET LOCAL`, never logged). Key rotation re-wraps the data key without re-encrypting every row; a full re-encrypt is a background job.
**Consequences:** Compromise of one tenant's data key does not expose others. Rotation is cheap. The app must fetch/unwrap the data key per tenant at connection setup.
**Pushback:** A single global `app.pii_key` is simpler but has a blast radius of *all* tenants and makes rotation a full-table rewrite. Envelope encryption is the world-class default for multi-tenant PII.

---

## ADR-0028 — Consignor/vendor liability accrues **at the moment of sale** (not at settlement)
**Status:** ACCEPTED (confirmed by the product owner)
**Context:** For consignment and vendor-mall sales, the amount owed to the consignor/vendor can be
recognized either (a) **at sale**, or (b) deferred until a periodic **settlement** run. This choice
determines whether a vendor portal can show *realtime* numbers.
**Decision:** Recognize the liability **at the moment of sale**. `post_sale` immediately credits the
`consignor_payable_control` / `vendor_payable_control` account, tagged to the consignor/vendor party,
and opens an AP open item. Settlement does **not** create the liability — it only *groups* already-
accrued amounts for payout.
**Consequences:**
- **Vendors see realtime balances**, because the portal reads the live ledger, not a batch table.
- The liability is faithfully represented at period end with no accrual adjustment needed.
- Settlement becomes a pure payout/grouping step (lower risk, fully reversible).
- Requires per-line consignor attribution at POS (`sale_line.consignor_party_id`).
**Pushback:** Deferring to settlement is simpler to implement but is **wrong under accrual accounting**
(the obligation exists the instant the goods sell) and makes a realtime portal impossible without a
parallel shadow calculation that inevitably drifts from the ledger. Accrual-at-sale keeps **one source
of truth**. This confirms and extends ADR-0022.

---

## ADR-0029 — Tender model: split tenders, clearing accounts, drawer over/short
**Status:** ACCEPTED
**Context:** A POS sale may be paid with multiple tenders (cash + card + store credit). Card money does
not arrive as cash on the sale date — it settles later, net of merchant fees. Cash drawers miscount.
**Decision:**
1. **Split tenders** are first-class: `payment_tender` is a child of `payment`; the sum of tenders must
   equal the payment total (DB-enforced).
2. **Clearing accounts**: card/other electronic tenders debit a **card clearing** asset, not `cash`.
   A later `post_merchant_settlement` moves clearing → bank and books **merchant fee expense** for the
   spread. This keeps the bank reconciliation honest.
3. **Liability tenders** (store credit, gift certificate) **debit the corresponding liability control**
   rather than an asset — redeeming a gift certificate extinguishes an obligation, it is not revenue.
4. **Over/short**: `post_shift_close` compares counted cash to expected cash and books the difference to
   `cash_over_short` (income/expense), never silently adjusting revenue.
**Consequences:** Cash, card, and liability tenders each post correctly; merchant fees are visible as
expense rather than netted into revenue; drawer discrepancies are auditable.
**Pushback:** Treating card sales as immediate `cash` is the common shortcut and it corrupts bank rec
and hides merchant fees. Netting fees against revenue understates both revenue and expense — a
reporting and tax defect. Clearing accounts are the world-class default.

---

## ADR-0030 — Period close and year-end close via Income Summary

**Status:** Accepted.
**Context:** The ledger enforced period locks but nothing could actually close a book, and there was no
Retained Earnings account for a year-end roll-up.
**Decision:**
1. Two lock levels: `closed` is a **soft lock** (reopenable via `reopen_period`); `locked` is a **hard
   lock** applied by year-end close and is not reopenable without reversing the close entry.
2. `close_period` refuses if the ledger is **out of balance** or if an **earlier period is still open**.
   Closing out of order hides gaps.
3. `close_fiscal_year` zeroes every income-statement account against **Income Summary (3950)**, then
   clears Income Summary to **Retained Earnings (3900)**, in a single balanced entry posted on the last
   day of the year. Income Summary must net to **zero** afterwards or the function raises.
4. Closing **posts a real journal entry**; it never mutates history. Undoing a close is a reversal.
**Consequences:** P&L accounts start each year at zero; equity carries forward correctly; the close is
idempotent by `idempotency_key` like every other poster.
**Pushback:** Many systems "close" by flipping a flag and computing retained earnings on the fly. That
leaves no audit trail for the roll-up. Posting a real close entry is the auditable default.

---

## ADR-0031 — Inventory valuation: weighted average cost

**Status:** Accepted (default; revisit before go-live if tax strategy requires FIFO).
**Context:** Owned goods could be sold through POS but nothing decremented stock or booked COGS, so
margin on owned inventory was invisible. Consigned goods are unaffected — the store never owns them.
**Decision:**
1. **Weighted average cost** (moving average), recomputed on every receipt.
2. Inventory is tracked in `inventory_item` (the definition + current on-hand + current average cost)
   with an append-only `inventory_movement` ledger. **Movements are never edited**, mirroring the
   journal.
3. COGS is booked **at the moment of sale** for owned lines: debit COGS, credit Inventory — consistent
   with ADR-0028 (accrue at sale).
4. Consigned items are explicitly **excluded** from inventory valuation: the store holds them but does
   not own them, so they are not a balance-sheet asset.
**Consequences:** Margin is reportable per sale; the Inventory control account ties to
`Σ (on_hand × avg_cost)`, and this is asserted in the test suite.
**Pushback:** FIFO gives better matching in a rising-cost environment and is often preferred for tax,
but it requires layer tracking and makes every sale a multi-layer relief. For a mall/consignment store
whose owned inventory is a minority of volume, weighted average is materially simpler and defensible
under GAAP. **This is a reversible decision** — the movement ledger retains enough detail to rebuild
FIFO layers later if you want it.

---

## ADR-0032 — Stored value: gift certificates and store credit

**Status:** Accepted.
**Context:** Gift certificates and store credit were **redeemable as tenders but could not be issued** —
the liability had no origin. Views existed over journal lines with no backing document.
**Decision:**
1. Issuance creates a **liability, never revenue**: selling a gift certificate debits cash and credits
   the gift-certificate control. Revenue is recognised only on **redemption**.
2. Stored value is an **open-item subledger** keyed by certificate/credit, so each instrument has its own
   balance and ties to the GL control account like AR/AP.
3. **Breakage** (unredeemed value recognised as income) is **opt-in and explicit**, controlled by
   `tenant_config.breakage_after_months`. Default is **NULL = never**.
4. Escheatment is a **jurisdictional legal question, not a software default**. The schema records the
   data needed to comply; it does not silently take unredeemed balances into income.
**Consequences:** Stored value is auditable per instrument; the liability cannot drift from the GL.
**Pushback:** Recognising breakage automatically on a fixed schedule is common and is **legally wrong in
many US states**, where unredeemed balances escheat to the state rather than becoming income. Defaulting
to "never" is the safe, correct default; enabling it must be a deliberate act.

---

## ADR-0033 — Production backup and developer data are first-class, verified operations

**Status:** Accepted.
**Context:** Two operational gaps were called out as having caused real pain before: there was no easy
way to back up a tenant at go-live, and no way to run local development against real data. Both had
previously been handled ad hoc, which is how ad-hoc backups become unrestorable and how dev databases
quietly fill with invented data that hides real bugs.
**Decision:**
1. Backup is **per tenant**, not per cluster. Schema-per-tenant means one customer is one schema; there
   is no reason to move the entire cluster to protect one of them.
2. Schema dumps keep **GRANTs**. RLS policies without the grants they depend on restore into an
   isolation model that silently does not isolate.
3. **Every backup is verified when written, and restores are verified when performed.** Verification
   means trial balance zero, every subledger tying to its GL control account, RLS policies present, and
   row-count parity with the source — not "psql exited 0". `restore_tenant.sh --into <scratch>` exists
   so a backup can be proved restorable without touching the live tenant.
4. Developer datasets are **scrubbed by default**. `--raw` requires typing `EXPORT RAW PII`.
5. Scrubbing runs on a **throwaway staging copy**. Production is only ever read.
6. Scrubbing removes **identities**, never **amounts**. Amounts, dates, ids, relationships and row
   counts are what make the copy worth having; names are what make it a liability. The scrub aborts
   unless the books still balance afterwards.
7. The export is **leak-tested against the artefact**: the shipped dump is reloaded and its PII columns
   compared to production row by row. A failed leak test deletes the export.
**Consequences:** Backups are trustworthy because they are exercised. Dev runs on production-shaped data
without production-grade risk.
**Pushback, recorded because it is the substance of this ADR:** syncing raw production PII to a laptop
was the stated goal, and shipping that as the default would have been wrong. A laptop is not a
compliance boundary — it is outside production controls, it lands in personal backups, and it puts
every affected customer in scope for breach notification. The scrubbed copy preserves everything that
makes real data useful for development. `--raw` remains available behind deliberate, typed consent.
**Evidence this was not theoretical:** building the leak test caught three leaks that had already been
packaged into an export and would have shipped — the unscrubbed intermediate dump zipped alongside the
scrubbed one, `audit_log` before/after snapshots preserving every original value, and
`organization.trading_name`, simply missed. The scrub had reported success in all three cases. This is
precisely why the check is against the artefact rather than the script's own notices.

---

## ADR-0034 — 1099 reporting is derived from CASH, accumulated as it happens

**Status:** Accepted.
**Context:** The store pays consignors and vendors, and above a threshold must report those payments to
the IRS. The book of record is accrual (ADR-0022), but 1099 is unambiguously a **cash-basis** return:
what was actually paid in the calendar year, not what was earned or accrued in it.
**Decision:** A `tax_year_payment` row is written at the moment a reportable payment is made, keyed to
the year the money actually moved. It is append-only, and a CHECK enforces that `tax_year` equals the
year of `payment_date` so the two can never drift. Thresholds live in `tax_form_threshold`, keyed by
form, box and **tax year**, because they change: 600 for 2024–2025, then 2,000 from 2026 under OBBBA
s.70433. An unseeded future year falls back to the most recent seeded value rather than reporting
nothing. `form_1099_exceptions()` surfaces payees who are over the threshold but missing a TIN, a W-9
or an address, because those are the ones that make the filing fail.
**Consequences:** A payment made on 2 January is reported in the new year even though it settles the
prior year's accrual, which is correct and is asserted directly (tax1099 X4). Backup withholding at 24%
is posted to its own liability account rather than netted into the payment.
**Rejected:** deriving 1099 totals by querying the ledger at year end. The accrual ledger does not know
when cash moved, reversals and reclassifications make the query non-deterministic, and a number the
store cannot reproduce next year is a number it cannot defend in an audit.

---

## ADR-0035 — Percentage rent and CAM are accrued on estimate, trued up on actuals

**Status:** Accepted.
**Context:** Percentage rent ("5% of sales over a 50,000 breakpoint") and CAM recovery cannot be known
until the period ends, but the landlord bills monthly throughout it.
**Decision:** Bill estimates during the period, then post a single adjusting true-up entry against
actuals. Four rules are enforced in the DB rather than left to the biller:
1. Percentage rent applies **only to the excess** above the breakpoint. Charging the rate on gross is
   the classic error and it over-bills every tenant who trades above breakpoint.
2. Refunds **reduce the sales base**. Otherwise a tenant is billed percentage rent on goods that came
   back.
3. The CAM pro-rata denominator is **leased area, not total area**. Including vacant units silently
   shifts the landlord's cost of their own empty space onto the tenants who did turn up.
4. Over-recovery is **credited back**, not kept.
Escalations and renewals are **effective-dated** (GiST no-overlap), never overwrites, so the rent in
force on any past date remains answerable.
**Consequences:** Re-running a true-up must not double-bill, and the guard cannot be the idempotency
key alone — an operator re-running year end with a fresh key must still be refused (lease L6). The
already-billed amount is subtracted inside the calculation itself.

---

## ADR-0036 — Markdowns are events; layaway deposits are liabilities

**Status:** Accepted.
**Context:** Two retail mechanics that are really accounting questions in merchandising costume.
**Decision (markdowns):** A markdown is recorded as an **event**, never as a price overwrite. The
current price is derived; history is never lost. Every event records **who absorbs** the reduction —
store, consignor, or shared with an explicit split — because that has a direct cash consequence and it
is the single thing consignors dispute. Most systems assume "consignor" silently and then cannot
defend the settlement. Marking down posts **no journal entry**: nothing has been bought, sold or paid.
The margin consequence lands when the item sells, through the commission split.
**Decision (layaway):** A deposit is a **liability**, not revenue. The customer has paid, the store has
not delivered, and the customer can usually walk away. Deposits credit a layaway control account; at
pickup the liability is released into revenue and **cash is not touched again**, because it arrived at
deposit time. On cancellation the liability unwinds into a refund (not income) plus any forfeited fee
(which is income). Goods on layaway are **reserved** — off the floor, not sold — and cannot be
reserved twice.
**Consequences:** Recognising deposits as revenue on receipt overstates income, overstates tax, and is
unlawful in states that regulate layaway. The reservation guard is scoped to **open** layaways: a plain
unique index would also brick the item forever after a cancellation, when the goods are physically back
on the shelf (retail R22).

---

## ADR-0037 — Tiered commission is trued up per period, and rated MARGINALLY

**Status:** Accepted.
**Context:** ADR-0028 accrues the consignor split at sale, which is right — the store owes the
consignor the moment the goods leave. But a **tiered** rule cannot be evaluated one sale at a time: at
the moment of a given sale, nobody knows where it will sit in the consignor's cumulative total for the
period.
**Decision:** Keep accruing at the sale-time rate, then compute the correct tiered commission over the
whole period and post the **difference** as a visible adjusting entry. Never rewrite the original
accrual: the sale is posted, the period may be closed, and the consignor may already have been paid.
Tiers are **marginal**, not cliff: a 5,000 breakpoint means the first 5,000 is charged at the base rate
and only the excess at the tier rate.
**Consequences:** Charging the flat rate and never revisiting it systematically **overcharges
high-volume consignors** — and it does so in proportion to volume, so the best consignors are the most
overcharged and they are the ones who leave. Cliff rating is the other plausible reading and it is
perverse: it makes commission **fall** as sales rise, so selling one more dollar of goods can make the
store hundreds poorer. Marginal is the only monotonic structure (retail R27).
**Both sides of the arithmetic are stored** (accrued *and* correct, not just the delta) so the store can
explain the adjustment to the consignor months later without re-deriving it from the sales history.

---

## ADR-0038 — Money may never rest in a control account without naming a party

**Status:** Accepted.
**Context:** `assert_subledger_control()` guarded only one direction: it stopped a **tagged** line from
landing on the wrong account. Nothing stopped an **untagged** line from landing on a control account.
So this was legal:

```
debit  1100 Accounts Receivable   500.00     <-- no party
credit 4000 Sales Revenue         500.00
```

It balances. The trial balance stays at zero. Every assertion in the suite passed. And that 500.00 of
receivable is owed by **nobody**: it appears on no customer statement, it can be invoiced to no one, and
it will never be collected. It surfaces only later as an unexplained difference in
`subledger_control_check()`, long after the originating transaction is findable.
**Decision:** A `BEFORE INSERT` trigger refuses any journal line hitting a control account without
`party_id` + `subledger_type_code`. The sole exception is a genuine **bearer** instrument — an
anonymous gift certificate has no holder to record — whitelisted per subledger type via
`subledger_type.allows_untagged` so the exemption is a reviewable data decision rather than a hole.
**Consequences:** Balanced is not the same as correct. A detective control that tells you the books are
wrong is worth far less than a preventive one that stops them going wrong; `subledger_control_check()`
remains as the backstop, and this trigger is what makes it boring. Migration 0005 **refuses to install
the guard** if existing data already violates it, reporting the offending lines instead, because
installing a constraint the live books already break is how a migration becomes an outage.
**Related:** `subledger_type.uses_open_items` was added at the same time. Security deposits, layaway
deposits, stored value and accrued vendor payables legitimately carry a GL control balance with no
`open_item` behind it, and `open_item_control_check()` was reporting all four as permanent differences
on a healthy database. A check that always shows failures is a check everyone learns to ignore — and
it hides the one real imbalance when it finally appears.

---

## ADR-0039 — Settlement integrity: reversal un-applies, one allocator, no silent cash, hash-chained journal

**Status:** Accepted.
**Context:** A review of the settlement layer found six defects (F1–F6) that all
share one property: **the trial balance still nets to zero while the detail
lies.** They were not caught by the existing 222 assertions because those
assertions were written after the code, against what the code does, rather than
before it, against what it must do. The invariants are now written down first in
`docs/SETTLEMENT_INVARIANTS.md`; this ADR records the decisions that enforce them.

**F1 (critical) — reversing a payment did not un-apply it.** `reverse_journal_entry()`
mirrored the journal lines and stopped. The `payment_application` rows and the
`open_item.open_amount` they had reduced were left untouched. So after reversing
a receipt, the GL control account was correct (the mirror entry restored it) but
the open items still showed the invoice as paid. `open_item_control_check()`
then failed by exactly the reversed amount — a real imbalance, produced by the
system's own reversal path. **Decision:** reversal is a **document status**, and
reversing a settlement entry calls `unapply_for_entry()`, which restores each
affected open item and recomputes its status. The un-application is recorded
append-only (PA-5), so history shows both the application and its reversal.

**F2 (critical) — FIFO was mandatory.** A customer who wanted to pay one specific
invoice could not; the allocator always consumed oldest-first. **Decision:**
`allocate_payment()` takes an optional `p_open_item_id`; the named item is
consumed first, then FIFO proceeds. FIFO remains the default (AL-3, AL-4).

**F3 — four copies of the allocator, two of them wrong.** `apply_payment`,
`post_consignor_payout`, and `post_refund` each re-implemented FIFO, and the
latter two omitted the `item_kind = 'invoice'` filter, so a payout or refund
could "settle" a credit memo. **Decision:** exactly one allocator,
`allocate_payment()`; every entry point calls it (AL-1, AL-2).

**F4 — two allocators silently swallowed unapplied cash.** `post_consignor_payout`
and `post_refund` dropped any remainder on the floor: the cash left the bank, the
control account moved, and the open items did not — a silent drift. **Decision:**
`allocate_payment()` never drops a remainder. It either records an **on-account**
open item (`item_kind = 'on_account'`) or raises; the default is to raise,
because silently absorbing cash is how a subledger drifts from its control (AL-5).

**F5 — `payment_application` was mutable, and stored-value redemption bypassed it.**
The table had only an audit trigger, so applications could be edited or deleted,
and `redeem_stored_value()` reduced `open_item.open_amount` directly with no
application row at all. **Decision:** `payment_application` is append-only
(`kernel.forbid_mutation`), and `open_item_application_check()` reconciles
`original − open` against the net of applications (PA-2, PA-4).

**F6 — write-off race and sign-masking.** `write_off_open_item()` read its target
without `FOR UPDATE`, so a concurrent settlement could race it; and
`open_item_control_check()` compared `abs()` of both sides, which masks a genuine
sign error as a match. **Decision:** `FOR UPDATE` on the write-off read; the
control check compares **signed** sums (CA-2, CA-4).

**Ported from EMP (three ideas worth keeping):**

- **B1 — hash-chained journal.** Each entry stores `prev_hash` (the previous
  entry's `entry_hash` for the tenant) and `entry_hash` (a digest over the
  entry's immutable content plus `prev_hash`). Tampering with history breaks the
  chain and `verify_journal_chain()` reports the first broken link (JI-3).
- **B2 — scale CHECK.** A `CHECK` rejects any amount whose scale exceeds the
  currency's scale, so `1.005` cannot be posted to a USD ledger (MO-1). The
  application layer already refuses floats; this closes the door at the database.
- **B3 — reversal-as-document-status.** A reversed entry is reported as reversed
  and **cannot be reversed again**; the status is authoritative rather than
  inferred from the presence of a mirror (RV-4). This is the structural form of
  the F1 fix.

**Consequences:** The settlement layer now has one allocator, an append-only
application history, a reversal path that keeps the subledger tied to the
control, and a tamper-evident journal. The cost is a small amount of indirection
(one allocator function) and one extra reconciliation query on the hot path of
nothing — `open_item_application_check()` is a reporting check, not a trigger.
The hash chain adds one digest per entry; it is computed in a `BEFORE INSERT`
trigger and is not on the read path.

**Related:** `docs/SETTLEMENT_INVARIANTS.md` (the normative statements),
migration `0007_settlement_integrity.sql`, and the regression suite
`db/tests/settlement.sql`.

---

## Open decisions for you
1. ~~**ADR-0006:** switch `journal_line.id` to `bigint`?~~ **DONE.**
2. ~~**ADR-0007:** keep RLS on the hot `journal_line` path?~~ **DONE** — measured ~3× cost; RLS disabled on journal tables, kept elsewhere; `ninja_migrator` BYPASSRLS added.
3. ~~**ADR-0008:** split the control plane into its own database?~~ **DONE** — `ninja_control` + `ninja_emp`.
4. ~~**ADR-0012:** drop literal 100% coverage in favor of an MSI gate?~~ **DONE** — resolved by **ADR-0024** (MSI ≥ 80%).
5. ~~**ADR-0011 (DBAL):** decimal lib, savepoints, native prepares?~~ **DONE** — resolved by **ADR-0025** (bcmath strings, savepoints supported, emulated prepares).
6. ~~**ADR-0019:** partition-enablement threshold?~~ **DONE** — resolved by **ADR-0026** (20M `journal_line` rows/tenant).
7. ~~**ADR-0018:** PII key management?~~ **DONE** — resolved by **ADR-0027** (envelope encryption, KMS-wrapped per-tenant data key).
8. ~~**Accrual at sale vs at settlement?**~~ **DONE** — resolved by **ADR-0028** (accrual at sale; realtime vendor portal).

9. ~~**Inventory valuation: FIFO or weighted average?**~~ **DONE** — resolved by **ADR-0031** (weighted average; reversible).
10. ~~**Gift certificate breakage policy?**~~ **DONE** — resolved by **ADR-0032** (opt-in, default never; escheatment is a legal question).

**No open decisions remain.** New questions will be raised as ADRs as work surfaces them.

> **Two ADRs above are defaults I chose so work could continue — both are cheap to reverse and worth
> your explicit sign-off:** ADR-0031 (weighted average vs FIFO) and ADR-0032 (breakage default of never).
