#!/usr/bin/env bash
# ============================================================================
# Ninja EMP — backup.sh
# Dumps BOTH databases (control plane + tenant plane) in three forms each:
#   - schema-only  (DDL, human-readable .sql)
#   - data-only    (rows, human-readable .sql)
#   - full custom  (pg_dump -Fc, restorable binary .dump)
# into backups/<UTC-timestamp>/ and refreshes backups/LATEST.
#
# Usage: bash scripts/backup.sh [label]
#   label (optional) is appended to the folder name, e.g. "pre-part5".
# ============================================================================
set -euo pipefail

CONTROL_DB="${CONTROL_DB:-ninja_control}"
TENANT_DB="${TENANT_DB:-ninja_emp}"
LABEL="${1:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DIRNAME="$STAMP${LABEL:+-$LABEL}"
OUT="$HERE/backups/$DIRNAME"

mkdir -p "$OUT"

# Run pg_dump as the postgres superuser (peer auth over the local socket).
PGDUMP="sudo -u postgres pg_dump"

echo ">> backup -> backups/$DIRNAME"

for DB in "$CONTROL_DB" "$TENANT_DB"; do
  echo "   - $DB: schema-only"
  # Keep privileges (GRANTs) so RLS/role access survives a restore; drop only ownership.
  $PGDUMP --schema-only --no-owner "$DB" > "$OUT/${DB}.schema.sql"
  echo "   - $DB: data-only"
  $PGDUMP --data-only --no-owner --no-privileges --column-inserts "$DB" > "$OUT/${DB}.data.sql"
  echo "   - $DB: full custom"
  $PGDUMP --format=custom --no-owner --no-privileges "$DB" > "$OUT/${DB}.dump"
done

# Metadata for provenance.
{
  echo "backup_utc=$STAMP"
  echo "label=$LABEL"
  echo "control_db=$CONTROL_DB"
  echo "tenant_db=$TENANT_DB"
  echo "pg_dump=$(sudo -u postgres pg_dump --version)"
  echo "host=$(hostname)"
} > "$OUT/MANIFEST.txt"

# Refresh LATEST pointer (relative symlink so it survives moves).
ln -sfn "$DIRNAME" "$HERE/backups/LATEST"

echo ">> done. files:"
ls -la "$OUT"
