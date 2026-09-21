#!/usr/bin/env bash
# =============================================================================
# migrate.sh — resumable, idempotent, checksum-verified migration runner.
#
# provision.sh builds a database from scratch. This evolves one that already has
# data. Applies every pending migration in db/migrations to every tenant schema,
# recording state in kernel.schema_migration.
#
#   ./scripts/migrate.sh                     apply all pending, all tenants
#   ./scripts/migrate.sh --status            show applied vs pending
#   ./scripts/migrate.sh --dry-run           show what would run
#   ./scripts/migrate.sh --tenant tenant_x   one tenant only
#   ./scripts/migrate.sh --allow-checksum-drift
#
# Safe to re-run. An interrupted run is fixed by running it again.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="$HERE/db/migrations"
DB="${NINJA_DB:-ninja_emp}"
PSQL="${PSQL:-psql}"

# Use sudo -u postgres when we are not already a database superuser role.
if [ -n "${PGUSER:-}" ] || [ "${NINJA_NO_SUDO:-0}" = "1" ]; then
  RUN_PSQL=("$PSQL")
else
  RUN_PSQL=(sudo -u postgres "$PSQL")
fi

DRY_RUN=0
STATUS_ONLY=0
ONE_TENANT=""
ALLOW_DRIFT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)               DRY_RUN=1 ;;
    --status)                STATUS_ONLY=1 ;;
    --tenant)                ONE_TENANT="${2:-}"; shift ;;
    --allow-checksum-drift)  ALLOW_DRIFT=1 ;;
    -h|--help)               sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

q() { "${RUN_PSQL[@]}" -d "$DB" -tAqc "$1"; }

# --- Preconditions -----------------------------------------------------------
if ! q "SELECT 1" >/dev/null 2>&1; then
  echo "!! Cannot connect to database '$DB'." >&2
  exit 1
fi

if [ "$(q "SELECT to_regclass('kernel.schema_migration') IS NOT NULL")" != "t" ]; then
  echo "!! kernel.schema_migration does not exist. Run db/provision.sh first." >&2
  exit 1
fi

# --- Discover tenant schemas -------------------------------------------------
if [ -n "$ONE_TENANT" ]; then
  TENANTS="$ONE_TENANT"
else
  TENANTS=$(q "SELECT nspname FROM pg_namespace
                WHERE nspname LIKE 'tenant_%'
                  AND nspname NOT LIKE 'pg_%'
                ORDER BY nspname")
fi

if [ -z "$TENANTS" ]; then
  echo "!! No tenant schemas found."
  exit 1
fi

MIGRATION_FILES=$(find "$MIGRATIONS" -maxdepth 1 -name '*.sql' | sort)
if [ -z "$MIGRATION_FILES" ]; then
  echo ">> No migration files in $MIGRATIONS"
  exit 0
fi

echo ">> database : $DB"
echo ">> tenants  : $(echo "$TENANTS" | tr '\n' ' ')"
echo ">> migrations directory: $MIGRATIONS"
echo

# --- Status ------------------------------------------------------------------
if [ "$STATUS_ONLY" = "1" ]; then
  for T in $TENANTS; do
    echo "== $T"
    for F in $MIGRATION_FILES; do
      BASE=$(basename "$F")
      VER="${BASE%%_*}"
      APPLIED=$(q "SELECT applied_at FROM kernel.schema_migration
                    WHERE tenant_schema='$T' AND version='$VER'")
      if [ -n "$APPLIED" ]; then
        printf '   [applied] %-40s %s\n' "$BASE" "$APPLIED"
      else
        printf '   [PENDING] %-40s\n' "$BASE"
      fi
    done
    echo
  done
  exit 0
fi

# --- Apply -------------------------------------------------------------------
TOTAL_APPLIED=0

for T in $TENANTS; do
  echo "== tenant schema: $T"

  for F in $MIGRATION_FILES; do
    BASE=$(basename "$F")
    VER="${BASE%%_*}"
    SUM=$(sha256sum "$F" | awk '{print $1}')

    PREV_SUM=$(q "SELECT checksum FROM kernel.schema_migration
                   WHERE tenant_schema='$T' AND version='$VER'")

    if [ -n "$PREV_SUM" ]; then
      # Already applied. Verify it has not been edited since.
      if [ "$PREV_SUM" != "$SUM" ] && [ "$ALLOW_DRIFT" = "0" ]; then
        echo "!! CHECKSUM MISMATCH on $BASE for $T"
        echo "   recorded: $PREV_SUM"
        echo "   on disk : $SUM"
        echo "   A migration that already ran has been edited. Write a NEW migration"
        echo "   instead, or re-run with --allow-checksum-drift if you are certain."
        exit 1
      fi
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      echo "   [would apply] $BASE"
      continue
    fi

    echo "   applying $BASE"
    START=$(date +%s%3N)

    # Each migration runs in ONE transaction: it fully applies or not at all.
    # The schema_migration insert is inside that transaction, so state can never
    # disagree with what actually ran.
    if ! "${RUN_PSQL[@]}" -d "$DB" -v ON_ERROR_STOP=1 --single-transaction \
        -c "SET search_path = $T, kernel;" \
        -f "$F" \
        -c "INSERT INTO kernel.schema_migration (tenant_schema, version, filename, checksum)
            VALUES ('$T','$VER','$BASE','$SUM');" >/dev/null; then
      echo "!! FAILED: $BASE on $T — rolled back. Nothing was applied."
      exit 1
    fi

    END=$(date +%s%3N)
    q "UPDATE kernel.schema_migration SET duration_ms=$((END-START))
        WHERE tenant_schema='$T' AND version='$VER'" >/dev/null
    echo "      ok ($((END-START))ms)"
    TOTAL_APPLIED=$((TOTAL_APPLIED+1))
  done
done

echo
if [ "$DRY_RUN" = "1" ]; then
  echo ">> dry run complete. Nothing was changed."
else
  echo ">> done. $TOTAL_APPLIED migration(s) applied."
fi
