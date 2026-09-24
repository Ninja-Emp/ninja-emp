# emp-pos handoff

This repository is the last register. Open chats on `emp-pos.code-workspace`, not the Nest EMP workspace.

## Locked

- Root: `C:\laragon\www\emp-pos`. One git repository. One PHP 8.5 process.
- Constitution: `C:\laragon\www\emp\docs\srs\README.md` (read-only reference in this workspace). Books stay EMP. Payable `2000`, rent receivable `1300`, clawback `1310`. No rent haircut, no shadow ledger, no second book.
- UI lessons, read-only: Perfect Consign storefront (`reference-pc-web`) for how that one account actually operates. Nest EMP screens under `reference-emp`. Ninja when the operator names it. Competitor notes in `C:\laragon\www\emp\docs\engineering\competitors\README.md`. Steal Saturday speed. Refuse mashed rent-in-payout, float money, penny drift, and fees that shrink payable.
- Becca is not a migration, a cutover, or a data source. Do not quote that mall’s balances. Do not connect to Perfect Consign production. The storefront is the only Becca-related input, and only as “how PC works.”
- Libraries, when a later slice installs them: `krubio/perfect-session`, `perfect-router`, `perfect-logger`, `perfect-database`, `perfect-container`. Strict types, attribute routes, PSR-4, PSR-3, PDO positional placeholders. Classes under 500 lines. No `StoreService`.
- Postgres 18 on port **5433**. Database **`emp_pos`**. Do not `docker volume rm`. Do not drop `emp_pos`, `emp_pos_nest_ref`, or Nest schemas unless that message names them.
- Slice 1 installed no Composer packages. Do not apply `emp-pos` DDL onto the Nest database `emp`.

## Workspace

`emp-pos.code-workspace` is the only write root for this product.

- `emp-pos` is writable.
- `reference-emp` (`C:\laragon\www\emp`) is read-only.
- `reference-pc-web` (`C:\laragon\www\curser-pos-web`) is read-only.
- `curser-pos-specs` and `curser-pos-admin` are not in this workspace.

## Directory

```text
emp-pos/
  public/index.php                 # health, plus /api/v1 identity and ledger
  bin/migrate.php                  # shared, or tenant <schema>
  bin/seed-demo.php                # wipe and reseed the demo store only
  bin/prove-catalog.php            # catalog diff, then rolls the probe schema back
  bin/prove-openapi.php            # identity, ledger, and register documents
  bin/prove-http.php               # signup, journal, trial balance; drops only slug contract-proof
  docs/openapi/                    # identity, ledger, register
  migrations/shared/001_public.sql
  migrations/tenant/001_store.sql  # includes the empty-mall reference rows
  seed/demo.sql                    # demo journals, fixed ids
  composer.json                    # PHP ^8.5, no packages installed
  docs/HANDOFF.md
  src/Bootstrap/Kernel.php
  src/Shared/
  src/Feature/
  tests/Feature/
```

Feature verticals are not created yet. Each later vertical is `src/Feature/<Name>/` with `<Name>Provider.php`, `Domain/`, `Action/`, `Http/`, `Web/`, `Persistence/`, and `templates/`. A feature may call `Ledger` and `Shared`. It does not query a sibling’s tables. When `Action/` would become a junk drawer, split by job (`Pos/Checkout/`, `Pos/Return/`). `Shared` is Money, errors, CSRF, database, and page chrome only.

`migrations/**/*.sql` is marked `-text` in `.gitattributes`. Function bodies keep the carriage returns from the Nest dump. Normalizing those files to LF makes the catalog diff fail.

## Slice 1

Done. Two DDL baselines. `php bin/prove-catalog.php` matched `emp_pos.public` to Nest `emp.public`, and a rolled-back store probe to a live tenant at migration 066. Reference rows match the empty Nest chain in `emp_pos_nest_ref` (`nest_tenant`), except intake extras.

New malls follow migration 066: `intake_show_category`, `intake_show_brand`, `intake_show_color`, `intake_show_size`, and `intake_show_notes` are off. A Nest chain that inserted `store_settings` before 066 still has them on. That row is not copied.

`php bin/seed-demo.php` builds Demo Mall and can wipe it again. Wipe runs only when slug `demo`, status `demo`, and schema `tenant_018f0000_0000_7000_8000_000000000001` all match. Logins: `owner@demo.test` and `cashier@demo.test`. Password: `practice`.

The seed posts opening capital (debit `1010`, credit `3000`) so the check does not draw an empty bank. Rent stays on `1300`. The only `2000` to `1300` journal is the named apply. The bowl return puts the unpaid holder remainder on `1310`. The check pays leftover payable. Till close is exact, so there is no over/short journal. Journal hashes are scheme v2.

```text
php bin/migrate.php
php bin/migrate.php tenant <schema>
php bin/seed-demo.php
php bin/prove-catalog.php
php bin/prove-database.php
php bin/prove-ledger.php
php bin/prove-openapi.php
php bin/prove-http.php
```

`prove-database.php` runs against `emp_pos` only. Each case is a transaction that rolls back. The demo store stays at status `demo` with its ten journals. A live status refuses the wipe.

The database rejects a second opening journal, a repeated posting key, unbalanced lines, a one-line journal, updates or deletes of ledger and audit rows, a repeated booth code, overlapping assignments and periods, a sale, return, rent receipt, or payout pointed at the wrong journal, and a repeated check number.

ACH is listed as a payout method and the check constraint `holder_payouts_cash_register_chk` still rejects it. Payable going negative, and which accounts a rent receipt may touch, are not database constraints. Those stay application rules. Do not change the baseline for them unless the operator asks.

`EMP_POS_DATABASE_URL` defaults to `emp_pos` on `127.0.0.1:5433`. Prove also reads Nest `emp` and `emp_pos_nest_ref` read-only.

## Contracts and handlers

Done. `docs/openapi/identity.openapi.json`, `ledger.openapi.json`, and `register.openapi.json`. `php bin/prove-openapi.php` checks those documents. It does not listen and does not touch the database.

HTTP handlers exist for identity (`/csrf`, `/signup`, `/login`, `/logout`, `/session`) and the ledger (`POST /journals`, `GET /journals/{journalId}`, `GET /books/trial-balance`). Signup creates the store schema, the primary book, an argon2id password, and a session whose `token_hash` is sha256 of the cookie `session`. Mutating routes require cookie `csrf` and header `X-CSRF-Token`. A cashier cannot post a journal. Ledger posts go through `LedgerPoster` only. That function refuses a rent receipt that touches `2000`, any `2000` to `1300` journal that is not `payable_rent_settlement`, and a payable balance that would go negative. A debit to payable never credits income. Rent income credits only when rent receivable is debited. `4200`, `6170`, and `6180` never share a journal with payable or tax. `6150` may share a sale or sale-return ticket with them. `LedgerPoster::post` only posts owner capital between `1010` and `3000`. A payout, rent receipt, labeled sale, or cash credited to income does not post. A reversal must swap that named journal. The same posting key with a different body, time, or memo is refused. The bank is locked before the balance is read. A posting date must be a real calendar day. Only an owner or a manager can post. Money in JSON is a canonical digit string. The journal insert and an `audit_events` row commit together. Register routes are documented only. There are no sale, void, return, rent, payout, or till handlers.

`php bin/prove-http.php` signs up slug `contract-proof`, posts a journal, reads it, reads the trial balance, and refuses the illegal shapes, then drops only that slug’s schema. Demo stays.

PHPStan is level 10 with no baseline. PHPMD is `composer run check:phpmd` after a clean probe. PHPUnit line coverage of `src/` is above 80%. Infection 0.35 (0.32 cannot install next to PHPUnit 13) is 100% MSI on `Money`, `JournalHash`, `LedgerPoster`, and `TrialBalance`.

## Next slices

1. Base install. Done.
2. Ledger poster. Done. `LedgerPoster::post` posts in the caller’s transaction. The same `posting_key` returns the existing journal. A drifted trial balance throws. `php bin/prove-ledger.php` rolls back on `emp_pos`.
3. Identity and ledger contracts. Done.
4. Register contract. Done as a document. Handlers are not written.
5. Identity and ledger HTTP. Done.
6. Register handlers: sale, void, return with clawback, rent charge, rent receipt, apply payable to rent, check payout, till open and close.
7. Catalog, party, booth. Items, vendors, House, booth list.
8. Office books. Tax worksheet, income, balance sheet, party statement.

Portal, gifts, store credit, layaway, Square, print hardware, platform billing, and any production import wait until the operator names them.

## Books that do not move

- Integer minor units. JSON money is a digit string plus currency.
- Payable never goes negative. Remainder is clawback `1310`.
- A rent receipt never debits `2000`. The only `2000` → `1300` path is the named apply.
- Fees, cash rounding, and till over/short never touch payable or tax.
- Audit row in the same transaction. No passwords, tokens, or bank numbers in the log.
- Retire and reverse. Booth codes stay unique.
- Do not renumber accounts to match Perfect Consign.
