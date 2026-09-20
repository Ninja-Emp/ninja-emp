#!/usr/bin/env bash
# ============================================================================
# Ninja EMP — zip_backup.sh
# Produces a single downloadable zip containing:
#   - the latest DB backup (schema + data + custom dumps)
#   - the full source tree (db/, docs/, scripts/, HANDOFF.md, README)
# Output: dist/ninja-emp-backup-<UTC-timestamp>.zip
#
# Usage: bash scripts/zip_backup.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DIST="$HERE/dist"
ZIP="$DIST/ninja-emp-backup-$STAMP.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$DIST"

# 1) Latest DB backup.
if [[ -d "$HERE/backups/LATEST" ]]; then
  mkdir -p "$STAGE/backup"
  cp -r "$HERE/backups/LATEST/." "$STAGE/backup/"
else
  echo "!! no backups/LATEST found — run scripts/backup.sh first" >&2
  exit 1
fi

# 2) Source tree (exclude runtime cruft, prior backups, dist).
mkdir -p "$STAGE/source"
rsync -a \
  --exclude '.git' \
  --exclude '.browser_data' \
  --exclude '.psiphon_data' \
  --exclude '.agent_hooks' \
  --exclude 'outputs' \
  --exclude 'summarized_conversations' \
  --exclude 'backups' \
  --exclude 'dist' \
  "$HERE/" "$STAGE/source/"

# 3) Manifest.
{
  echo "ninja-emp backup bundle"
  echo "created_utc=$STAMP"
  echo "contents: backup/ (latest DB dump), source/ (full repo tree)"
} > "$STAGE/README.txt"

( cd "$STAGE" && zip -qr "$ZIP" . )
echo ">> wrote $ZIP"
ls -la "$ZIP"
