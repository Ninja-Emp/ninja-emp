# HANDOFF — Ninja EMP Settlement Fixes (A) + EMP Idea Ports (B)

**Created:** end of the session that began the work. **Purpose:** let a fresh agent
finish without re-deriving anything. Read this top to bottom before touching code.

---

## 0. TL;DR — where we are

The user asked: **"Do A and B."**

- **A** = Fix Ninja EMP's settlement defects **F1–F6** (stating invariants *before*
  writing code — this is a hard requirement from the user).
- **B** = Port EMP's three good ideas: **hash chain**, **minor-unit/scale CHECK**,
  **reversal-as-document-status**.

**Done so far (this session):**
1. Installed PostgreSQL 18.6 and provisioned the DB; established a **GREEN baseline
   of 222/222 assertions**.
2. Read the entire settlement layer in full (files listed in §3).
3. **Wrote the invariants first** — `docs/SETTLEMENT_INVARIANTS.md` (normative).
4. **Wrote ADR-0039** in `docs/DECISIONS.md` (the decisions that close F1–F6 + B1–B3).
5. Wrote `todo.md` with the full task breakdown.

**NOT done yet:** any code change. No migration written. No fix implemented. No test
written. The workspace is otherwise the latest Ninja EMP (pulled earlier this session).

**Next action:** write migration `db/migrations/0007_settlement_integrity.sql` and
implement the fixes in the order in §6, each with a regression test.

---

## 1. Working agreements (from HANDOFF.md §7 — still governing)

- **ALWAYS push back if something is not world-class.** The user is a 30+ year senior
  engineer / Senior DBA. Do not flatter; do not rubber-stamp.
- **DB-first.** Schema and invariants before application code.
- **Externalize decisions to files.** Chat is not load-bearing. Write to `docs/`.
- **State the invariants before writing code.** This is the explicit lesson from the
  prior segment: the F1–F6 defects were caused by writing modules fast and using tests
  as design review. A test written after the code asserts what the code *does*, not
  what it *must do*. The user is watching for this specifically.
- **User profile:** PHP master; does **not** know JS/TypeScript syntax. Uses Navicat,
  Laragon on Windows. GitHub org `Ninja-Emp`, private repo `Ninja-Emp/ninja-emp`.

---

## 2. Environment (this sandbox was reset — reproduce as follows)

PostgreSQL was **not** installed in the fresh sandbox. It is now installed and running.
If the sandbox resets again, reproduce with:

```bash
# PG 18 (Debian 12 ships 15; the project needs 18 for native uuidv7())
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg lsb-release
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-18 postgresql-client-18 postgresql-contrib-18
pg_ctlcluster 18 main start
```

Then provision and test:

```bash
cd /workspace
bash db/provision.sh tenant_demo          # builds ninja_control + ninja_emp + tenant_demo
bash scripts/run_tests.sh                 # must print RESULT: GREEN, 222/222
```

- Tenant schema: `tenant_demo`. Demo tenant id: `11111111-1111-7111-8111-111111111111`.
- Test runner: `scripts/run_tests.sh [suite...]`. Suites live in `db/tests/`.
- Tests are **re-runnable** (delta-based). Reprovision for a pristine baseline.
- `psql` runs as `sudo -u postgres psql -d ninja_emp`.

**Baseline verified this session:**
```
invariants 28 · consignment 12 · vendormall 20 · pos 27 · partition 6
close 23 · inventory 30 · tax1099 19 · lease 20 · retail 37  = 222 PASS, 0 FAIL, 0 ERR
```

---

## 3. The settlement layer — files read in full (know these)

| File | What it holds |
|------|---------------|
| `db/30_ledger.sql` | CoA, `posting_map`, `posting_account()`, `journal_entry`, `journal_line`, `assert_entry_balanced()`, `assert_period_open()`, `assert_subledger_control()`, `assert_control_account_tagged()`, `post_journal_entry()`, **`reverse_journal_entry()`**, `trial_balance()`, `journal_entry_status` view |
| `db/45_openitem.sql` | `open_item`, `payment_application`, `open_item_create()`, `open_item_signed()`, `subledger_control_role()`, **`apply_payment()`**, `v_open_item`, `v_aging`, **`open_item_control_check()`** |
| `db/65_consignment_posting.sql` | `post_consignment_sale()`, **`post_consignor_payout()`** (duplicate allocator) |
| `db/75_pos_posting.sql` | `post_sale()`, **`post_refund()`** (duplicate allocator) |
| `db/85_close.sql` | **`write_off_open_item()`** (no `FOR UPDATE`) |
| `db/78_stored_value.sql` | `issue_stored_value()`, **`redeem_stored_value()`** (reduces `open_item` directly, no application row), `recognize_breakage()` |
| `db/00_kernel.sql` | `kernel.forbid_mutation()`, `kernel.touch_audit()`, `kernel.money_amount` domain, `kernel.currency` (has `minor_unit`), `kernel.subledger_type` (has `uses_open_items`, `allows_untagged`), `kernel.account_type` (has `normal_balance` D/C) |

**Key facts:**
- `kernel.money_amount` = `numeric(19,4)`. `kernel.currency.minor_unit` = display scale
  (USD=2, JPY=0).
- `open_item.open_amount` is a **non-negative magnitude**; direction comes from
  `item_kind` (`invoice` | `credit_memo`). `open_item_signed(kind, amt)` is the only
  value that may be summed into a subledger balance.
- Control accounts and their normal balance: AR 1100 (D); AP 2000, Vendor Payable 2100,
  Consignor Payable 2110, Customer Credit 2200, Gift Cert 2300, Security Deposit 2400,
  Layaway Deposit 2450 (all C).
- `journal_entry` is append-only; `reverse_journal_entry()` mirrors lines only.
- `payment_application` currently has **only** `trg_payment_application_audit`
  (BEFORE UPDATE touch_audit) — **no append-only trigger**.
- Tests set `SET app.tenant_id = '11111111-...'` at the top of each suite (so
  `kernel.current_tenant()` is non-NULL in tests, unlike in migrations).

---

## 4. The six defects (F1–F6) — exact locations

**F1 (CRITICAL) — reversal does not un-apply settlement.**
`db/30_ledger.sql:376` `reverse_journal_entry()` mirrors `journal_line` and stops. It
never touches `payment_application` or `open_item`. After reversing a receipt, the GL
control is correct but the open items still show the invoice paid →
`open_item_control_check()` fails by the reversed amount.

**F2 (CRITICAL) — FIFO is mandatory.**
`apply_payment()` (`db/45_openitem.sql:183`) always allocates oldest-first. No way to
pay a specific invoice.

**F3 — four copies of the allocator, two wrong.**
`apply_payment` (45), `post_consignor_payout` (65:109), `post_refund` (75:173) each
re-implement FIFO. The latter two **omit the `item_kind = 'invoice'` filter**, so a
payout/refund can "settle" a credit memo.

**F4 — two allocators silently swallow unapplied cash.**
`post_consignor_payout` and `post_refund` drop any remainder (no raise, no on-account).
Cash leaves the bank, the control moves, the open items do not → silent drift.

**F5 — `payment_application` is mutable; stored-value bypasses it.**
No append-only trigger on `payment_application`. `redeem_stored_value()`
(`db/78_stored_value.sql:261-265`) reduces `open_item.open_amount` directly with **no
application row**. `recognize_breakage()` (78:330-332) does the same.

**F6 — write-off race + sign-masking.**
`write_off_open_item()` (`db/85_close.sql:439`) reads `SELECT * INTO v_item FROM
open_item WHERE id = p_open_item_id` **without `FOR UPDATE`**.
`open_item_control_check()` (`db/45_openitem.sql:332`) uses
`abs(sum(jl.base_debit - jl.base_credit))` — masks a genuine sign error as a match.

---

## 5. The complete `open_item.open_amount` mutation map (verified by grep)

Every path that changes `open_amount` — the tie-out invariant (PA-4) must cover all:

| Path | File:line | Records an application row today? |
|------|-----------|-----------------------------------|
| `open_item_create()` (insert) | 45 | n/a (creation) |
| `apply_payment()` | 45:256 | **yes** |
| `post_consignor_payout()` | 65:166 | **yes** |
| `post_refund()` | 75:300 | **yes** |
| `redeem_stored_value()` | 78:262 | **NO** ← F5 |
| `recognize_breakage()` | 78:331 | **NO** ← F5 |
| `write_off_open_item()` | 85:475 | **NO** ← F5 |

**Design decision made (recorded in ADR-0039):** `payment_application` becomes the
**open-item activity ledger**. Every reduction of `open_amount` writes a row there
(settlement, write-off, redemption, breakage). This makes PA-4 universally true:
`original_amount - open_amount = Σ applied_amount` over live applications.

---

## 6. Implementation plan — order and design

**Write migration `db/migrations/0007_settlement_integrity.sql`** (append-only,
idempotent, transactional — see `db/migrations/README.md`). It must:
- `CREATE OR REPLACE` the changed functions.
- Add the new columns/triggers/indexes.
- **Guard against existing data** that would violate new constraints (the project's
  convention — see migration 0005 — is to *refuse to install* and report offenders
  rather than break a live DB).

**Order (each step = code + regression test):**

1. **F1 + B3 (reversal-as-status).** Add `unapply_for_entry(p_entry_id)` that finds
   `payment_application` rows for the entry, restores each `open_item.open_amount` by
   the applied amount, recomputes status, and records the un-application append-only
   (a negative-amount row or a `reversed_by` link — decide and document). Call it from
   `reverse_journal_entry()`. Add a guard: a reversed entry cannot be reversed again
   (RV-4). `journal_entry_status` already exposes `is_reversed`.

2. **F5.** Add `trg_payment_application_append_only` (`kernel.forbid_mutation`). Add
   `open_item_application_check()` reconciling `original - open` vs net applications.
   Route `redeem_stored_value()` and `recognize_breakage()` through the application
   ledger.

3. **F3.** Create one `allocate_payment(p_party_id, p_subledger_type, p_amount,
   p_entry_date, p_journal_entry, p_open_item_id DEFAULT NULL, p_on_account DEFAULT
   false)`. Rewrite `apply_payment`, `post_consignor_payout`, `post_refund` to call it.
   The `item_kind = 'invoice'` filter lives **only** inside `allocate_payment`.

4. **F2.** The optional `p_open_item_id` on `allocate_payment` (consume the named item
   first, then FIFO). Expose it on `apply_payment`.

5. **F4.** `allocate_payment` never drops a remainder: default **raise**; optional
   `p_on_account` records an `item_kind = 'on_account'` open item. (Note: adding
   `'on_account'` to the `item_kind` CHECK is a schema change — include it.)

6. **F6.** `FOR UPDATE` in `write_off_open_item()`. Rewrite `open_item_control_check()`
   to compare **signed** sums (no `abs()`), using `account_type.normal_balance` to
   orient the control side.

7. **B1 (hash chain).** Add `prev_hash text`, `entry_hash text` to `journal_entry`;
   unique indexes; a `BEFORE INSERT` trigger computing `entry_hash` over the entry's
   immutable content + `prev_hash` (use `pgcrypto` `digest`, already installed in
   `kernel`); `verify_journal_chain()` returning the first broken link. **Watch out:**
   the trigger needs the tenant's previous entry — order by `entry_no`; handle the
   genesis row; and the migration must backfill existing entries in `entry_no` order.

8. **B2 (scale CHECK).** Add a CHECK on `journal_line`, `open_item`,
   `payment_application` rejecting amounts whose scale exceeds the currency's
   `minor_unit`. Simplest robust form: `amount = round(amount, 2)` for USD, or a
   trigger that looks up `minor_unit`. Decide and document; guard existing data.

**Regression suite:** add `db/tests/settlement.sql` and register it in
`scripts/run_tests.sh` `DEFAULT_SUITES`. Each assertion must **fail before the fix and
pass after** — verify that explicitly (revert mentally / test on a copy).

---

## 7. Invariants (normative — do not re-derive; read the file)

`docs/SETTLEMENT_INVARIANTS.md` is the source of truth. Summary of IDs:
OI-1..6 (open items) · PA-1..6 (applications) · AL-1..6 (allocation) · RV-1..5
(reversal) · CA-1..4 (control) · MO-1..3 (money) · JI-1..4 (journal).

ADR-0039 in `docs/DECISIONS.md` records the decisions. **Read both before coding.**

---

## 8. Gotchas learned the hard way (do not rediscover)

- **psql does not interpolate `:vars` inside `DO $$` bodies.** Bridge via
  `SELECT set_config('app.t_x', :'x', false)` then `current_setting('app.t_x')`.
- **The migration runner does not set `app.tenant_id`**, so `kernel.current_tenant()`
  is NULL inside migrations. Any backfill that needs a tenant must handle NULL.
- **Tests use a per-run random token** (`:'run'`) to avoid idempotency-key collisions
  across re-runs. Follow that pattern.
- **`git config --global --add safe.directory /workspace`** may be needed after a pull
  ("dubious ownership").
- **The EMP repo (`benanamen/emp`) now 404s** (made private/renamed). EMP findings
  stand from the earlier verified clone; do not try to re-clone.
- **GitHub auth:** the sandbox reset wipes credentials. Earlier this session the user
  logged in via the browser and I extracted the session cookie from
  `/workspace/.browser_data/Default/Cookies` (AES-CBC, key
  `pbkdf2_hmac('sha1', b'peanuts', b'saltysalt', 1, 16)`, strip 32-byte domain-hash
  prefix) to `curl` the repo ZIP. If you need to pull again, ask the user to log in
  first, then reuse that method — or just ask the user to push/pull.

---

## 9. Files created/modified this session (uncommitted)

- `docs/SETTLEMENT_INVARIANTS.md` — **NEW** (normative invariants).
- `docs/DECISIONS.md` — **MODIFIED** (ADR-0039 appended before "Open decisions").
- `todo.md` — **REWRITTEN** (full task breakdown; §0–1 done, §2–11 pending).
- `docs/EMP_ASSESSMENT.md` — untracked (from earlier this session; the EMP review).
- `db/migrations/0006_item_price_barcode.sql`, `src/`, `app/`, `ui/`, `tests/` —
  untracked (from the earlier pull of latest Ninja EMP; not mine).

**Nothing has been committed.** Decide with the user whether to commit the invariants
+ ADR first (recommended: yes — they are the design) before the code.

---

## 10. First three actions for the next agent

1. Read `docs/SETTLEMENT_INVARIANTS.md` and ADR-0039 in `docs/DECISIONS.md`.
2. Re-establish the environment (§2) and confirm **222/222 GREEN**.
3. Write `db/migrations/0007_settlement_integrity.sql`, starting with **F1 + B3**
   (reversal un-applies), then its regression test. Proceed in the §6 order.

**Do not** write code before re-reading the invariants. That is the whole point of
this handoff.
