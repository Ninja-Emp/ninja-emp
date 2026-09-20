# Local Development Setup (Windows + Laragon + PostgreSQL 18 + Navicat)

## Why local is faster

The sandbox is a throwaway build/CI environment reached over the network. Your local machine
has local disk I/O and no network hop, so Navicat queries, migrations, and test runs feel
instant. **Do day-to-day development locally; use the sandbox for automated builds and CI.**

## Important: Laragon ships MySQL, not PostgreSQL

Laragon's default stack is **MySQL/MariaDB**. This project requires **PostgreSQL 18** because it
uses PG-18-only features:

- native `uuidv7()` (no extension needed)
- deferred constraint triggers (DB-enforced journal balance)
- `btree_gist` exclusion constraints (effective-dated non-overlap)
- `FORCE ROW LEVEL SECURITY`

So you must **add PostgreSQL 18 to Laragon** (or run it side-by-side). Two options below.

---

## Option A — Add PostgreSQL 18 to Laragon (recommended)

1. **Download the PostgreSQL 18 Windows installer** (EDB):
   https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
   Choose **PostgreSQL 18.x** → Windows x86-64.

2. **Install to a Laragon-friendly path**, e.g. `C:\laragon\bin\postgresql\pgsql-18`.
   During install set:
   - Port: **5432** (or 5433 if MySQL/another PG already uses 5432)
   - Superuser: `postgres`
   - Password: choose one and remember it (used by Navicat)
   - Locale: default

3. **Register it with Laragon** (optional but nice):
   Laragon → Menu → Preferences → Services & Ports, or simply add the `bin` folder to PATH:
   `C:\laragon\bin\postgresql\pgsql-18\bin`.

4. **Verify** in a terminal:
   ```powershell
   psql --version        # expect: psql (PostgreSQL) 18.x
   ```

## Option B — Standalone PostgreSQL 18 (simplest)

Install PostgreSQL 18 normally (default `C:\Program Files\PostgreSQL\18`). It runs as a Windows
service on port 5432. Laragon and PostgreSQL coexist fine — they use different ports.

---

## Create the databases and roles

The schema is provisioned by `db/provision.sh`, which expects a Unix-like shell. On Windows use
**Git Bash** (ships with Git for Windows) or **WSL**. From the repo root in Git Bash:

```bash
# Set the superuser password so psql can connect over TCP (or use PGPASSWORD).
export PGPASSWORD='your-postgres-password'

# provision.sh uses `sudo -u postgres` (Linux peer auth). On Windows, run the SQL directly
# as the postgres superuser instead. Easiest: create a small wrapper or run:
psql -U postgres -h localhost -p 5432 -c "CREATE DATABASE ninja_control;"
psql -U postgres -h localhost -p 5432 -c "CREATE DATABASE ninja_emp;"
```

> **Note:** `db/provision.sh` is written for the Linux sandbox (`sudo -u postgres`, peer auth).
> On Windows, either (a) run it under **WSL** where `sudo -u postgres` works, or (b) run the
> numbered SQL files manually with `psql -U postgres -h localhost`. A Windows-native
> `provision.ps1` can be added on request.

### Manual provisioning order (Windows, if not using WSL)

```bash
PSQL="psql -U postgres -h localhost -p 5432 -v ON_ERROR_STOP=1"

# roles (cluster-level)
$PSQL -d postgres -f db/99_roles.sql

# control plane
$PSQL -d ninja_control -f db/00_bootstrap.sql

# tenant plane: kernel
$PSQL -d ninja_emp -f db/00_kernel.sql

# tenant schema + core DDL
$PSQL -d ninja_emp -c "CREATE SCHEMA tenant_demo;"
for f in 05_audit 10_party 20_money 30_ledger; do
  $PSQL -d ninja_emp -c "SET search_path = tenant_demo, kernel;" -f db/$f.sql
done

# seeds
for f in 35_coa_seed 37_coa_consignment 36_tenant_seed; do
  $PSQL -d ninja_emp -c "SET search_path = tenant_demo, kernel; SET app.tenant_id='11111111-1111-7111-8111-111111111111';" -f db/$f.sql
done

# domain + posting + RLS
for f in 40_subledger 45_openitem 50_vendormall 55_vendormall_posting 60_consignment 65_consignment_posting 90_rls; do
  $PSQL -d ninja_emp -c "SET search_path = tenant_demo, kernel;" -f db/$f.sql
done
```

---

## Connect Navicat

Create a **PostgreSQL** connection (not MySQL):

| Field | Value |
|-------|-------|
| Host | `localhost` |
| Port | `5432` (or your chosen port) |
| Initial Database | `ninja_emp` |
| User | `postgres` |
| Password | your postgres password |

You will see two databases: **`ninja_emp`** (kernel + `tenant_demo` schema) and
**`ninja_control`** (control plane). Set the schema filter to `tenant_demo` and `kernel` to
focus on the app tables.

> **Tip:** To browse as the app role, create a second Navicat connection with user `ninja_app`.
> RLS will apply, so you must `SET app.tenant_id = '11111111-1111-7111-8111-111111111111';`
> in a query window before selecting rows.

---

## Backups on your machine

The same scripts work locally (Git Bash / WSL):

```bash
bash scripts/backup.sh            # writes backups/<timestamp>/
bash scripts/restore.sh           # restores backups/LATEST (destructive)
bash scripts/zip_backup.sh        # writes dist/ninja-emp-backup-<ts>.zip
```

On Windows-native psql, replace `sudo -u postgres pg_dump` with
`pg_dump -U postgres -h localhost` in the scripts (or set `PGHOST`/`PGUSER`/`PGPASSWORD`).

---

## Keeping local and GitHub in sync

```bash
git pull            # get latest from GitHub
# ... work ...
bash scripts/push.sh "feat: ..."   # commit + push
```

The GitHub repo is the source of truth. The sandbox can be destroyed at any time without loss
because everything lives in git.
