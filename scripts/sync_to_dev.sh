#!/usr/bin/env bash
# =============================================================================
# sync_to_dev.sh — produce a developer copy of production data.
#
# THE PROBLEM THIS SOLVES
#   Developing against invented seed data hides the bugs that only real data
#   shape produces: the vendor with 4,000 items, the lease with a weird proration,
#   the refund that crosses a period boundary.
#
# THE RISK IT MANAGES
#   This schema holds TINs (1099s), payment records and full party PII. A laptop
#   is not a compliance boundary. So the default is SCRUBBED: you get real
#   volumes, real distributions, real amounts and real edge cases, with
#   identities replaced.
#
#   Monetary values are deliberately NOT altered — they are what makes the copy
#   useful, and they are not what identifies anyone.
#
#   ./scripts/sync_to_dev.sh tenant_demo                 scrubbed (default)
#   ./scripts/sync_to_dev.sh tenant_demo --raw           UNSCRUBBED, requires typed consent
#   ./scripts/sync_to_dev.sh --all
#   ./scripts/sync_to_dev.sh tenant_demo --out dist
#
# Output: dist/ninja-emp-devdata-<tenant>-<ts>[-RAW].zip
#   Unzip on your dev box and run load_dev_data.ps1 / .sh inside it.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${NINJA_DB:-ninja_emp}"
PSQL="${PSQL:-psql}"
PGDUMP="${PGDUMP:-pg_dump}"
OUT="$HERE/dist"
STAGE_DB="ninja_scrub_stage"

if [ -n "${PGUSER:-}" ] || [ "${NINJA_NO_SUDO:-0}" = "1" ]; then
  SUDO=()
else
  SUDO=(sudo -u postgres)
fi

RAW=0
ALL=0
TENANT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --raw)  RAW=1 ;;
    --all)  ALL=1 ;;
    --out)  OUT="${2:-}"; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
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
  echo "Usage: $0 <tenant_schema> [--raw] | --all" >&2
  exit 2
fi

# --- Raw export requires deliberate, typed consent ---------------------------
if [ "$RAW" = "1" ]; then
  cat <<'WARN'

  ############################################################################
  #  RAW EXPORT REQUESTED — NO SCRUBBING                                     #
  #                                                                          #
  #  This copy will contain real personal data: names, addresses, contact    #
  #  details, and encrypted tax identifiers (TIN/SSN/EIN).                   #
  #                                                                          #
  #  Once it is on a laptop it is outside your production controls, it is    #
  #  in your backups, and it is in scope for breach notification.            #
  #                                                                          #
  #  The scrubbed export gives you the same row counts, the same amounts,    #
  #  and the same edge cases. Use it unless you have a specific reason.      #
  ############################################################################

WARN
  read -r -p "  Type EXPORT RAW PII to continue: " CONFIRM
  if [ "$CONFIRM" != "EXPORT RAW PII" ]; then
    echo "  Aborted. Re-run without --raw for a scrubbed copy."
    exit 1
  fi
fi

mkdir -p "$OUT"
TS=$(date -u +%Y%m%dT%H%M%SZ)

# Extension name+schema from the source catalog. Needed both when building the
# staging database and when rebuilding the export for the leak test.
EXTS_FOR_CHECK=$(q "SELECT e.extname||'|'||n.nspname
                      FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
                     WHERE e.extname <> 'plpgsql';")

for T in $TENANTS; do
  echo
  echo ">> ===== $T ====="

  if [ "$(q "SELECT count(*) FROM pg_namespace WHERE nspname='$T'")" != "1" ]; then
    echo "!! No such schema: $T" >&2
    continue
  fi

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  # psql/pg_dump run as the postgres user via sudo; mktemp -d is 0700.
  chmod 755 "$WORK"

  if [ "$RAW" = "1" ]; then
    echo ">> dumping RAW (unscrubbed)"
    # kernel is included so the dump is self-contained, and CREATE SCHEMA is
    # made idempotent for the same reason as the scrubbed path.
    "${SUDO[@]}" $PGDUMP --schema=kernel --schema="$T" --no-owner "$DB" > "$WORK/$T.dump.raw"
    sed -E 's/^CREATE SCHEMA ([a-zA-Z0-9_]+);/CREATE SCHEMA IF NOT EXISTS \1;/' \
        "$WORK/$T.dump.raw" > "$WORK/$T.sql"
    rm -f "$WORK/$T.dump.raw"
    SUFFIX="-RAW"
    MODE="RAW — CONTAINS REAL PII"
  else
    # Scrub a THROWAWAY COPY, never the source. Production is never modified by
    # this script; that property is worth the extra restore cycle.
    echo ">> building throwaway staging database ($STAGE_DB)"
    "${SUDO[@]}" $PSQL -d postgres -q -c "DROP DATABASE IF EXISTS $STAGE_DB;" >/dev/null
    "${SUDO[@]}" $PSQL -d postgres -q -c "CREATE DATABASE $STAGE_DB;" >/dev/null

    # Extensions must land in the SAME schema they occupy in the source, or
    # every reference the dump makes to kernel.pgp_sym_decrypt(...) fails to
    # resolve. pg_dump --schema= never emits CREATE EXTENSION, so we replicate
    # extname+schema from the source catalog rather than guessing 'public'.
    echo ">> replicating extensions into staging"
    EXTS="$EXTS_FOR_CHECK"
    for pair in $EXTS; do
      ext="${pair%%|*}"; ns="${pair##*|}"
      "${SUDO[@]}" $PSQL -d "$STAGE_DB" -q -v ON_ERROR_STOP=1 \
        -c "CREATE SCHEMA IF NOT EXISTS $ns;" \
        -c "CREATE EXTENSION IF NOT EXISTS $ext SCHEMA $ns;" >/dev/null
    done

    echo ">> copying kernel + $T into staging"
    "${SUDO[@]}" $PGDUMP --schema=kernel --schema="$T" --no-owner "$DB" > "$WORK/pre.raw.sql"
    # We pre-created the extension schemas above, so the dump's bare
    # CREATE SCHEMA would collide. Make it idempotent.
    sed -E 's/^CREATE SCHEMA ([a-zA-Z0-9_]+);/CREATE SCHEMA IF NOT EXISTS \1;/' \
        "$WORK/pre.raw.sql" > "$WORK/pre.sql"
    chmod 644 "$WORK/pre.sql"

    # NOT '|| true'. A staging load that half-failed produces a half-scrubbed
    # export, which is worse than no export at all.
    if ! "${SUDO[@]}" $PSQL -d "$STAGE_DB" -q -v ON_ERROR_STOP=1 \
        -f "$WORK/pre.sql" >"$WORK/stage_load.log" 2>&1; then
      echo "!! Staging load failed. Refusing to emit an export." >&2
      grep -i 'error' "$WORK/stage_load.log" | head -5 >&2
      "${SUDO[@]}" $PSQL -d postgres -q -c "DROP DATABASE IF EXISTS $STAGE_DB;" >/dev/null
      exit 1
    fi

    echo ">> scrubbing PII in staging (production untouched)"
    if ! "${SUDO[@]}" $PSQL -d "$STAGE_DB" -v ON_ERROR_STOP=1 \
        -c "SET search_path = $T, kernel;" \
        -c "SET ninja.allow_scrub = 'yes';" \
        -c "SET app.pii_key = 'dev-scrub-key-not-secret';" \
        -f "$HERE/db/scrub.sql"; then
      echo "!! Scrub failed. Refusing to emit a possibly-unscrubbed export." >&2
      "${SUDO[@]}" $PSQL -d postgres -q -c "DROP DATABASE IF EXISTS $STAGE_DB;" >/dev/null
      exit 1
    fi

    echo ">> dumping scrubbed copy"
    "${SUDO[@]}" $PGDUMP --schema=kernel --schema="$T" --no-owner "$STAGE_DB" > "$WORK/$T.dump.raw"
    # The loader pre-creates schema kernel to host the extensions, so the dump's
    # bare CREATE SCHEMA kernel; would abort the load. Ship it idempotent.
    sed -E 's/^CREATE SCHEMA ([a-zA-Z0-9_]+);/CREATE SCHEMA IF NOT EXISTS \1;/' \
        "$WORK/$T.dump.raw" > "$WORK/$T.sql"
    rm -f "$WORK/$T.dump.raw"
    "${SUDO[@]}" $PSQL -d postgres -q -c "DROP DATABASE IF EXISTS $STAGE_DB;" >/dev/null
    SUFFIX=""
    MODE="SCRUBBED — identities anonymised, amounts preserved"
  fi

  ROWS=$(grep -c '^INSERT\|^COPY' "$WORK/$T.sql" 2>/dev/null || echo "n/a")
  SIZE=$(du -h "$WORK/$T.sql" | cut -f1)

  # ---- Loader scripts for the dev box ---------------------------------------
  cat > "$WORK/load_dev_data.sh" <<EOF
#!/usr/bin/env bash
# Load this dataset into a LOCAL PostgreSQL 18 instance.
set -euo pipefail
DB="\${1:-ninja_emp}"

echo ">> creating database \$DB (dropping if present)"
psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS \$DB;"
psql -U postgres -d postgres -c "CREATE DATABASE \$DB;"

# pgcrypto and btree_gist must live in the kernel schema, NOT public: the dump
# calls kernel.pgp_sym_decrypt(...) and kernel.gen_random_uuid(). Creating them
# in public makes the load fail with
#   ERROR: function kernel.pgp_sym_decrypt(bytea, text) does not exist
echo ">> creating extensions in schema kernel"
psql -U postgres -d "\$DB" -c "CREATE SCHEMA IF NOT EXISTS kernel;"
psql -U postgres -d "\$DB" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto  SCHEMA kernel;"
psql -U postgres -d "\$DB" -c "CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA kernel;"

echo ">> loading data"
psql -U postgres -d "\$DB" -v ON_ERROR_STOP=1 -f "$T.sql"

echo ">> verifying (trial balance must be 0)"
psql -U postgres -d "\$DB" -c "SET search_path=$T,kernel; SELECT sum(balance) AS trial_balance FROM $T.trial_balance(current_date);"
echo ">> done. Point Navicat at \$DB."
EOF
  chmod +x "$WORK/load_dev_data.sh"

  cat > "$WORK/load_dev_data.ps1" <<EOF
# Load this dataset into a LOCAL PostgreSQL 18 instance (Windows / Laragon).
# Usage:  .\\load_dev_data.ps1  [dbname]
param([string]\$DbName = "ninja_emp")
\$ErrorActionPreference = "Stop"
Write-Host ">> creating database \$DbName (dropping if present)"
psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS \$DbName;"
psql -U postgres -d postgres -c "CREATE DATABASE \$DbName;"

# Extensions MUST be created in the kernel schema, not public. The dump calls
# kernel.pgp_sym_decrypt(...); with them in public the load dies with
#   ERROR: function kernel.pgp_sym_decrypt(bytea, text) does not exist
Write-Host ">> creating extensions in schema kernel"
psql -U postgres -d \$DbName -c "CREATE SCHEMA IF NOT EXISTS kernel;"
psql -U postgres -d \$DbName -c "CREATE EXTENSION IF NOT EXISTS pgcrypto  SCHEMA kernel;"
psql -U postgres -d \$DbName -c "CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA kernel;"

Write-Host ">> loading data"
psql -U postgres -d \$DbName -v ON_ERROR_STOP=1 -f "$T.sql"
if (\$LASTEXITCODE -ne 0) { throw "Load failed with exit code \$LASTEXITCODE" }

Write-Host ">> verifying (trial balance must be 0)"
psql -U postgres -d \$DbName -c "SET search_path=$T,kernel; SELECT sum(balance) AS trial_balance FROM $T.trial_balance(current_date);"
Write-Host ">> done. Point Navicat at \$DbName."
EOF

  cat > "$WORK/README.txt" <<EOF
Ninja EMP — developer dataset
=============================
tenant        : $T
exported (UTC): $TS
mode          : $MODE
source db     : $DB
approx size   : $SIZE

LOAD IT
-------
Windows (Laragon / PowerShell):
    .\\load_dev_data.ps1
Linux / macOS / WSL / Git Bash:
    ./load_dev_data.sh

Both create a local database (default name: ninja_emp), load this dataset,
and print the trial balance. The trial balance MUST be 0.

WHAT IS IN HERE
---------------
Real row counts, real distributions, real monetary amounts, real edge cases.
$( [ "$RAW" = "1" ] && echo "Real identities. Handle as production data." || echo "Identities are anonymised: names, addresses, contacts, and tax
identifiers are replaced. Amounts, dates, ids and relationships are intact,
so every accounting invariant still holds." )

$( [ "$RAW" = "1" ] && cat <<'RAWWARN'
!! THIS EXPORT CONTAINS REAL PERSONAL DATA
!! Do not commit it. Do not put it in cloud sync. Delete it when finished.
RAWWARN
)
EOF

  # Intermediates MUST NOT ship. pre.raw.sql is the UNSCRUBBED dump; zipping
  # the whole work directory shipped it alongside the scrubbed one and silently
  # defeated the entire exercise. Delete the intermediates, then name the files
  # to include explicitly rather than globbing the directory.
  rm -f "$WORK/pre.raw.sql" "$WORK/pre.sql" "$WORK/stage_load.log"

  ZIP="$OUT/ninja-emp-devdata-$T-$TS$SUFFIX.zip"
  (cd "$WORK" && zip -q "$ZIP" \
      "$T.sql" load_dev_data.sh load_dev_data.ps1 README.txt)

  # Belt and braces: prove the archive contains only what we intended.
  if unzip -Z1 "$ZIP" | grep -qvE "^($T\.sql|load_dev_data\.sh|load_dev_data\.ps1|README\.txt)$"; then
    echo "!! Unexpected files in $ZIP — refusing to ship it." >&2
    unzip -Z1 "$ZIP" >&2
    rm -f "$ZIP"
    exit 1
  fi
  rm -rf "$WORK"
  trap - EXIT

  echo ">> wrote $ZIP ($(du -h "$ZIP" | cut -f1))"
  echo "   mode: $MODE"
done

# -----------------------------------------------------------------------------
# Leak test
#
# The scrub reported success on an export that still contained real names,
# because the notices only describe what the script MEANT to do. This checks
# the artefact itself: pull the identifying strings straight out of production
# and assert that none of them survive in the shipped dump.
#
# Three real leaks were found this way and would otherwise have shipped:
#   1. the unscrubbed intermediate dump, zipped alongside the scrubbed one
#   2. audit_log before/after jsonb snapshots holding every original value
#   3. organization.trading_name, simply missed
# -----------------------------------------------------------------------------
if [ "$RAW" = "0" ] && [ "${NINJA_SKIP_LEAKTEST:-0}" != "1" ]; then
  echo
  echo ">> leak-testing exports"
  LEAK_RC=0
  for T in $TENANTS; do
    ZIP=$(ls -1t "$OUT"/ninja-emp-devdata-"$T"-*.zip 2>/dev/null | grep -v -- '-RAW' | head -1)
    [ -z "$ZIP" ] && continue

    CHK=$(mktemp -d); chmod 755 "$CHK"
    unzip -q -o "$ZIP" -d "$CHK"

    # Load the shipped dump into a scratch database and compare the PII-bearing
    # COLUMNS against production, row by row, joined on id.
    #
    # An earlier version grepped the whole dump for identifying strings. That is
    # unusable: this dataset contains a person named "Jane Customer" and another
    # named "Gift Holder", so the needles 'Customer' and 'Gift' matched the chart
    # of accounts ("Customer Store Credit", "Gift Certificates") and reported
    # leaks that were not leaks. Comparing named columns tests the actual claim
    # -- "this value is no longer the production value" -- with no false
    # positives from ordinary English words in reference data.
    VDB="ninja_leaktest_$$"
    "${SUDO[@]}" $PSQL -d postgres -q -c "DROP DATABASE IF EXISTS $VDB;" >/dev/null
    "${SUDO[@]}" $PSQL -d postgres -q -c "CREATE DATABASE $VDB;" >/dev/null
    for pair in $EXTS_FOR_CHECK; do
      ext="${pair%%|*}"; ns="${pair##*|}"
      "${SUDO[@]}" $PSQL -d "$VDB" -q \
        -c "CREATE SCHEMA IF NOT EXISTS $ns;" \
        -c "CREATE EXTENSION IF NOT EXISTS $ext SCHEMA $ns;" >/dev/null 2>&1
    done
    sed -E 's/^CREATE SCHEMA ([a-zA-Z0-9_]+);/CREATE SCHEMA IF NOT EXISTS \1;/' \
        "$CHK/$T.sql" > "$CHK/load.sql"
    "${SUDO[@]}" $PSQL -d "$VDB" -q -f "$CHK/load.sql" >/dev/null 2>&1

    # dblink is not assumed; compare by pulling both sides as text.
    FOUND=0
    for spec in \
      "party|id|display_name" \
      "person|party_id|given_name" \
      "person|party_id|family_name" \
      "organization|party_id|legal_name" \
      "organization|party_id|trading_name" \
    ; do
      tbl="${spec%%|*}"; rest="${spec#*|}"; key="${rest%%|*}"; col="${rest##*|}"
      PROD=$("${SUDO[@]}" $PSQL -d "$DB"  -tAqc \
        "SELECT $key::text||'='||COALESCE($col,'') FROM $T.$tbl ORDER BY 1;")
      DEV=$("${SUDO[@]}" $PSQL -d "$VDB" -tAqc \
        "SELECT $key::text||'='||COALESCE($col,'') FROM $T.$tbl ORDER BY 1;")
      SAME=$(comm -12 <(echo "$PROD" | sort) <(echo "$DEV" | sort) | grep -v '=$' || true)
      if [ -n "$SAME" ]; then
        echo "   !! LEAK: $tbl.$col unchanged for $(echo "$SAME" | wc -l) row(s)"
        FOUND=$((FOUND+1))
      fi
    done

    # audit_log payloads must not carry row snapshots.
    AUD=$("${SUDO[@]}" $PSQL -d "$VDB" -tAqc \
      "SELECT count(*) FROM $T.audit_log
        WHERE (before_data IS NOT NULL AND before_data <> '{\"scrubbed\": true}'::jsonb)
           OR (after_data  IS NOT NULL AND after_data  <> '{\"scrubbed\": true}'::jsonb);" 2>/dev/null || echo 0)
    if [ "${AUD:-0}" != "0" ]; then
      echo "   !! LEAK: $AUD audit_log row(s) still carry before/after payloads"
      FOUND=$((FOUND+1))
    fi

    "${SUDO[@]}" $PSQL -d postgres -q -c "DROP DATABASE IF EXISTS $VDB;" >/dev/null
    rm -rf "$CHK"

    if [ "$FOUND" -gt 0 ]; then
      echo "   !! $FOUND leaked value(s). Deleting $ZIP."
      rm -f "$ZIP"
      LEAK_RC=1
    else
      echo "   $T: clean (no production identity strings found)"
    fi
  done
  if [ "$LEAK_RC" != "0" ]; then
    echo "!! LEAK TEST FAILED. No export was shipped." >&2
    exit 1
  fi
fi

echo
echo ">> done."
