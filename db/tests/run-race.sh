#!/usr/bin/env bash
# ============================================================================
# Ninja EMP — concurrency (race) proof harness.
#
# Ported from the sibling kernel's prove_race.ps1. Each scenario runs two
# concurrent psql sessions against one tenant schema:
#
#   session A ("hold")  opens a transaction, takes a kernel row lock, sleeps 6s,
#                       then ROLLBACKs;
#   session B ("wait")  opens a transaction and touches the same row, so it must
#                       block on A's lock until A rolls back.
#
# If B returns in well under the sleep, the lock was not taken and the kernel is
# not serialising writers. B must wait >= MIN_WAIT_MS, then finish cleanly.
#
# The scenarios together cover the kernel's lock order:
#   1. counter   journal_counter   (posting serialization point / hash chain)
#   2. period    fiscal_period     (period status)
#   3. account   account           (line account)
#   4. key       unique (tenant_id, idempotency_key)  (idempotency)
#
# A posting takes the counter first, then the period, then each line's account.
# Because the counter is always taken first, two posters can never take the other
# locks in opposite orders, so a deadlock is impossible by construction.
#
# Usage:
#   db/tests/run-race.sh [tenant_schema]     # default: tenant_demo
#
# Connection from the standard libpq environment variables, or PSQL (as
# provision.sh uses), e.g. PSQL="psql -h /tmp -p 5436 -U postgres".
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/race"

DB="${NINJA_DB:-ninja_emp}"
TENANT="${1:-tenant_demo}"
PSQL="${PSQL:-sudo -u postgres psql}"

MIN_WAIT_MS="${MIN_WAIT_MS:-4500}"
SLEEP_SECONDS=6

log()  { printf '[race] %s\n' "$*" >&2; }
fail() { printf '[race] ERROR: %s\n' "$*" >&2; exit 1; }

now_ms() { date +%s%3N; }

psql_q() { $PSQL -d "${DB}" -qAt -c "$1"; }

# Resolve the tenant id so every session sets the same app.tenant_id.
TENANT_ID="$(psql_q "SET search_path TO ${TENANT}, kernel; SELECT tenant_id FROM tenant_config LIMIT 1")"
[[ -n "${TENANT_ID}" ]] || fail "tenant ${TENANT} has no tenant_config row"
log "tenant ${TENANT} (tenant_id ${TENANT_ID})"

# Run a SQL file with the tenant search_path and tenant context prepended.
psql_file() {
    local file="$1"
    {
        printf 'SET search_path TO %s, kernel;\n' "${TENANT}"
        printf "SET app.tenant_id = '%s';\n" "${TENANT_ID}"
        cat "${file}"
    } | $PSQL -d "${DB}" -v ON_ERROR_STOP=1 -qAt
}

# --- one scenario -----------------------------------------------------------
# run_scenario <name>
#   hold = race/<name>_hold.sql, wait = race/<name>_wait.sql
SCENARIO_RESULTS=()
run_scenario() {
    local name="$1"
    local hold="${SQL_DIR}/${name}_hold.sql"
    local wait="${SQL_DIR}/${name}_wait.sql"
    [[ -f "${hold}" && -f "${wait}" ]] || fail "missing scenario SQL for ${name}"

    # Session A: take the lock and hold it.
    psql_file "${hold}" >/dev/null 2>&1 &
    local hold_pid=$!
    sleep 1

    # Session B: must block on A's lock. Time it.
    local start end elapsed out code
    start="$(now_ms)"
    set +e
    out="$(psql_file "${wait}" 2>&1)"
    code=$?
    set -e
    end="$(now_ms)"
    elapsed=$((end - start))

    wait "${hold_pid}" || true

    if (( elapsed < MIN_WAIT_MS )); then
        fail "${name}: session B returned in ${elapsed}ms (< ${MIN_WAIT_MS}ms); it did not wait on the lock
${out}"
    fi
    if (( code != 0 )); then
        fail "${name}: session B failed after waiting ${elapsed}ms
${out}"
    fi
    if [[ "${out}" != *RACE_B_OK* ]]; then
        fail "${name}: session B did not finish cleanly after waiting ${elapsed}ms
${out}"
    fi
    log "${name}: blocked ${elapsed}ms, then completed"
    SCENARIO_RESULTS+=("${name}=${elapsed}")
}

# --- run --------------------------------------------------------------------
log 'setup'
psql_file "${SQL_DIR}/setup.sql" >/dev/null

for scenario in counter period account key; do
    run_scenario "${scenario}"
done

log 'teardown'
psql_file "${SQL_DIR}/teardown.sql" >/dev/null

# Every race transaction rolled back, so no race journal may remain.
LEFT="$(psql_q "SET search_path TO ${TENANT}, kernel; SELECT count(*) FROM journal_entry WHERE source = 'race'")"
if [[ "${LEFT}" != "0" ]]; then
    fail "race proof left ${LEFT} journal entries behind"
fi

printf 'RACE_OK %s\n' "${SCENARIO_RESULTS[*]}"
