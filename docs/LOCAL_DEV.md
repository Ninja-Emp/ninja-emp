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

---

# Developing against real production data

Inventing seed data hides the bugs that only real data produces: the vendor with four thousand
items, the lease with the odd proration, the refund that straddles a period boundary. The point
of this workflow is that your Laragon instance runs on the same shapes production runs on.

Two scripts cover it. `scripts/backup_tenant.sh` snapshots one tenant on the server, and
`scripts/sync_to_dev.sh` produces a loadable, **de-identified** copy for your laptop.

## Step 1 — snapshot the tenant on the server (go-live and beyond)

Run this on the production host before anything risky, and on a schedule afterwards. It is
per-tenant, because schema-per-tenant means one customer is one schema and there is no reason to
move the whole cluster to protect one of them.

```bash
bash scripts/backup_tenant.sh tenant_acme --label pre-golive
bash scripts/backup_tenant.sh --all --label nightly
```

Each run writes `backups/tenants/<tenant>/<UTC-timestamp>[-label]/` containing a schema-only dump
**with grants** (RLS policies are worthless if the GRANTs do not come back with them), a portable
data-only dump, a custom-format dump for fast `pg_restore`, and a `MANIFEST.txt` recording row
counts and the trial balance at the moment of capture. A `LATEST` symlink points at the newest run.

Every backup is verified as it is written. An unverified backup is a guess.

### Prove the backup is restorable

A backup you have never restored is a hypothesis. Restore it into a scratch schema, which leaves
the live tenant untouched:

```bash
bash scripts/restore_tenant.sh backups/tenants/tenant_acme/LATEST --into tenant_restore_test
```

The restore fails loudly and exits non-zero unless the trial balance is zero, every subledger ties
to its GL control account, the RLS policies came back, and the row counts match the source. Wire
it into cron and let it page you when a backup stops being restorable.

## Step 2 — build a dev dataset

Run on the production host:

```bash
bash scripts/sync_to_dev.sh tenant_acme
```

This writes `dist/ninja-emp-devdata-tenant_acme-<timestamp>.zip`.

**It is scrubbed by default, and production is never modified.** The script restores into a
throwaway staging database, scrubs that, dumps it, and drops it. Your live data is only ever read.

What is replaced: person names and dates of birth, party display names, organisation legal and
trading names, contact details, street addresses, tax identifiers (**both** the ciphertext and the
unsalted SHA-256 hash — a hashed SSN is a nine-digit keyspace and falls to brute force in seconds),
card last-4 and processor references, journal memos, and the `audit_log` before/after row
snapshots, which otherwise preserve a verbatim copy of every value the scrub just removed.

What is kept: every id, foreign key and relationship, every monetary amount, every date, the whole
chart of accounts, and all row counts. Amounts are deliberately untouched — they are what make the
copy useful for debugging, and they are not what identifies anyone. The scrub verifies the books
still balance before the export is allowed out.

The export is then **leak-tested**: the shipped dump is loaded into a scratch database and its
PII-bearing columns are compared against production row by row. If any value survives, the zip is
deleted and the script exits non-zero. Nothing ships on the strength of the script believing it
succeeded.

### If you genuinely need unscrubbed data

```bash
bash scripts/sync_to_dev.sh tenant_acme --raw
```

You must type `EXPORT RAW PII` at the prompt. Once real personal data is on a laptop it is outside
your production controls, it is in your laptop backups, and it is in scope for breach notification.
The scrubbed copy has the same row counts, the same amounts and the same edge cases; reach for
`--raw` only when you have a specific reason that the scrubbed copy cannot serve.

## Step 3 — load it into Laragon

Copy the zip to your machine, unzip it, and run the loader inside it. **PowerShell:**

```powershell
cd ninja-emp-devdata-tenant_acme-20260101T000000Z
.\load_dev_data.ps1                  # creates/loads database "ninja_emp"
.\load_dev_data.ps1 ninja_dev        # or a database name of your choosing
```

**Git Bash / WSL:**

```bash
./load_dev_data.sh
```

The loader drops and recreates the target database, creates `pgcrypto` and `btree_gist`
**in the `kernel` schema** (they must not go in `public`; the dump calls
`kernel.pgp_sym_decrypt(...)` and the load fails with a confusing
`function kernel.pgp_sym_decrypt(bytea, text) does not exist` if they are anywhere else), loads the
data, and prints the trial balance. **The trial balance must be `0.0000`.** If it is not, the
dataset did not load cleanly — do not develop against it.

Then point Navicat at the database you just created. Same connection settings as above, only the
database name changes.

## A reasonable rhythm

Refresh dev data weekly, or whenever you are about to work on something where data shape matters —
a reporting change, a migration, a performance problem. Refreshing is cheap and destructive only to
your local copy.

```bash
# on the server
bash scripts/backup_tenant.sh --all --label nightly    # cron
bash scripts/sync_to_dev.sh tenant_acme                # when you want fresh dev data

# on your machine
.\load_dev_data.ps1
```

## Running migrations locally

Once the dev data is loaded, apply pending migrations against it exactly as production will:

```bash
bash scripts/migrate.sh --status      # what would run
bash scripts/migrate.sh --dry-run     # parse and roll back
bash scripts/migrate.sh               # apply
```

Each migration runs in a single transaction, and its checksum is recorded. If a migration file is
edited after it has been applied, the runner refuses to continue rather than silently diverging
your environments.
