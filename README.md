# Ninja EMP — Enterprise Mall Platform

A greenfield **vendor mall + consignment store SaaS** with world-class double-entry
accounting. **DB-first**: the PostgreSQL schema is the contract; application code follows it.

> **Status:** The database is **complete** (Parts 0–5 plus the full Tier 1/2/3 backlog) and
> proven on live PostgreSQL 18.6 — **241 assertions across 11 SQL suites, all green**. The PHP
> application layer (Part 6) is underway: DBAL, ledger engine, auth/tenancy, routing/middleware,
> the API-first OpenAPI 3.1 surface, and the server-rendered Tenant UI are built. The quality
> gate (PHPStan L10, PHPMD, Deptrac, PHPUnit, Infection) is in place.

---

## Quick start (two minutes, no Composer)

**Requirements to run the app:** **PHP 8.1 or newer** — that's it. The application is
**zero-dependency at runtime**: it needs no framework, no Composer, and no database to boot
the Tenant UI. (PHP **8.5** is the production target; the code uses nothing newer than 8.1.)

The task runner is **`php bin/ninja`** — pure PHP, so it works the same on Windows, macOS
and Linux. **You do not need `make`** (a `Makefile` is provided as an optional wrapper for
those who prefer it).

```bash
git clone https://github.com/Ninja-Emp/ninja-emp.git
cd ninja-emp

cp .env.example .env          # optional; sensible defaults are built in
php bin/ninja doctor          # check your environment (PHP version, extensions)
php bin/ninja serve-ui        # run the Tenant UI — no database, no Composer
```

Then open **<http://127.0.0.1:8091>** — the mall operator's back office. It is a fully
interactive console (POS, registers, booths, vendors, inventory, reports, settings) backed by
an in-memory mock repository, so it runs with nothing installed.

To run the **API** as well (needs the PSR interfaces, which the bundled bootstrap provides):

```bash
php bin/ninja serve           # API on :8092 + Tenant UI on :8091
```

- **API** — <http://127.0.0.1:8092/api/health> — docs at `/api/docs`, contract at `/api/openapi.json`

Run `php bin/ninja` on its own to list every task.

### Windows / Laragon

The runner is cross-platform: it resolves `composer`, `php` and other programs on `PATH` and
launches `.bat`/`.cmd` shims through `cmd.exe`, so it works from **Git Bash**, **PowerShell**,
**cmd.exe** or the Laragon terminal without any extra tooling.

```powershell
git clone https://github.com/Ninja-Emp/ninja-emp.git
cd ninja-emp
php bin\ninja doctor
php bin\ninja serve-ui
```

You do **not** need Composer to run the app. `php bin/ninja install` is only for the
development tooling (PHPUnit, PHPStan, …); if Composer is missing it now says so and points
you at `serve-ui` instead of failing. See `docs/LOCAL_DEV.md` for adding PostgreSQL 18 to
Laragon when you want the database-backed API.

### With the database (Docker)

For the full stack — PostgreSQL 18, provisioning, migrations — you also need **Docker**:

```bash
php bin/ninja install         # composer install (dev tooling; optional)
php bin/ninja up              # start PostgreSQL 18 in Docker
php bin/ninja provision       # create both databases + tenant schema + seeds
php bin/ninja serve           # run the API + Tenant UI
```

### Without Docker

Point `.env` at any PostgreSQL 18 instance and run `php bin/ninja provision` /
`php bin/ninja serve`. The provisioning scripts honour a `PSQL` override, e.g.
`PSQL="psql -h 127.0.0.1 -U postgres" bash db/provision.sh`.

---

## Applications (entry points)

There are exactly **two deployable applications**, each with its own document root under
`apps/`. A document root is the directory a web server points at; keeping one per
deployable is what lets the API and the UI scale, deploy and be secured independently.

| App | Namespace | Document root | Default port | Serve |
|-----|-----------|---------------|--------------|-------|
| **API** | `NinjaEmp\Api\*` | `apps/api/public` | `8092` | `php bin/ninja serve-api` |
| **Tenant UI** | `NinjaEmp\TenantUi\*` | `apps/tenant-ui/public` | `8091` | `php bin/ninja serve-ui` |

Both are served together with `php bin/ninja serve`. Each app has its own README
(`apps/api/README.md`, `apps/tenant-ui/README.md`) stating its document root and how to run it.

## Repository layout

```
src/                     the shared library (NinjaEMP\*): DBAL, ledger, money, auth, tenancy, HTTP, OpenAPI
apps/                    the deployable applications — one directory per web-facing app
  api/                   the API application (NinjaEmp\Api\*) — OpenAPI 3.1 surface
    public/              front controller + dev-server router (the document root)
  tenant-ui/             the Tenant UI application (NinjaEmp\TenantUi\*) — server-rendered templates
    public/              front controller + dev-server router (the document root)
db/                      PostgreSQL schema (DB-first). Numbered, idempotent, re-runnable.
  migrations/            versioned, resumable, checksum-verified migrations (0001…0007)
  tests/                 SQL assertion suites (11 suites, 241 assertions)
bootstrap/               zero-dependency autoloader + PSR interface stubs (used when vendor/ is absent)
bin/ninja                the developer task runner (pure PHP — no make, no bash)
scripts/                 backup / restore / sync / migrate helpers
tests/                   PHPUnit suite: Unit (harness bridge) + E2E (real front controllers)
docs/                    SRS, DECISIONS (ADRs), handoffs, ERD, DBAL, LOCAL_DEV, ROADMAP
  prototypes/            design prototypes (not deployable) — e.g. the vendor-portal mock-up
docker-compose.yml       PostgreSQL 18 for local development
Makefile                 optional wrapper around `php bin/ninja`
.env.example             configuration template (copy to .env)
```

The application is **zero-dependency PHP** at runtime: no framework, and the only Composer
runtime packages are the PSR interfaces (`psr/log`, `psr/container`, `psr/http-message`,
`psr/http-server-*`). Everything else under `require-dev` is tooling.

Because the app depends only on the PSR *interfaces* (not on any concrete package), it can run
**with or without Composer**. Every entry point requires `bootstrap/autoload.php`, which uses
`vendor/autoload.php` when it exists and otherwise registers a tiny PSR-4 autoloader plus
minimal PSR interface stubs (`bootstrap/psr-stubs.php`). That is what lets a fresh clone boot
on a machine that has only PHP installed.

---

## Commands

Every command is a task on the pure-PHP runner, so it works on any OS. `make <task>` is an
optional alias for `php bin/ninja <task>`.

| Command | What it does |
|---------|--------------|
| `php bin/ninja` | List every task |
| `php bin/ninja doctor` | Check your environment (PHP version, extensions, Composer, `.env`) |
| `php bin/ninja install` | Install dev tooling (`composer install`; optional — the app runs without it) |
| `php bin/ninja up` / `down` | Start / stop PostgreSQL 18 (Docker) |
| `php bin/ninja provision` | Create both databases + tenant schema + seeds (destructive) |
| `php bin/ninja migrate` | Apply pending migrations to every tenant schema |
| `php bin/ninja serve` | Run the API + Tenant UI dev servers |
| `php bin/ninja serve-api` / `serve-ui` | Run one app only (`serve-ui` needs no database) |
| `php bin/ninja test` | Full PHPUnit suite (unit + end-to-end) |
| `php bin/ninja test-unit` / `test-e2e` | One suite only |
| `php bin/ninja gate` | The whole quality gate, in CI order |

---

## Testing

The PHP suite runs under **PHPUnit**:

```bash
php bin/ninja test       # unit (harness bridge) + end-to-end
php bin/ninja test-unit  # unit only
php bin/ninja test-e2e   # end-to-end only (boots the real front controllers over HTTP)
```

- **Unit** — the pure domain (money, ledger, DBAL, HTTP, OpenAPI). Written against a tiny
  zero-dependency harness (`tests/TestHarness.php`) and driven through a PHPUnit bridge
  (`tests/PhpUnit/HarnessBridgeTest.php`) so mutation testing can map mutants to tests.
  **1,459 assertions**, plus functional DBAL tests that run against a live PostgreSQL
  (they auto-skip when `.env` is absent).
- **End-to-end** — the real `public/router.php` → `public/index.php` path for both apps,
  exercising routing, RBAC gating, views and the JSON endpoints over HTTP.

The **database** suites are separate (they need a live PostgreSQL):

```bash
bash scripts/run_tests.sh          # all 11 suites
bash scripts/run_tests.sh close    # just one suite
```

| Suite | Assertions | Result |
|-------|-----------|--------|
| `invariants.sql` | 28 | **PASS** |
| `consignment.sql` | 12 | **PASS** |
| `vendormall.sql` | 20 | **PASS** |
| `pos.sql` | 27 | **PASS** |
| `partition.sql` | 6 | **PASS** |
| `close.sql` | 23 | **PASS** |
| `inventory.sql` | 30 | **PASS** |
| `tax1099.sql` | 19 | **PASS** |
| `lease.sql` | 20 | **PASS** |
| `retail.sql` | 37 | **PASS** |
| `settlement.sql` | 19 | **PASS** |
| **Total** | **241** | **GREEN** |

---

## Quality gate (Definition of Done)

Every commit must pass, in CI, in order (`docs/HANDOFF.md` §4):

1. **PHP-CS-Fixer** — style (PSR-12)
2. **PHPStan level 10** — zero errors, no baseline
3. **PHPMD** — complexity/coupling, zero violations
4. **Deptrac** — architecture boundaries (bounded contexts)
5. **Unit tests**
6. **Functional tests** — against real PostgreSQL
7. **Mutation testing (Infection)** — the primary gate (MSI ≥ 80%; currently **81%**, Covered MSI 83%)
8. **End-to-end tests** — the critical journeys
9. **Smoke** — the app boots

Run it all locally with `php bin/ninja gate`.

---

## Documentation map

- `docs/SRS.md` — Software Requirements Spec (Parts 1–8; Parts 1–5 built).
- `docs/DECISIONS.md` — Architecture Decision Records (ADR-0001 … ADR-0039).
- `docs/HANDOFF.md` — locked technical decisions + working agreements.
- `docs/HANDOFF_SETTLEMENT.md` / `docs/HANDOFF_QUALITY_GATE.md` — workstream handoffs.
- `docs/DATA_STANDARDS.md` — normative enterprise data standards (ADR-0015).
- `docs/ERD.md` / `docs/erd.png` — entity-relationship diagram.
- `docs/DBAL.md` — database abstraction layer design.
- `docs/LOCAL_DEV.md` — set up PostgreSQL 18 alongside Laragon + Navicat.
- `docs/ROADMAP.md` — what's next (Part 6 onward).
- `docs/prototypes/` — design prototypes (not deployable), e.g. the vendor-portal mock-up.

---

## Key decisions (see `docs/DECISIONS.md` for the full set)

- **PostgreSQL 18**, schema-per-tenant SaaS, shared `kernel` schema, separate control-plane DB.
- **Party Model** (Silverston) for all actors.
- **Double-entry ledger**: append-only, DB-enforced balance, reversal-not-edit, idempotent
  posting, period locking, subledgers tied to GL control accounts.
- **Money** = `NUMERIC(19,4)` + `CHAR(3)` currency; never float, never PG `money`.
- **Accrual** is the book of record; **cash basis** is a derived report (ADR-0022).
- **Open-item AR/AP** drives aging + cash-basis conversion (ADR-0023).
- **Accrual at sale** (ADR-0028): consignor/vendor liability is recognized the instant goods
  sell, which is what makes the **realtime vendor portal** possible.
- **Tenders** (ADR-0029): split tenders are first-class; card receipts hit a **clearing**
  account until the processor settles; merchant fees are **expensed**, never netted.
- **Account determination** via `posting_map` — domain code never hard-codes account codes.
- **RLS** defense-in-depth; disabled on hot journal tables (ADR-0007).

---

## GitHub

**Repo:** <https://github.com/Ninja-Emp/ninja-emp> — **public**, default branch `main`.

```bash
bash scripts/push.sh "feat: what you changed"   # commit + push in one step
```
