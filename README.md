# Ninja EMP — Enterprise Mall Platform

A greenfield **vendor mall + consignment store SaaS** with world-class double-entry accounting.
**DB-first**: the PostgreSQL schema is the contract; application code follows.

> **Status:** DB foundation complete through **Part 5 (POS & Payments)**, including a **realtime
> vendor portal**. All invariants proven on live PostgreSQL 18.6. Application layer (Part 6) not yet built.

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
  tests/            Assertion suites (invariants, vendormall, partition, consignment).
docs/               SRS, DECISIONS (ADRs), DATA_STANDARDS, ERD, DBAL, LOCAL_DEV, ROADMAP.
scripts/            backup.sh, restore.sh, zip_backup.sh, push.sh
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

| Suite | Assertions | Result |
|-------|-----------|--------|
| `invariants.sql` | 19 | **19/19 PASS** |
| `vendormall.sql` | 20 | **20/20 PASS** |
| `partition.sql` | 5 | **5/5 PASS** |
| `consignment.sql` | 12 | **12/12 PASS** |
| `pos.sql` | 27 | **27/27 PASS** |

Verified **after a full backup→restore round-trip** — the dumps are genuinely restorable.

## GitHub

**Repo:** https://github.com/Ninja-Emp/ninja-emp — **private**, default branch `main`.

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

- `docs/SRS.md` — Software Requirements Spec (Parts 1–8; Parts 1–4 built).
- `docs/DECISIONS.md` — Architecture Decision Records (ADR-0001 … ADR-0027).
- `docs/DATA_STANDARDS.md` — Normative enterprise data standards (ADR-0015).
- `docs/ERD.md` / `docs/erd.png` — Entity-relationship diagram.
- `docs/DBAL.md` — Database abstraction layer design.
- `docs/LOCAL_DEV.md` — Set up PostgreSQL 18 alongside Laragon + Navicat.
- `docs/ROADMAP.md` — What's next (Part 5 onward).

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
