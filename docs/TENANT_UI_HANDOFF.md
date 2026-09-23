# Ninja EMP — Tenant UI Build Handoff

**Status:** In progress · **Branch:** `feat/tenant-ui` · **Owner:** agent build
**Purpose:** A complete, self-contained handoff so any agent (or human) can resume this build
if credits run out. Read this top-to-bottom before touching code.

---

## 0. TL;DR — what we are building

The **Tenant UI**: the mall operator's back-office console for Ninja EMP. It is the
**tenant-facing** application (the mall business is the SaaS tenant). It is deliberately
**clean, professional, and easy to navigate** — and deliberately **NOT** styled like the
warm "grandma-friendly" vendor portal (that stays as-is; see §9).

Delivered as **real PHP templates** (option "A" chosen by the owner): server-rendered PHP
with a thin **mock data layer** so it runs standalone today, then wires to the real DBAL
(ADR-0025) later. No framework (per HANDOFF.md §2). PSR-12 style.

---

## 1. Locked decisions (from the owner)

| # | Decision | Value |
|---|----------|-------|
| 1 | "Tenant UI" means | The **mall operator's back-office/admin console** (confirmed) |
| 2 | Delivery format | **(A)** Real PHP templates + thin mock data layer, wire to DBAL later |
| 3 | First-pass scope | **POS** (barcode scan, split payments, hold sale, discounts, tax-free toggle), **Booth CRUD + 2D booth map**, **Vendors management**, **Inventory management**, **Reports** |
| 4 | Roles | **Yes** — role-aware UI (owner / manager / accountant / cashier) |
| 5 | Theming | **Neutral** default, **light + dark** mode, **easily swappable themes**; a **secondary theme in the dark-blue range**. Theme = CSS custom properties, switchable at runtime. |
| 6 | Navigation | **Collapsible left sidebar** with related icons; **top bar** for search + account |
| 7 | Standard | "World-class SaaS application" — use best judgment |

**Explicitly out of scope for now:** the vendor portal (leave the existing `ui/` prototype
untouched — see §9). POS is treated as a surface **inside** the tenant UI shell (owner did
not ask to split it out; revisit if needed).

---

## 2. Environment facts (verified)

- **OS:** Debian 12 (bookworm), Python 3.11 base image.
- **PHP:** NOT preinstalled. Install with:
  `sudo apt-get update && sudo apt-get install -y php-cli php-mbstring php-xml php-curl php-zip php-intl unzip`
  (Target PHP 8.x; the project's production target is PHP 8.5 per HANDOFF.md, but any 8.1+ runs this UI.)
- **Composer:** not preinstalled; install if a dependency is ever needed (we aim for **zero** deps).
- **Repo:** `Ninja-Emp/ninja-emp`, default branch `main`. Auth via `gh` / `$GITHUB_TOKEN`.
- **Push pattern:** `git push https://x-access-token:$GITHUB_TOKEN@github.com/Ninja-Emp/ninja-emp.git <branch>`
- **Ports:** 8080 and 8090 are taken by pre-existing servers. Use **8091** for local preview
  (`php -S localhost:8091 -t public public/router.php`). Expose with the `expose-port` tool when sharing.
- **bcmath:** required by `Support/Money.php`. Install with `sudo apt-get install -y php-bcmath`.

---

## 3. Architecture (how the PHP app is laid out)

```
apps/tenant-ui/                     ← the tenant UI application root
  public/
    index.php                      ← single front controller (all requests route here)
    assets/
      css/theme.css                ← design tokens + components (themes via [data-theme])
      css/app.css                  ← layout/shell styles
      js/app.js                    ← shell behavior (sidebar, theme switch, search)
      js/pos.js                    ← POS island (barcode, split pay, hold, discount, tax-free)
      js/booth-map.js              ← 2D booth map island (drag/click, CRUD hooks)
  src/
    Support/
      View.php                     ← tiny template renderer (layout + partials, escaping)
      Router.php                   ← attribute-free simple router (path → controller)
      Auth.php                     ← mock session + role gate (RBAC)
      Theme.php                    ← theme registry (neutral, dark-blue, …)
      Money.php                    ← string/bcmath money formatting (never float)
      Flash.php                    ← one-shot messages
    Data/
      MockRepository.php           ← thin mock data layer (arrays) — swap for DBAL later
      seed.php                     ← realistic seed data (mall, spaces, vendors, items, sales)
    Http/
      Controllers/                 ← one controller per module (see §5)
    Views/
      layout.php                   ← app shell (sidebar + topbar + content slot)
      partials/                    ← sidebar, topbar, table, card, modal, pagination, empty-state
      <module>/                    ← per-module view templates
  README.md                        ← how to run + how to wire the DBAL
```

**Why a front controller + `src/`:** mirrors the real app's PSR-7/15 middleware + attribute
routing shape, so swapping the mock router for the real one is mechanical. Keep controllers
thin; keep views dumb; keep data access behind `MockRepository` so the DBAL swap is one class.

**Escaping:** every dynamic value in a view goes through `View::e()` (htmlspecialchars,
ENT_QUOTES, UTF-8). No raw echo of user data. Ever.

**Money:** all amounts are **strings** end-to-end (bcmath), formatted only at render via
`Money::format()`. Never cast money to float. (Matches ADR-0002 / ADR-0025.)

---

## 4. Design system (theming)

- **Tokens** live in `assets/css/theme.css` as CSS custom properties on `:root` and
  `[data-theme="…"]`. Components reference **only** tokens — never hard-coded colors.
- **Themes to ship:**
  - `neutral` (default) — slate greys + a single restrained accent (indigo/teal).
  - `dark` — dark surface variant of neutral.
  - `dark-blue` — the requested **secondary theme in the dark-blue range**.
  - Light/dark is a **mode**; theme is a **palette**. Support both axes:
    `data-theme="neutral"` + `data-mode="light|dark"`, or fold mode into theme names
    (`neutral`, `neutral-dark`, `dark-blue`, `dark-blue-dark`). Pick one and document it.
- **Switching:** `Theme.php` exposes the registry; `js/app.js` sets the attribute and
  persists the choice in `localStorage`. Server can also set it per user preference.
- **Accessibility:** WCAG AA contrast in every theme; visible focus rings; keyboard-operable
  sidebar and islands; `prefers-reduced-motion` respected. (The vendor portal set the bar;
  match or exceed it.)
- **Icons:** inline SVG sprite (no icon-font dependency). Keep them consistent and simple.

---

## 5. Modules & routes (first pass)

| Module | Route(s) | Controller | Notes |
|--------|----------|-----------|-------|
| Dashboard | `/` | `DashboardController` | KPIs: today's sales, open shifts, low stock, payables |
| POS | `/pos` | `PosController` | Barcode scan, split payments, hold/resume sale, discounts, tax-free toggle |
| Booths | `/booths`, `/booths/new`, `/booths/{id}` | `BoothController` | CRUD + 2D map island |
| Booth map | `/booths/map` | `BoothController@map` | 2D interactive map (SVG/canvas island) |
| Vendors | `/vendors`, `/vendors/{id}` | `VendorController` | List, detail, balances (ties to `v_vendor_*`) |
| Inventory | `/inventory`, `/inventory/{id}` | `InventoryController` | Items, stock, weighted-avg cost, adjustments |
| Reports | `/reports` | `ReportController` | Sales, aging, payouts, tax, inventory valuation |
| Settings | `/settings` | `SettingsController` | Theme, roles, tenant config |
| Auth | `/login`, `/logout` | `AuthController` | Mock session; role gate |

**Roles (RBAC):** `owner` (all), `manager` (ops + POS + reports), `accountant` (ledger +
reports + vendors, no POS), `cashier` (POS only). Gate in `Auth::can($permission)`; hide nav
items and block routes the role can't use. Document the permission matrix in `Auth.php`.

---

## 6. POS requirements (detail — this is the priority surface)

- **Barcode scanning:** a focused input that captures scanner keystrokes (scanners act as
  keyboards ending in Enter). On scan → look up item → add to cart. Manual SKU entry too.
- **Split payments:** a sale can be paid by multiple tenders. Tender types mirror the domain
  (ADR-0029): cash, check, card (→ **clearing**, not cash), gift certificate, customer store
  credit, **vendor payable draw**. Show remaining balance; block completion until tenders
  cover the total. (Mock layer only — no real posting yet.)
- **Hold sale:** park the current cart, resume later. Multiple held sales, named/dated.
- **Discount handling:** line and/or order discounts (percent or amount), with a reason.
  Show the discount explicitly (never silently net it).
- **Tax-free toggle:** per-sale toggle that zeroes tax (e.g., resale/charity). Show clearly
  that tax was waived and why.
- **Fast, keyboard-first:** cashier should be able to run a whole sale without a mouse.
- **Big, clear totals:** subtotal, discount, tax, total, change due.

---

## 7. Build order (do it in this sequence)

1. **Scaffold** `apps/tenant-ui/` structure + front controller + `View`/`Router`/`Auth`/`Theme`/`Money`.
2. **Design system** `theme.css` (neutral + dark + dark-blue) + `app.css` shell.
3. **App shell** `layout.php` + sidebar + topbar + theme switcher + search.
4. **Mock data** `seed.php` + `MockRepository` (mall, floors, spaces, vendors, items, sales, users/roles).
5. **Dashboard**.
6. **POS** (the priority) — cart, barcode, split pay, hold, discount, tax-free.
7. **Booths** CRUD + **2D booth map** island.
8. **Vendors** management.
9. **Inventory** management.
10. **Reports**.
11. **Settings** (theme, roles).
12. **README** + run/verify + push + PR.

---

## 8. Definition of done (quality gate)

- Runs with `php -S localhost:8090 -t apps/tenant-ui/public` and every route returns 200.
- No PHP notices/warnings/errors in any request (check the server log).
- All output escaped; money handled as strings; no floats.
- Every theme (neutral, dark, dark-blue) passes AA contrast and looks intentional.
- Sidebar collapses; theme switch persists; POS works keyboard-only; booth map is keyboard-operable.
- Screenshots captured for each module (light + dark).
- Branch pushed; PR opened against `main`.

---

## 9. Do NOT touch (leave as-is)

- `ui/` — the **grandma-friendly vendor portal** prototype. The owner said leave it as is for now.
  It is a separate, intentionally different design language. Do not restyle it to match the tenant UI.

---

## 10. Progress log (update as you go)

- [x] Environment recon (PHP missing → install step documented in §2)
- [x] Branch `feat/tenant-ui` created off `main`
- [x] This handoff doc written
- [x] Scaffold app structure (front controller + router.php + PSR-4 autoloader)
- [x] Design system (themes: neutral + dark-blue; light + dark modes)
- [x] App shell (collapsible sidebar, topbar search/account, theme switcher)
- [x] Mock data layer (MockRepository + seed.php)
- [x] Dashboard (KPIs, 14-day trend, occupancy, recent sales, low stock)
- [x] POS (barcode scan, split payments, hold/resume, discounts, tax-free)
- [x] Booths + 2D map (CRUD + interactive map island)
- [x] Vendors (list + statement view)
- [x] Inventory (search + detail)
- [x] Reports (tender mix, vendor payouts, tax)
- [x] Settings (appearance, tenant config, role/permission matrix)
- [x] Verify (all routes 200, no warnings, RBAC gating) + screenshots (light + dark)
- [x] README + push + PR

**Build complete.** All modules implemented and verified. See `apps/tenant-ui/README.md`
for run instructions and the DBAL wiring guide.

---

## 10b. Round 2 fixes (owner feedback)

After the first pass the owner reviewed the running UI and filed a list of issues. All were
addressed on the same branch:

| # | Issue | Fix |
|---|-------|-----|
| 1 | No way to add/edit inventory items | `InventoryController::create/edit/store/update` + `Views/inventory/form.php`; "+ New item" button and per-row Edit on the list |
| 2 | No way to add/edit vendors | `VendorController::create/edit/store/update` + `Views/vendors/form.php`; "+ New vendor" button and per-row Edit |
| 3 | POS should not show the catalog | Catalog grid removed from `Views/pos/index.php`; `PosController::index` no longer passes all items |
| 4 | Instant inventory modal (vendor mall: items not in inventory until sold) | `PosController::quickAdd` (`POST /pos/quick-add`) + modal in the POS view; **vendor-owned by default**, store-owned option |
| 5 | No register management | `RegisterController` (index/create/edit/store/update/open/close) + `Views/registers/{index,form}.php`; open with float, close with count + variance |
| 6 | Can't edit business name / currency / timezone | `SettingsController::update` calls `MockRepository::updateTenant`; Settings tenant card is now an editable form |
| 7 | Left sidebar too fat when open | `--sidebar-w` narrowed `264px → 208px` (collapsed rail unchanged at `68px`) |
| 8 | Settings theme picker didn't work (topbar did) | Root cause: the layout applies the persisted theme from `localStorage` **before paint**, overriding the session value the form wrote. Fix: the Settings form now writes `localStorage` on submit and reflects the applied value on load. |
| 9 | Instant inventory is always vendor-owned | Default `owner=vendor`; store-owned is an explicit opt-in |
| 10 | Store should sell and buy | Store-owned items appear as POS tiles (sell); "Buy from vendor" (`POST /pos/buy`, `POST /vendors/{id}/purchase`) creates a store-owned item and increases the vendor payable |

**Data layer:** `MockRepository` is now **session-backed** (`$_SESSION['nem_data']`, seeded
from `seed.php` on first use) so create/edit/purchase/register operations actually persist for
the life of the session. Method signatures are unchanged from what a DBAL-backed repository
would expose.

**New routes:** `/inventory/new`, `POST /inventory`, `/inventory/{id}/edit`, `POST /inventory/{id}`,
`/vendors/new`, `POST /vendors`, `/vendors/{id}/edit`, `POST /vendors/{id}`, `POST /vendors/{id}/purchase`,
`/registers`, `/registers/new`, `POST /registers`, `/registers/{id}/edit`, `POST /registers/{id}`,
`POST /registers/{id}/open`, `POST /registers/{id}/close`, `POST /pos/quick-add`, `POST /pos/buy`.

**Round 2 progress log:**

- [x] Settings theme picker fixed (localStorage sync)
- [x] Inventory add/edit
- [x] Vendors add/edit
- [x] POS catalog removed
- [x] Instant inventory modal (vendor-owned default)
- [x] Register management (create/open/close)
- [x] Editable tenant settings
- [x] Sidebar narrowed
- [x] Store sell + buy-from-vendor
- [x] Verify all routes + POST endpoints
- [x] Screenshots (light + dark) refreshed
- [x] README + handoff updated

---

## 10c. Remaining application work (the real app, beyond this UI)

The Tenant UI is a **front-end slice** running on a mock data layer. The following is the
remaining work to make Ninja EMP a real application. This is the handoff for the next phase.

### A. Data access layer (DBAL) — ADR-0025 — ✅ DELIVERED
- `src/Db/` implements the contract in `docs/DBAL.md`: `Connection`, `PdoConnection`,
  `TenantContext`/`Tenant`, `ResultSet`, `Row`, `PlaceholderRewriter` (quote-aware named→positional),
  `Identifier`, `TypeMapper`, `ErrorMapper`, and typed exceptions.
- **bcmath + string money** end-to-end (`src/Money/Money.php`); **emulated prepares** (PgBouncer);
  **nested `transactional()` joins the outer transaction**; `SET LOCAL` tenant context per tx.
- **83 unit assertions green** (`php tests/run.php`), zero deps. Functional tests auto-skip without a DB.
- **Still to do:** a `DbalRepository implements Repository` with one method per `MockRepository`
  method (identical signatures) so controllers/views don't change; bind it in `public/index.php`
  and delete the mock. Read the realtime vendor views: `v_vendor_balance_realtime`,
  `v_vendor_sales_realtime`, `v_vendor_sales_today`, `v_vendor_payout_available`, `v_vendor_statement`.

### B. Ledger engine — ADR-0020 / ADR-0028 / ADR-0029 — ✅ DELIVERED
- `src/Ledger/` implements **append-only, reversal-not-edit, idempotent** posting via
  `LedgerService::post()` → `post_journal_entry()`; `reverse()` → `reverse_journal_entry()`.
- **Account determination** via `posting_map` (`resolveAccount()` → `posting_account()`), no
  hard-coded account numbers. `JournalEntry` validates balance in PHP before the DB.
- **Tenders** (ADR-0029) mapped in `Tender`: cash/check→undeposited funds, card→clearing,
  gift cert→liability, store credit→customer credit, vendor draw→vendor payable.
- **Still to do:** wire `PosController::checkout` to post; vendor payable accrual on sale;
  payout/aging; commission per `commission_rule`; accrual-at-sale → realtime vendor portal (ADR-0028).

### C. Auth & tenancy — ✅ DELIVERED
- `src/Auth/`: `Role` (permission matrix — the server-side enforcement point), `User`,
  `PasswordHasher` (Argon2id/bcrypt), `Csrf` (constant-time), `SessionAuth` (fixation-safe).
- `src/Tenancy/`: `TenantRegistry` (control-plane seam), `TenantRecord` (validates schema name),
  `InMemoryTenantRegistry`, `TenantResolver` (slug → host → `TenantContext`, rejects
  suspended/unknown tenants).
- **Still to do:** wire `SessionAuth` + `TenantResolver` into the request pipeline (routing +
  middleware), replace the mock role switcher, and enforce RBAC on the API surface.

### D. API-first surface — OpenAPI 3.1
- Expose the same operations as JSON endpoints (PSR-7/15 + attribute routing) so the UI and
  integrations share one contract. Generate/validate against the OpenAPI spec.

### E. Domain modules still to build (server-side)
- **Leases / rent components / billing** (recurring rent, CAM, late fees).
- **Consignor agreements / commission rules** (tiered, per-category).
- **Consignment item intake** (check-in, tagging, photos, price changes).
- **Payouts** (batch vendor payouts, statements, 1099 prep).
- **Open items / payment applications** (customer store credit, layaway).
- **Shifts** (tie registers to shifts; cash counts, over/short posting).
- **Reports** backed by real queries (sales, aging, payouts, tax, inventory valuation).

### F. Hardening
- Input validation + error handling; structured logging (PSR-3).
- Migrations runner; seed/fixtures for dev.
- Tests (unit for money/ledger; integration for posting; e2e for POS).
- CI (lint + tests), deploy pipeline.

**Suggested next step:** **A (DBAL)**, **B (ledger engine)** and **C (auth & tenancy)** are
delivered (`src/`, 118 unit assertions green). Next: the **DbalRepository** that swaps the mock
data layer for the real DBAL, then the domain modules in **E** (Vendor Mall, Consignment, POS,
Inventory) built on `LedgerService`.

---

## 11. Key references in this repo

- `HANDOFF.md` — locked technical decisions (PHP 8.5, no frameworks, PSR set, DBAL deferred).
- `docs/SRS.md` — Parts 3–5 define the domains the UI must surface (Vendor Mall, Consignment, POS).
- `docs/DECISIONS.md` — ADR-0025 (DBAL), ADR-0029 (tenders), ADR-0020 (posting_map), ADR-0002 (money).
- `docs/ROADMAP.md` — Part 6 is the application layer; this UI is the first slice of it.
- `db/80_vendor_portal.sql` — the realtime views the Vendors module will read.
- `ui/` — the vendor portal prototype (reference for accessibility bar; do not restyle).
