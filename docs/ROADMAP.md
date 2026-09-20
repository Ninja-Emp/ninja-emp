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

**Proven:** 83 assertions across 5 suites, all idempotent, verified after a backup→restore round-trip.

## Next — Part 6: Application Layer

With the domain schema stable through Part 5, the next build is the PHP application layer.

1. **DBAL** per ADR-0025 — bcmath + string money, savepoints, emulated prepares (PgBouncer).
2. **Feature modules + service contracts** (PHP 8.5, no frameworks, PSR-3/4/7/11/12/15).
3. **Routing + middleware**; auth (sessions, RBAC via party roles).
4. **Vendor portal UI** — the realtime views from Part 5 are already built and proven.
5. **API-first**: OpenAPI 3.1 spec generated from the contracts.
6. **Server-rendered PHP templates** + a map island for the mall floor plan.
7. **Quality gate**: PHP-CS-Fixer, PHPStan L10, PHPMD, Deptrac, mutation testing (MSI ≥ 80%).

## Remaining Part 5 follow-ons (deferred, not blocking)

Square/processor API integration · 1099-NEC generation and threshold tracking · vendor payable
draw as a tender · gift-certificate issuance flow · inventory decrement for owned goods.

## Then — Part 7: Integrations & Reporting

- QuickBooks / Xero export mapping (CoA + journal export).
- Reporting depth: trial balance, P&L, balance sheet, cash-basis conversion, aging,
  consignor statements, vendor statements, sales tax reports.
- Dashboards.

## Cross-cutting (ongoing)

- Partition-enable the journal at the 20M-row threshold (ADR-0026).
- PII envelope encryption with KMS (ADR-0027).
- Resumable migrations runner.
- CI pipeline: provision → test suites → mutation gate → build.

## Immediate next action

**Part 6, step 1: the DBAL** (ADR-0025) — the foundation every service will sit on. Alternatively,
if you'd rather keep going DB-first, the Part 5 follow-ons above (1099-NEC, gift certificates,
inventory) are the natural next schema work.
