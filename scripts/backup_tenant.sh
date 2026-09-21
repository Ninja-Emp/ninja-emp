#!/usr/bin/env bash
# =============================================================================
# backup_tenant.sh — back up ONE tenant, for production go-live and beyond.
#
# scripts/backup.sh dumps whole databases, which is right for dev. In production
# you need to snapshot a SINGLE tenant: before a risky migration, at go-live, or
# on a schedule per customer. Schema-per-tenant makes that clean — one schema,
# one dump.
#
#   ./scripts/backup_tenant.sh tenant_demo
#   ./scripts/backup_tenant.sh tenant_demo --label pre-golive
#   ./scripts/backup_tenant.sh --all --label nightly
#   ./scripts/backup_tenant.sh tenant_demo --out /mnt/backups
#
# Produces, per tenant, in backups/tenants/<tenant>/<UTC-timestamp>[-label]/ :
#   <tenant>.schema.sql   schema only, WITH grants (RLS depends on them)
#   <tenant>.data.sql     data only, portable column-inserts
#   <tenant>.dump         custom format, for fast pg_restore
#   MANIFEST.txt          what/when/counts + verification of the dump
#
# Every backup is VERIFIED after it is written. An unverified backup is a guess.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${NINJA_DB:-ninja_emp}"
PGDUMP="${PGDUMP:-pg_dump}"
PSQL="${PSQL:-psql}"
OUTROOT="$HERE/backups/tenants"

if [ -n "${PGUSER:-}" ] || [ "${NINJA_NO_SUDO:-0}" = "1" ]; then
  SUDO=()
else
  SUDO=(sudo -u postgres)
fi

LABEL=""
ALL=0
TENANT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all)    ALL=1 ;;
    --label)  LABEL="${2:-}"; shift ;;
    --out)    OUTROOT="${2:-}"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)  TENANT="$1" ;;
  esac
  shift
done

q() { "${SUDO[@]}" $PSQL -d "$DB" -tAqc "$1"; }

if [ "$ALL" = "1" ]; then
  TENANTS=$(q "SELECT nspname FROM pg_namespace WHERE nspname LIKE 'tenant_%' ORDER BY nspname")
elif [ -n "$TENANT" ]; then
  TENANTS="$TENANT"
else
  echo "Usage: $0 <tenant_schema> [--label X] | --all" >&2
  exit 2
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
OVERALL_RC=0

for T in $TENANTS; do
  if [ "$(q "SELECT count(*) FROM pg_namespace WHERE nspname='$T'")" != "1" ]; then
    echo "!! No such schema: $T" >&2
    OVERALL_RC=1
    continue
  fi

  DIR="$OUTROOT/$T/${TS}${LABEL:+-$LABEL}"
  mkdir -p "$DIR"
  echo ">> backing up $T -> $DIR"

  # Schema WITH privileges: RLS policies are worthless if the GRANTs do not come
  # back with them. Learned the hard way — do not add --no-privileges here.
  "${SUDO[@]}" $PGDUMP --schema="$T" --schema-only --no-owner "$DB" > "$DIR/$T.schema.sql"

  "${SUDO[@]}" $PGDUMP --schema="$T" --data-only --no-owner --no-privileges \
      --column-inserts "$DB" > "$DIR/$T.data.sql"

  "${SUDO[@]}" $PGDUMP --schema="$T" --format=custom --no-owner --no-privileges \
      "$DB" > "$DIR/$T.dump"

  # ---- Counts, straight from the live schema --------------------------------
  TABLES=$(q "SELECT count(*) FROM information_schema.tables
               WHERE table_schema='$T' AND table_type='BASE TABLE'")
  JE=$(q "SELECT count(*) FROM $T.journal_entry" 2>/dev/null || echo "n/a")
  JL=$(q "SELECT count(*) FROM $T.journal_line"  2>/dev/null || echo "n/a")
  TB=$(q "SET search_path=$T,kernel; SELECT COALESCE(sum(balance),0) FROM $T.trial_balance(current_date)" 2>/dev/null || echo "n/a")

  # ---- Verify the dump is readable ------------------------------------------
  # A backup nobody has read is a guess. pg_restore --list fails loudly on a
  # truncated or corrupt custom-format dump.
  VERIFY="ok"
  if ! "${SUDO[@]}" pg_restore --list "$DIR/$T.dump" >/dev/null 2>&1; then
    VERIFY="FAILED — custom dump is not readable"
    OVERALL_RC=1
  fi
  if [ ! -s "$DIR/$T.schema.sql" ]; then
    VERIFY="FAILED — schema dump is empty"
    OVERALL_RC=1
  fi

  cat > "$DIR/MANIFEST.txt" <<EOF
Ninja EMP — per-tenant backup
=============================
tenant schema : $T
database      : $DB
taken (UTC)   : $TS
label         : ${LABEL:-none}
host          : $(hostname)
pg_dump       : $("${SUDO[@]}" $PGDUMP --version | head -1)

Contents
--------
$T.schema.sql   schema only, WITH grants (RLS depends on them)
$T.data.sql     data only, column-inserts (portable across PG versions)
$T.dump         custom format, restore with pg_restore

State at backup time
--------------------
base tables    : $TABLES
journal entries: $JE
journal lines  : $JL
trial balance  : $TB   (must be 0)

Verification   : $VERIFY

Restore
-------
  ./scripts/restore_tenant.sh $DIR --into $T
EOF

  echo "   tables=$TABLES entries=$JE lines=$JL trial_balance=$TB verify=$VERIFY"

  if [ "$TB" != "n/a" ] && [ "$TB" != "0" ] && [ "$TB" != "0.0000" ]; then
    echo "   !! WARNING: trial balance is $TB, expected 0. Backing up an unbalanced book."
  fi

  # Convenience pointer to this tenant's most recent backup. Must live beside
  # the timestamped directories it points at, or it dangles.
  if [ "$VERIFY" = "ok" ]; then
    ln -sfn "${TS}${LABEL:+-$LABEL}" "$OUTROOT/$T/LATEST" 2>/dev/null || true
  fi
done

echo ">> done."
exit $OVERALL_RC
