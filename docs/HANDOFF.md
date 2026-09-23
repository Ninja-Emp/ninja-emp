# Ninja EMP — Project Handoff & Decision Record

**Codename:** Ninja EMP (Enterprise Mall Platform) **Repo path:** C:\\laragon\\www\\ninja-emp **Status:** Pre-build. Greenfield. DB-first. No application code written yet. **Purpose of this doc:** Seed a fresh chat with full context so no decisions are lost.

* * *

## 1\. Product Vision

Build the **ultimate best vendor mall AND consignment store software on the market**, with **world-class double-entry accounting** as the foundation. No competitor has true double-entry. The ledger is the single source of truth; everything else is written against it.

Two operating models, one shared ledger core:

-   **Vendor-run checkout** (landlord model): mall is lessor; revenue = rent + fees; vendor is merchant of record.
-   **Central checkout** (agent model): mall is merchant of record; commission is revenue; vendor is owed a net settlement.
-   **Hybrid** (rent + commission): both postings coexist; settlement engine nets them.

Both models are supported from ONE double-entry core + two thin domain modules.

### Business realities to model (confirmed by owner)

-   Store owner also sells their own items → model as a Party with a vendor/consignor role flagged `is_house`; settlement routes to owner's equity/draw, not a third-party payable.
-   Store buys items from vendors/consignors → store acts as buyer (outright purchase → Inventory asset; or consignment buyout; can net against vendor payable).
-   Vendors/consignors are also customers and can **buy in-store using money the store owes them** → this is a **vendor-payable draw / set-off**, a DISTINCT tender type from customer store credit.
-   **Customer store credit** (from a return) is a separate liability (refund liability owed to a customer) — different subledger, different legal meaning, but also a tender type at POS.
-   POS tender types must therefore include: cash, check, card, gift certificate, **customer store credit**, and **vendor payable draw** — visually similar to cashier, posting to different accounts.

### Settlement equation

Net payout = Sales − Commission − Rent − Fees − Prior balance − Draws taken

* * *

## 2\. Locked Technical Decisions

| Area | Decision |
| --- | --- |
| Language | PHP 8.5 (confirmed) |
| Database | PostgreSQL, **schema-per-tenant** SaaS |
| PG version | **PostgreSQL 18** — one version everywhere (Laragon, Docker, CI, prod), pinned to exact minor. Native `uuidv7()` for append-only journal keys. |
| Money | **USD base** (multi-currency-ready). `NUMERIC(19,4)` + `currency CHAR(3)` on every amount. Never use PG `money` type. |
| DB access | PDO, **named parameters** (not positional). DBAL design deferred to a later dedicated talk. |
| Architecture | OOP, SOLID, feature-based vertical slices / bounded contexts, shared kernel |
| Frameworks | **NONE.** Third-party libs only after case-by-case discussion. |
| PSR | PSR-3 (logging), PSR-4, PSR-7 (**Nyholm adopted**), PSR-11, PSR-12, PSR-15 (middleware) |
| Logging | Monolog (PSR-3) — logging is not our moat |
| Container | **`krubio/perfect-container-psr-11` — CONDITIONALLY APPROVED** (see §10). Fork/vendor + patch 2 defects before production use. |
| Routing | Attribute-based, dynamic route params, pretty URLs (cache compiled route table) |
| API | **API-first.** Maintain an **OpenAPI 3.1** document as source of truth. Versioned `/v1`. |
| UI | **Server-rendered PHP templates** (clean separation) + progressive enhancement. JS only where needed; the **map builder is a single JS "island."** |
| DB modeling | **Party Model Architecture** (Party / PartyRole / PartyRelationship / PartyContactMechanism) |
| Dev env | Laragon on Win 11 VM; **Docker** for parity with Linux prod (recommended + accepted) |
| Multi-tenancy | Schema-per-tenant + **RLS as defense-in-depth** (use `FORCE ROW LEVEL SECURITY`) |
| Pooling | PgBouncer **transaction mode** + `SET LOCAL search_path` per transaction (DBAL-enforced). PgBouncer 1.21+ with `max_prepared_statements` for native prepares. Tenant→pool router with dedicated-pool escape hatch. |
| Migrations | Resumable, batched, per-schema migration runner (day-one design decision) |

* * *

## 3\. Accounting Principles (non-negotiable invariants)

-   Double-entry ledger is the **single source of truth**.
-   **Append-only journal.** Corrections are **reversals, never edits**.
-   **DB-enforced balance**: deferred constraint trigger — Σ debits = Σ credits per journal entry.
-   **Idempotent posting** (safe to retry).
-   **Period close / locking.**
-   **Subledgers** (AR, AP, vendor payable) tie to **GL control accounts**.
-   **Trial balance = 0** invariant. Assets = Liabilities + Equity.
-   **Invariant test harness** proves these never break.
-   **Money precision:** never round silently, never lose value. Carry full precision through all intermediates. When a rounding is mathematically forced (FX, percentage allocation, denomination rounding), record it as an **explicit, auditable adjustment line** so the ledger balances to the penny. Use **exact allocation (largest-remainder)** for splits — parts always sum to the whole.
-   **The scale you choose IS your rounding boundary** — `NUMERIC(19,4)` rounds at the 4th decimal, which is beyond real-world need.

* * *

## 4\. Quality Gate (Definition of Done)

Every commit must pass, in CI, in order:

1.  **PHP-CS-Fixer** — style (PSR-12), auto-fixed
2.  **PHPStan level 10** — zero errors, no baseline for our own code
3.  **PHPMD** — complexity/coupling rules (no god classes), zero violations
4.  **Deptrac / PHPat** — architecture boundaries intact (bounded contexts enforced)
5.  **Unit tests** — fast, on the shared kernel
6.  **Functional tests** — against **real PostgreSQL** (never SQLite), incl. ledger invariants
7.  **Mutation testing (Infection)** — **primary gate**
8.  **End-to-end (E2E)** — critical money journeys over HTTP against the **real front controllers** (the "grandma can use it" acceptance layer). Implemented as a PHPUnit suite (`tests/E2E/`) that boots `php -S` on a free port and drives the real app — no extra runtime dependency.
9.  **Smoke** — app boots, login works

**Coverage policy (user's call):** **100% coverage everywhere**, with **mutation testing as the real gate that counts more than coverage.** Note: equivalent mutants make literal 100% MSI theoretically impossible; document exceptions rather than silently lowering the bar.

**Test pyramid:** unit (pure domain, no DB) → functional (real PG, proves the ledger) → contract (API vs OpenAPI spec) → E2E (critical journeys only, not every button) → smoke. The unit and E2E layers both run under one umbrella: `composer test` (PHPUnit).

* * *

## 5\. Dependency Policy

-   **Runtime:** no frameworks. Tiny, deliberate allowlist. Fork/vendor anything critical so we own it.
-   **Dev tooling:** unrestricted (PHPStan, PHPMD, PHP-CS-Fixer, Infection, Codeception, Deptrac, PHPat, Monolog, Nyholm, container lib). These are instruments, not runtime dependencies.
-   **Rationale:** user's concern is "I don't want someone else changing my app." Libraries are versioned immutable artifacts via `composer.lock` — nobody edits our code. Mitigate supply-chain risk with lock files, `composer audit` in CI, and forking critical deps.

* * *

## 6\. SRS Outline (pragmatic — build only what's in scope, section by section)

**Part 0 — Platform & Non-Functionals** Multi-tenancy (control plane vs tenant plane), connection/search\_path strategy, migration strategy, backup/restore, security, audit, RBAC, performance targets.

**Part 1 — Foundational Data Model** Party Model; Money & Currency; Time & Periods (fiscal calendar, period locking).

**Part 2 — The Ledger (the heart)** Chart of Accounts (hierarchical, typed); Journal Entry + Journal Line (append-only); DB-enforced balance; reversal-not-edit; idempotent posting; posting-rules engine; subledgers tied to GL control accounts; trial-balance invariant; invariant test harness.

**Part 3 — Domain: Vendor Mall** Locations → floors → booths/areas; leases; rent billing components (base + CAM + fees); deposits; delinquency/liens; abandoned property; waitlist→lease.

**Part 4 — Domain: Consignment** Consignor intake; item tagging; commission engine; markdown/discount; returns; layaway; gift certs; settlement/payout; vendor statements.

**Part 5 — POS & Payments** Central + vendor-run checkout; cash drawer; card/check; Square integration; merchant fees; sales tax; 1099-NEC; **tender types incl. customer store credit and vendor payable draw**.

**Part 6 — Application Layer** Feature modules, service contracts, routing, middleware, auth, API surface, server-rendered UI + map island.

**Part 7 — Integrations & Reporting** QB/Xero export mapping; reporting depth; dashboards.

**Part 8 — Invariants & Test Strategy** The accounting invariants that must never break, and how we prove it.

* * *

## 7\. Working Agreements

-   **ALWAYS push back** if a suggestion is not world-class, or if there's a better way. The user explicitly wants this. Do not be agreeable for its own sake.
-   **DB-first.** The DB is the foundation; all code is written against it. Agree the schema before writing application code.
-   **Pragmatic SRS.** No information overload on things not yet being worked on. Expand section by section as we build.
-   **Externalize decisions to files** (SRS, DECISIONS.md/ADRs, DDL). Chat history is volatile; files are the durable memory. No chat is load-bearing.
-   **Chat structure:** hub + spokes. One lean decisions hub; a focused chat per workstream (DB-Party, DB-Ledger, DB-VendorMall, DB-Consignment, App-Architecture, App-POS, Quality-CI, SRS).
-   **User profile:** PHP master, 30+ years senior software engineer, Senior DBA. Does NOT know JS syntax (can read it). Prefers PHP's clean separation over JS-intermingled HTML.

* * *

## 8\. Open Decisions / Next Steps

1.  **First build artifact:** DB-first SRS skeleton + foundational PostgreSQL schema (Party Model + Money + ledger core) + ERD + DECISIONS.md.
2.  **Container lib:** fork/vendor `krubio/perfect-container-psr-11` and patch the 2 defects in §10 (or accept the documented limitations and guard against them).
3.  **DBAL design:** dedicated talk (named params, placeholder uniqueness, typing, `SET LOCAL`).

* * *

## 9\. Prior Work (context, not to be reused)

A separate **booth rental management app** was previously built (PHP 8.2 + PostgreSQL, schema-per- tenant, vanilla-JS SPA, SVG multi-floor map builder). It is a **booth-rental admin tool**, NOT a vendor mall OS. It is **frozen as-is** and is a different product. Do not carry its architecture forward — Ninja EMP is greenfield and ledger-first.

* * *

## 10\. Container Library Review — `krubio/perfect-container-psr-11`

**Reviewed:** 2025-09 (source at github.com/benanamen/perfect-container-psr-11, v2.0.0) **Method:** full source read + empirical test harness (19 behavioral checks) on PHP 8.2.

### Verdict: CONDITIONALLY APPROVED — fork/vendor it and patch 2 defects before production.

### What's good

-   **PSR-11 compliant.** Correctly implements `ContainerInterface`; throws proper `NotFoundExceptionInterface` / `ContainerExceptionInterface` (anonymous classes).
-   **Zero runtime dependencies** except `psr/container ^2.0`. Tiny supply-chain surface.
-   **PHPStan level 10** configured and passing; **PHPUnit 12** with 100% coverage claimed; PHP-CS-Fixer configured; CI runs tests on Linux + Windows, PHP 8.3/8.4.
-   **Clean, readable, strict-typed** single-class implementation (~130 lines). Easy to audit.
-   **Autowiring works** for nested constructor deps and interface→implementation binding.
-   **Sensible error handling** — union types, abstract classes, unresolvable scalars all throw clear exceptions rather than failing silently.
-   **MIT licensed** — free to fork and modify.

### Defects found (empirically verified)

**DEFECT 1 — No circular-dependency detection → fatal crash.** `A` depends on `B`, `B` depends on `A` → infinite recursion → `Allowed memory size exhausted` fatal error. There is no resolution stack / visited-set guard. In a large DI graph a single accidental cycle takes down the whole request with an unrecoverable fatal (not a catchable exception). **Must patch:** track in-progress resolutions and throw `ContainerExceptionInterface` on a cycle.

**DEFECT 2 — No instance caching (not a singleton container).** `get(Db::class)` twice returns **two different instances**. Every `get()` of an unregistered class re-instantiates it. For a ledger app this is dangerous: a shared service (DB connection, ledger service, unit-of-work) resolved in two places would be two separate objects → lost state, broken transactions. **Must patch:** cache resolved instances (or explicitly document that all shared services must be registered as closures with manual singletons — which the MIGRATION.md admits).

### Minor observations

-   `has()` returns `false` for an autowirable-but-unregistered class even when autowiring is on — technically PSR-11-legal but can surprise callers.
-   No compiled-container mode — reflection runs on every resolution. Fine at small scale; consider caching for hot paths.
-   Bus factor 1 (single author), 1 star, 3,080 installs, 1 dependent. Low adoption — but the code is small and auditable, so this matters less than for a large dependency.
-   `composer.json` requires `php: ^8.3`; PHP 8.5 compatibility not explicitly declared (should work, but verify).

### Recommendation

**Fork it into our namespace** (e.g. `NinjaEMP\Container`), patch Defect 1 (cycle guard) and Defect 2 (instance caching), add tests for both, and own it. It's a small, clean, well-typed foundation — exactly the kind of thing worth owning rather than depending on. This also satisfies the user's "I don't want someone else changing my app" requirement completely.