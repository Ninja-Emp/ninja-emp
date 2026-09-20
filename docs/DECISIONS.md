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

## Open decisions for you
1. ~~**ADR-0006:** switch `journal_line.id` to `bigint`?~~ **DONE.**
2. ~~**ADR-0007:** keep RLS on the hot `journal_line` path?~~ **DONE** — measured ~3× cost; RLS disabled on journal tables, kept elsewhere; `ninja_migrator` BYPASSRLS added.
3. ~~**ADR-0008:** split the control plane into its own database?~~ **DONE** — `ninja_control` + `ninja_emp`.
4. ~~**ADR-0012:** drop literal 100% coverage in favor of an MSI gate?~~ **DONE** — resolved by **ADR-0024** (MSI ≥ 80%).
5. ~~**ADR-0011 (DBAL):** decimal lib, savepoints, native prepares?~~ **DONE** — resolved by **ADR-0025** (bcmath strings, savepoints supported, emulated prepares).
6. ~~**ADR-0019:** partition-enablement threshold?~~ **DONE** — resolved by **ADR-0026** (20M `journal_line` rows/tenant).
7. ~~**ADR-0018:** PII key management?~~ **DONE** — resolved by **ADR-0027** (envelope encryption, KMS-wrapped per-tenant data key).
8. ~~**Accrual at sale vs at settlement?**~~ **DONE** — resolved by **ADR-0028** (accrual at sale; realtime vendor portal).

**No open decisions remain.** New questions will be raised as ADRs when Part 5+ work surfaces them.
