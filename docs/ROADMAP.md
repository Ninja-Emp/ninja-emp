# Ninja EMP — Roadmap

DB-first sequencing. Each part is built as schema + posting functions + assertion suite, proven
on live PostgreSQL before moving on. Application code (Part 6) comes after the domain schema is
stable.

## Done

| Part | Scope | Status |
|------|-------|--------|
| 0 | Platform & non-functionals (SaaS, RLS, PgBouncer, migrations) | ✅ |
| 1 | Foundational data model (Party Model, Money, audit, PII) | ✅ |
| 2 | **The Ledger** — CoA, journal, invariants, posting API, `posting_map` | ✅ |
| 3 | **Vendor Mall** — location→floor→space, lease, rent, deposit, delinquency | ✅ |
| 4 | **Consignment** — agreements, commission rules, items, sales, settlements, payouts | ✅ |
| 5 | **POS & Payments** — tenders, tax, registers/shifts, sales, refunds, merchant settlement | ✅ |
| — | **Realtime vendor portal** — ledger-sourced views, ties to GL control | ✅ |
| — | Open-item AR/AP (aging + cash-basis conversion) | ✅ |
| — | Durability: git, backups, restore, zip bundles | ✅ |
| 6a | **Financial statements** — P&L, balance sheet, cash-basis derivation | ✅ |
| 6b | **Period & year-end close** — close/reopen, retained earnings, income summary | ✅ |
| 6c | **AR write-off** — bad-debt routine, reversible | ✅ |
| 6d | **Inventory** — moving weighted-average cost, COGS on owned sales (ADR-0031) | ✅ |
| 6e | **Stored value** — gift certificates / store credit, opt-in breakage (ADR-0032) | ✅ |
| 6f | **Vendor draw** — payable draw as a tender, overdraw guard | ✅ |
| 6g | **1099-NEC** — cash-basis accumulation, year-keyed thresholds (ADR-0034) | ✅ |
| 6h | **Percentage rent + CAM true-up** — excess-only, over-recovery credited (ADR-0035) | ✅ |
| 6i | **Markdown engine + layaway** — events not overwrites; deposits are liabilities (ADR-0036) | ✅ |
| 6j | **Percentage-commission true-up** — rated marginally, monotonic (ADR-0037) | ✅ |
| — | **Migrations runner** — versioned, resumable, idempotent, checksum drift detection | ✅ |
| — | **Per-tenant backup/restore** + **scrubbed prod→dev sync** with leak test | ✅ |

**Proven:** **222 assertions across 10 suites**, all idempotent, from a clean
`provision.sh` → `migrate.sh` → `run_tests.sh`, and verified after a
backup→restore round-trip. The database is complete.

## In progress — Part 6: Application Layer

With the domain schema **complete and proven**, the PHP application layer is underway.

| Step | Scope | Status |
|------|-------|--------|
| 6.1 | **DBAL** per ADR-0025 — bcmath + string money, savepoints, emulated prepares (PgBouncer) | ✅ |
| 6.2 | **Ledger engine** — idempotent posting, posting_map account determination, reversal, tenders | ✅ |
| 6.3 | **Feature modules + service contracts** (PHP 8.5, no frameworks, PSR-3/4/7/11/12/15) | ⏳ |
4. **Routing + middleware**; auth (sessions, RBAC via party roles).
5. **Vendor portal UI** — the realtime views from Part 5 are already built and proven.
6. **API-first**: OpenAPI 3.1 spec generated from the contracts.
7. **Server-rendered PHP templates** + a map island for the mall floor plan.
8. **Quality gate**: PHP-CS-Fixer, PHPStan L10, PHPMD, Deptrac, mutation testing (MSI ≥ 80%).

**Delivered so far (6.1 + 6.2):** `src/` now contains the DBAL (`NinjaEMP\Db\*`:
`Connection`, `PdoConnection`, `TenantContext`, `PlaceholderRewriter`, `TypeMapper`,
`Identifier`, `ErrorMapper`, typed exceptions) and the ledger engine
(`NinjaEMP\Ledger\*`: `LedgerService`, `JournalEntry`, `JournalLine`, `Tender`),
plus the `Money`/`Currency` value objects. **83 unit assertions green** (`php tests/run.php`),
zero dependencies. Functional DBAL tests auto-skip without a live database.

## Deferred follow-ons (not blocking)

Square/processor API integration · formal vendor statements · abandoned-property / lien handling ·
journal partitioning at the 20M-row threshold (ADR-0026) · PII envelope encryption with KMS
(ADR-0027).

## Then — Part 7: Integrations & Reporting

- QuickBooks / Xero export mapping (CoA + journal export).
- Reporting depth: aging, consignor statements, vendor statements, sales tax reports,
  comparative P&L / balance sheet.
- Dashboards.

## Cross-cutting (ongoing)

- CI pipeline: provision → migrate → test suites → mutation gate → build.
- Partition-enable the journal at the 20M-row threshold (ADR-0026).
- PII envelope encryption with KMS (ADR-0027).

## Immediate next action

**Part 6, step 3: feature modules + service contracts.** The DBAL (6.1) and ledger engine (6.2)
are delivered and unit-tested. Next: build the domain services (Vendor Mall, Consignment, POS,
Inventory) on top of `LedgerService`, then routing + auth, then the vendor portal UI and the
OpenAPI 3.1 surface.
