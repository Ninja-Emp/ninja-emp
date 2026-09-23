# Ninja EMP — Enterprise Mall Platform

A greenfield **vendor mall + consignment store SaaS** with world-class double-entry
accounting. **DB-first**: the PostgreSQL schema is the contract; application code follows it.

> **Status:** The database is **complete** (Parts 0–5 plus the full Tier 1/2/3 backlog) and
> proven on live PostgreSQL 18.6 — **241 assertions across 11 SQL suites, all green**. The PHP
> application layer (Part 6) is underway: DBAL, ledger engine, auth/tenancy, routing/middleware,
> the API-first OpenAPI 3.1 surface, and the server-rendered Tenant UI are built. The quality
> gate (PHPStan L10, PHPMD, Deptrac, PHPUnit, Infection) is in place.

---

## Quick start (five minutes)

**Requirements:** PHP **8.5** (with `bcmath`, `mbstring`, `pdo_pgsql`), **Composer**, and
**Docker** (for PostgreSQL 18). On Windows, Laragon works too — see `docs/LOCAL_DEV.md`.

```bash
git clone https://github.com/Ninja-Emp/ninja-emp.git
cd ninja-emp

cp .env.example .env      # configuration; the defaults match the Docker database
make install              # composer install (dev tooling)
make up                   # start PostgreSQL 18 in Docker
make provision            # create both databases + tenant schema + seeds
make serve                # run the API + Tenant UI
```

Then open:

- **Tenant UI** — <http://127.0.0.1:8091> — the mall operator's back office
- **API** — <http://127.0.0.1:8092/api/health> — docs at `/api/docs`, contract at `/api/openapi.json`

Run `make` on its own to list every target.

### Without Docker

Point `.env` at any PostgreSQL 18 instance and run `make provision` / `make serve`. The
provisioning scripts honour a `PSQL` override, e.g.
`PSQL="psql -h 127.0.0.1 -U postgres" bash db/provision.sh`.

---

## Repository layout

```
src/                     the library (NinjaEMP\*): DBAL, ledger, money, auth, tenancy, HTTP, OpenAPI
app/
  api/                   the API application (NinjaEmp\Api\*) — OpenAPI 3.1 surface
    public/              front controller + dev-server router (the web root)
  tenant-ui/             the Tenant UI application (NinjaEmp\TenantUi\*) — server-rendered templates
    public/              front controller + dev-server router (the web root)
db/                      PostgreSQL schema (DB-first). Numbered, idempotent, re-runnable.
  migrations/            versioned, resumable, checksum-verified migrations (0001…0007)
  tests/                 SQL assertion suites (11 suites, 241 assertions)
bin/                     developer entrypoints (migrate, serve)
scripts/                 backup / restore / sync / migrate helpers
tests/                   PHPUnit suite: Unit (harness bridge) + E2E (real front controllers)
docs/                    SRS, DECISIONS (ADRs), handoffs, ERD, DBAL, LOCAL_DEV, ROADMAP
docker-compose.yml       PostgreSQL 18 for local development
Makefile                 the developer entrypoints
.env.example             configuration template (copy to .env)
```

The application is **zero-dependency PHP** at runtime: no framework, and the only Composer
runtime packages are the PSR interfaces (`psr/log`, `psr/container`, `psr/http-message`,
`psr/http-server-*`). Everything else under `require-dev` is tooling.

---

## Commands

| Command | What it does |
|---------|--------------|
| `make up` / `make down` | Start / stop PostgreSQL 18 (Docker) |
| `make provision` | Create both databases + tenant schema + seeds (destructive) |
| `make migrate` | Apply pending migrations to every tenant schema |
| `make serve` | Run the API + Tenant UI dev servers |
| `make test` | Full PHPUnit suite (unit + end-to-end) |
| `make test-unit` / `make test-e2e` | One suite only |
| `make gate` | The whole quality gate, in CI order |

---

## Testing

The PHP suite runs under **PHPUnit**:

```bash
make test          # unit (harness bridge) + end-to-end
make test-unit     # unit only
make test-e2e      # end-to-end only (boots the real front controllers over HTTP)
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

Run it all locally with `make gate`.

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
