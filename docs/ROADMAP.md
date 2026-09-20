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
| — | Open-item AR/AP (aging + cash-basis conversion) | ✅ |
| — | Durability: git, backups, restore, zip bundles | ✅ |

**Proven:** 56 assertions across 4 suites, all idempotent, verified after a backup→restore round-trip.

## Next — Part 5: POS & Payments (DB-first)

The point-of-sale and money-movement layer. Build order:

1. **Tender types** — cash, card, check, **customer store credit**, **vendor payable draw**,
   gift certificate. Lookup table + posting roles.
2. **Sale / sale_line** — central checkout and vendor-run checkout; per-line tax, discount,
   commission routing (consignment lines → consignor payable; owned lines → inventory/COGS).
3. **Payment / payment_tender** — split tenders, change, over/short; ties to open-item AR.
4. **Sales tax** — tax jurisdictions, rates, tax collected payable; exemption certificates.
5. **Merchant fees** — processor fee expense, net settlement deposit, fee reconciliation.
6. **Cash drawer / shift** — opening float, counts, over/short posting.
7. **Returns / refunds** — reversal-not-edit; restock; store-credit issuance.
8. **1099-NEC** — vendor/consignor reportable payments, threshold tracking, year-end export.
9. **Posting functions** — `post_sale`, `post_payment`, `post_refund`, `post_drawer_count`,
   all idempotent and `posting_map`-driven.
10. **Assertion suite** — `db/tests/pos.sql`.

## Then — Part 6: Application Layer

- Feature modules + service contracts (PHP 8.5, no frameworks, PSR-3/4/7/11/12/15).
- Routing + middleware; auth (sessions, RBAC via party roles).
- API-first: OpenAPI 3.1 spec generated from contracts.
- Server-rendered PHP templates + a map island for the mall floor plan.
- DBAL per ADR-0025 (bcmath + string money, savepoints, emulated prepares for PgBouncer).
- Quality gate: PHP-CS-Fixer, PHPStan L10, PHPMD, Deptrac, mutation testing (MSI ≥ 80%, ADR-0024).

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

**Part 5, step 1: tender types + sale/sale_line schema.** Say the word and I'll build it DB-first
the same way — schema, posting functions, and an assertion suite proven on live PostgreSQL.
