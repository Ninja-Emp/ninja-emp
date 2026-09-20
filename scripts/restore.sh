#!/usr/bin/env bash
# ============================================================================
# Ninja EMP — restore.sh
# Restores BOTH databases from a backup directory produced by backup.sh.
# Drops & recreates each database, loads schema (SQL), then loads data from the
# custom-format dump with --disable-triggers (handles circular FKs correctly).
#
# Usage: bash scripts/restore.sh [backup_dir]
#   backup_dir defaults to backups/LATEST.
#
# WARNING: destructive — the target databases are dropped and recreated.
# ============================================================================
set -euo pipefail

CONTROL_DB="${CONTROL_DB:-ninja_control}"
TENANT_DB="${TENANT_DB:-ninja_emp}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE/backups/LATEST}"

if [[ ! -d "$SRC" ]]; then
  echo "!! backup dir not found: $SRC" >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd)"
echo ">> restore from $SRC"

PSQL="sudo -u postgres psql -v ON_ERROR_STOP=1 -q"
PGRESTORE="sudo -u postgres pg_restore"

for DB in "$CONTROL_DB" "$TENANT_DB"; do
  echo "   - $DB: drop + recreate"
  $PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB;" >/dev/null
  $PSQL -d postgres -c "CREATE DATABASE $DB;" >/dev/null

  echo "   - $DB: schema"
  $PSQL -d "$DB" -f "$SRC/${DB}.schema.sql" >/dev/null

  echo "   - $DB: data (custom dump, triggers disabled)"
  # --data-only: schema already loaded. --disable-triggers: circular FKs.
  # --no-owner/--no-privileges: portable across environments.
  $PGRESTORE --data-only --disable-triggers --no-owner --no-privileges \
    -d "$DB" "$SRC/${DB}.dump" >/dev/null
done

echo ">> restore complete."
