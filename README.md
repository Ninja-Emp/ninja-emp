# Ninja EMP — Enterprise Mall Platform

A greenfield **vendor mall + consignment store SaaS** with world-class double-entry accounting.
**DB-first**: the PostgreSQL schema is the contract; application code follows.

> **Status:** **Database complete.** Parts 0–5 plus the full Tier 1/2/3 backlog — financial
> statements, period/year-end close, AR write-off, inventory with weighted-average cost, stored
> value, vendor draw, 1099-NEC, percentage-rent/CAM true-up, markdown engine, layaway, and
> percentage-commission true-up — all built and proven on live PostgreSQL 18.6.
> **241 assertions across 11 suites, all green**, from a clean provision → migrate → test run.
> The settlement layer is hardened (ADR-0039): reversal un-applies settlement, one allocator,
> no silent cash, hash-chained journal. Application layer (Part 6) is the next build.

---

## Where things live (durability model)

| Environment | Role | Durable? |
|-------------|------|----------|
| **GitHub repo** | **Source of truth** — all code, schema, docs, backups | ✅ Permanent |
| **Your local dev** | Fast day-to-day work (Navicat + PostgreSQL 18) | ✅ Your machine |
| **Sandbox (this agent)** | Throwaway build/CI environment | ❌ Ephemeral |

**The sandbox is not a durable store.** Everything is committed to git and pushed to GitHub;
DB backups are written into `backups/` and bundled into `dist/*.zip` for download.

---

## Repository layout

```
db/                 PostgreSQL schema (DB-first). Numbered, idempotent, re-runnable.
  provision.sh      One-shot: creates both DBs, roles, kernel, tenant schema, seeds.
  migrations/       Versioned, resumable, idempotent migrations (0001…0007).
  tests/            Assertion suites (11 suites, 241 assertions).
  scrub.sql         PII scrubbing for prod→dev sync.
docs/               SRS, DECISIONS (ADRs), DATA_STANDARDS, ERD, DBAL, LOCAL_DEV, ROADMAP, DB_AUDIT.
scripts/            run_tests.sh, migrate.sh, backup.sh, restore.sh, backup_tenant.sh,
                    restore_tenant.sh, sync_to_dev.sh, zip_backup.sh, push.sh
backups/            Timestamped DB dumps (schema + data + custom). LATEST symlink.
dist/               Downloadable zip bundles (git-ignored).
HANDOFF.md          Original project context + working agreements.
```

## Quick start (sandbox or local)

```bash
# 1) Provision both databases from scratch (idempotent)
bash db/provision.sh tenant_demo

# 2) Prove the invariants
sudo -u postgres psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/invariants.sql
sudo -u postgres psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/vendormall.sql
sudo -u postgres psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/partition.sql
sudo -u postgres psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/consignment.sql
sudo -u postgres psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/pos.sql

# 3) Back up (schema + data) into backups/<timestamp>/
bash scripts/backup.sh

# 4) Restore from the latest backup (destructive)
bash scripts/restore.sh

# 5) Bundle a downloadable zip
bash scripts/zip_backup.sh
```

## Test results (all green, re-runnable)

Run everything with one command:

```bash
bash scripts/run_tests.sh          # all suites
bash scripts/run_tests.sh close    # just one suite
```

| Suite | Assertions | Result |
|-------|-----------|--------|
| `invariants.sql` | 28 | **28/28 PASS** |
| `consignment.sql` | 12 | **12/12 PASS** |
| `vendormall.sql` | 20 | **20/20 PASS** |
| `pos.sql` | 27 | **27/27 PASS** |
| `partition.sql` | 6 | **6/6 PASS** |
| `close.sql` | 23 | **23/23 PASS** |
| `inventory.sql` | 30 | **30/30 PASS** |
| `tax1099.sql` | 19 | **19/19 PASS** |
| `lease.sql` | 20 | **20/20 PASS** |
| `retail.sql` | 37 | **37/37 PASS** |
| `settlement.sql` | 19 | **19/19 PASS** |
| **Total** | **241** | **GREEN** |

The suites are **delta-based and re-runnable** — they assert on the change they
cause, not on absolute totals, so they can be run repeatedly without
reprovisioning. Verified from a clean `db/provision.sh` → `scripts/migrate.sh` →
`scripts/run_tests.sh`, and after a full backup→restore round-trip.

## GitHub

**Repo:** https://github.com/Ninja-Emp/ninja-emp — **public**, default branch `main`.

Day-to-day sync (commits + pushes in one step):

```bash
bash scripts/push.sh "feat: what you changed"
```

### Cloning to your local machine

```bash
git clone https://github.com/Ninja-Emp/ninja-emp.git
cd ninja-emp
```

If prompted for credentials, use a **Personal Access Token** as the password (GitHub no longer
accepts account passwords over HTTPS), or install the GitHub CLI and run `gh auth login`.

## Documentation map

- `docs/SRS.md` — Software Requirements Spec (Parts 1–8; Parts 1–5 built).
- `docs/DECISIONS.md` — Architecture Decision Records (ADR-0001 … ADR-0038).
- `docs/DATA_STANDARDS.md` — Normative enterprise data standards (ADR-0015).
- `docs/ERD.md` / `docs/erd.png` — Entity-relationship diagram.
- `docs/DBAL.md` — Database abstraction layer design.
- `docs/LOCAL_DEV.md` — Set up PostgreSQL 18 alongside Laragon + Navicat.
- `docs/DB_AUDIT.md` — Verified inventory of database work (now complete).
- `docs/ROADMAP.md` — What's next (Part 6 onward).

## Key decisions (see DECISIONS.md for the full set)

- **PostgreSQL 18**, schema-per-tenant SaaS, shared `kernel` schema, separate control-plane DB.
- **Party Model** (Silverston) for all actors.
- **Double-entry ledger**: append-only, DB-enforced balance, reversal-not-edit, idempotent posting,
  period locking, subledgers tied to GL control accounts.
- **Money** = `NUMERIC(19,4)` + `CHAR(3)` currency; never float, never PG `money`.
- **Accrual** is the book of record; **cash basis** is a derived report (ADR-0022).
- **Open-item AR/AP** drives aging + cash-basis conversion (ADR-0023).
- **Accrual at sale** (ADR-0028): consignor/vendor liability is recognized the instant goods sell,
  which is what makes the **realtime vendor portal** possible — it reads the live ledger, so it
  cannot drift from the books.
- **Tenders** (ADR-0029): split tenders are first-class; card receipts hit a **clearing** account
  (not cash) until the processor settles; merchant fees are **expensed**, never netted into revenue;
  drawer differences go to **cash over/short**.
- **Account determination** via `posting_map` — domain code never hard-codes account codes (ADR-0020).
- **RLS** defense-in-depth; disabled on hot journal tables (measured ~3× cost, ADR-0007).
