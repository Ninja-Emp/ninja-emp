#!/usr/bin/env bash
# =============================================================================
# restore_tenant.sh — restore ONE tenant from a backup_tenant.sh snapshot.
#
#   ./scripts/restore_tenant.sh backups/tenants/tenant_demo/20260101T000000Z
#   ./scripts/restore_tenant.sh <dir> --into tenant_restore_test
#
# --into restores into a DIFFERENT schema name, which is how you verify a backup
# without touching the live tenant. Restoring to a scratch schema and running the
# invariants against it is the only way to know a backup is actually good.
#
# The restore is DESTRUCTIVE to the target schema: it is dropped and recreated.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${NINJA_DB:-ninja_emp}"
PSQL="${PSQL:-psql}"

if [ -n "${PGUSER:-}" ] || [ "${NINJA_NO_SUDO:-0}" = "1" ]; then
  SUDO=()
else
  SUDO=(sudo -u postgres)
fi

SRC=""
INTO=""
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --into) INTO="${2:-}"; shift ;;
    --yes)  YES=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)  SRC="$1" ;;
  esac
  shift
done

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "Usage: $0 <backup-dir> [--into <schema>]" >&2
  exit 2
fi

# Resolve symlinks (backup_tenant.sh leaves a LATEST symlink per tenant).
# find(1) will not descend into a symlinked directory given as its start point.
SRC=$(cd "$SRC" && pwd -P)

SCHEMA_SQL=$(find "$SRC" -maxdepth 1 -name '*.schema.sql' | head -1)
DATA_SQL=$(find "$SRC" -maxdepth 1 -name '*.data.sql' | head -1)

if [ -z "$SCHEMA_SQL" ] || [ -z "$DATA_SQL" ]; then
  echo "!! $SRC does not look like a tenant backup (missing .schema.sql/.data.sql)" >&2
  exit 1
fi

ORIG=$(basename "$SCHEMA_SQL" .schema.sql)
TARGET="${INTO:-$ORIG}"

echo ">> source schema : $ORIG"
echo ">> target schema : $TARGET"
echo ">> database      : $DB"

if [ "$YES" = "0" ]; then
  echo
  echo "!! This DROPS schema '$TARGET' in database '$DB' and rebuilds it."
  read -r -p "   Type the target schema name to confirm: " CONFIRM
  if [ "$CONFIRM" != "$TARGET" ]; then
    echo "   Aborted."
    exit 1
  fi
fi

q() { "${SUDO[@]}" $PSQL -d "$DB" -tAqc "$1"; }

echo ">> dropping and recreating $TARGET"
q "DROP SCHEMA IF EXISTS $TARGET CASCADE;" >/dev/null

# Restoring under a different name: rewrite the schema reference in the dumps.
# sed on the dump is safe here because pg_dump fully qualifies identifiers.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# psql runs as the postgres user via sudo, so it must be able to read these.
# mktemp -d is 0700 by default, which locks postgres out.
chmod 755 "$TMP"

if [ "$TARGET" != "$ORIG" ]; then
  sed "s/\\b$ORIG\\./$TARGET./g; s/SCHEMA $ORIG\\b/SCHEMA $TARGET/g; s/^CREATE SCHEMA $ORIG;/CREATE SCHEMA $TARGET;/" \
      "$SCHEMA_SQL" > "$TMP/schema.sql"
  sed "s/\\b$ORIG\\./$TARGET./g" "$DATA_SQL" > "$TMP/data.sql"
else
  cp "$SCHEMA_SQL" "$TMP/schema.sql"
  cp "$DATA_SQL"   "$TMP/data.sql"
fi

echo ">> loading schema (with grants)"
"${SUDO[@]}" $PSQL -d "$DB" -v ON_ERROR_STOP=1 -q -f "$TMP/schema.sql" >/dev/null

# --disable-triggers equivalent: the ledger has circular FKs (account.parent_id,
# journal_entry.reversal_of_id) and deferred assertion triggers that would fire
# mid-load on data that is only consistent once fully restored.
echo ">> loading data (triggers disabled during load)"
"${SUDO[@]}" $PSQL -d "$DB" -v ON_ERROR_STOP=1 -q \
  -c "SET session_replication_role = replica;" \
  -f "$TMP/data.sql" \
  -c "SET session_replication_role = origin;" >/dev/null

# ---- Verify the restore ------------------------------------------------------
# A restore that loads without error is not a restore that is CORRECT. Check the
# accounting invariants, not just that psql exited 0.
echo ">> verifying"
RC=0

TABLES=$(q "SELECT count(*) FROM information_schema.tables
             WHERE table_schema='$TARGET' AND table_type='BASE TABLE'")
POLICIES=$(q "SELECT count(*) FROM pg_policies WHERE schemaname='$TARGET'")
TB=$(q "SET search_path=$TARGET,kernel; SELECT COALESCE(sum(balance),0) FROM $TARGET.trial_balance(current_date)" 2>/dev/null || echo "n/a")

echo "   base tables   : $TABLES"
echo "   RLS policies  : $POLICIES"
echo "   trial balance : $TB"

if [ "$TB" = "n/a" ]; then
  echo "!! could not compute trial balance in $TARGET" >&2; RC=1
elif [ "$(q "SELECT ($TB)::numeric <> 0")" = "t" ]; then
  echo "!! RESTORE VERIFICATION FAILED: trial balance is $TB, expected 0." >&2; RC=1
fi

# RLS without policies is an open door. If the source had policies and the
# restore has none, the grants came back but the isolation did not.
if [ "$POLICIES" = "0" ]; then
  echo "!! RESTORE VERIFICATION FAILED: no RLS policies in $TARGET." >&2; RC=1
fi

# Every subledger must still tie to its GL control account.
BAD=$(q "SET search_path=$TARGET,kernel;
         SELECT COALESCE(string_agg(subledger_type_code || '=' || difference, ', '), '')
           FROM $TARGET.subledger_control_check() WHERE difference <> 0" 2>/dev/null || echo "n/a")
if [ "$BAD" = "n/a" ]; then
  echo "   subledgers    : (check unavailable)"
elif [ -n "$BAD" ]; then
  echo "!! RESTORE VERIFICATION FAILED: subledger(s) out of balance: $BAD" >&2; RC=1
else
  echo "   subledgers    : all tie to control accounts"
fi

# Row-count parity against the source schema, when it is still present. This is
# what catches a data file that loaded "successfully" but partially.
if [ "$TARGET" != "$ORIG" ] && [ "$(q "SELECT count(*) FROM pg_namespace WHERE nspname='$ORIG'")" = "1" ]; then
  for t in journal_entry journal_line party account open_item; do
    A=$(q "SELECT count(*) FROM $ORIG.$t" 2>/dev/null || echo x)
    B=$(q "SELECT count(*) FROM $TARGET.$t" 2>/dev/null || echo y)
    if [ "$A" != "$B" ]; then
      echo "!! ROW COUNT MISMATCH on $t: source=$A restored=$B" >&2; RC=1
    fi
  done
  [ "$RC" = "0" ] && echo "   row counts    : match source $ORIG"
fi

if [ "$RC" != "0" ]; then
  echo ">> RESTORE FAILED VERIFICATION. Do not trust this backup." >&2
  exit 1
fi

echo ">> restore complete and verified."
