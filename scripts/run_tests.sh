#!/usr/bin/env bash
# ============================================================================
# Ninja EMP — run_tests.sh
# Runs every assertion suite in db/tests/ against the tenant plane and
# reports PASS / FAIL / ERROR counts per suite and in total.
#
# The suites are written to be RE-RUNNABLE (delta-based assertions), so this
# can be run repeatedly without reprovisioning. Reprovision if you want a
# pristine baseline: db/provision.sh
#
# Usage:
#   scripts/run_tests.sh              # all suites
#   scripts/run_tests.sh close pos    # only named suites
# ============================================================================
set -uo pipefail

DB="${NINJA_DB:-ninja_emp}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="$HERE/db/tests"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# rls_benchmark is a performance probe, not an assertion suite.
DEFAULT_SUITES=(invariants consignment vendormall pos partition close inventory \
                tax1099 lease retail settlement)

if [[ $# -gt 0 ]]; then
  SUITES=("$@")
else
  SUITES=("${DEFAULT_SUITES[@]}")
fi

TOTAL=0; FAILED=0; ERRORED=0
printf '%-14s %6s %6s %6s\n' SUITE PASS FAIL ERR
printf '%-14s %6s %6s %6s\n' -------------- ------ ------ ------

for s in "${SUITES[@]}"; do
  f="$TESTDIR/$s.sql"
  if [[ ! -f "$f" ]]; then
    echo "!! no such suite: $s" >&2; ERRORED=$((ERRORED+1)); continue
  fi
  log="$OUT/$s.log"
  sudo -u postgres psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" >"$log" 2>&1
  rc=$?
  p=$(grep -c 'PASS' "$log")
  fl=$(grep -c 'FAIL' "$log")
  er=0
  if [[ $rc -ne 0 ]]; then er=1; fi
  TOTAL=$((TOTAL+p)); FAILED=$((FAILED+fl)); ERRORED=$((ERRORED+er))
  printf '%-14s %6s %6s %6s\n' "$s" "$p" "$fl" "$er"
  if [[ $fl -gt 0 || $er -gt 0 ]]; then
    echo "   ---- $s output (last 40 lines) ----"
    tail -40 "$log" | sed 's/^/   /'
    echo "   -----------------------------------"
  fi
done

printf '%-14s %6s %6s %6s\n' -------------- ------ ------ ------
printf '%-14s %6s %6s %6s\n' TOTAL "$TOTAL" "$FAILED" "$ERRORED"

if [[ $FAILED -gt 0 || $ERRORED -gt 0 ]]; then
  echo "RESULT: RED"
  exit 1
fi
echo "RESULT: GREEN"
