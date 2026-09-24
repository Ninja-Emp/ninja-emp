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
  public/index.php                 # health check only ("ok")
  bin/migrate.php                  # shared, or tenant <schema>
  bin/seed-demo.php                # wipe and reseed the demo store only
  bin/prove-catalog.php            # catalog diff, then rolls the probe schema back
  migrations/shared/001_public.sql
  migrations/tenant/001_store.sql  # includes the empty-mall reference rows
  seed/demo.sql                    # Saturday journals, fixed ids
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

The seed posts opening capital (debit `1010`, credit `3000`) so the check does not draw an empty bank. Rent stays on `1300`. The only `2000` to `1300` journal is the named apply. The bowl return puts the unpaid holder remainder on `1310`. The check pays leftover payable. Till close is exact, so there is no over/short journal. Journal hashes are scheme v2. `postJournal` is slice 2.

```text
php bin/migrate.php
php bin/migrate.php tenant <schema>
php bin/seed-demo.php
php bin/prove-catalog.php
php bin/prove-database.php
```

`prove-database.php` runs against `emp_pos` only. Each case is a transaction that rolls back. The demo store stays at status `demo` with its ten journals. A live status refuses the wipe.

The database rejects a second opening journal, a repeated posting key, unbalanced lines, a one-line journal, updates or deletes of ledger and audit rows, a repeated booth code, overlapping assignments and periods, a sale, return, rent receipt, or payout pointed at the wrong journal, and a repeated check number.

ACH is listed as a payout method and the check constraint `holder_payouts_cash_register_chk` still rejects it. Payable going negative, and which accounts a rent receipt may touch, are not database constraints. Those stay application rules. Do not change the baseline for them unless the operator asks. `postJournal` is still slice 2.

`EMP_POS_DATABASE_URL` defaults to `emp_pos` on `127.0.0.1:5433`. Prove also reads Nest `emp` and `emp_pos_nest_ref` read-only.

## Next slices

One chat each:

1. Base install. Done.
2. Ledger. `postJournal` in one transaction. Balanced, append-only, idempotent `posting_key`. Trial balance fails closed.
3. Tenancy and identity. Signup creates a schema. Cookie session. CSRF on HTML POST.
4. Saturday kernel. Sale, void, return with clawback, rent charge, rent receipt, apply-payable-to-rent, check payout, open and close till.
5. Catalog, party, booth. Items, vendors, House, booth list. Map is Canvas 2D.
6. Office books. Tax worksheet, income, balance sheet, party statement.

Portal, gifts, store credit, layaway, Square, print hardware, platform billing, and any production import wait until the operator names them.

## Books that do not move

- Integer minor units. JSON money is a digit string plus currency.
- Payable never goes negative. Remainder is clawback `1310`.
- A rent receipt never debits `2000`. The only `2000` → `1300` path is the named apply.
- Fees, cash rounding, and till over/short never touch payable or tax.
- Audit row in the same transaction. No passwords, tokens, or bank numbers in the log.
- Retire and reverse. Booth codes stay unique.
- Do not renumber accounts to match Perfect Consign.
