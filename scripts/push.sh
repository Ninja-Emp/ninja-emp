#!/usr/bin/env bash
# ============================================================================
# Ninja EMP — push.sh
# Commits everything and pushes to the configured GitHub remote.
#
# First-time setup (run once):
#   git remote add origin https://github.com/<you>/<repo>.git
#   # or with a token:  https://<token>@github.com/<you>/<repo>.git
#
# Usage: bash scripts/push.sh "commit message"
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

MSG="${1:-chore: sync $(date -u +%Y-%m-%dT%H:%M:%SZ)}"

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "!! no 'origin' remote configured." >&2
  echo "   run: git remote add origin https://github.com/<you>/<repo>.git" >&2
  exit 1
fi

git add -A
if git diff --cached --quiet; then
  echo ">> nothing to commit."
else
  git commit -m "$MSG"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo ">> pushing $BRANCH -> origin"
git push -u origin "$BRANCH"
echo ">> done."
