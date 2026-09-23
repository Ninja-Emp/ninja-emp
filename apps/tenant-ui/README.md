# Ninja EMP — Tenant UI

> **Document root:** `apps/tenant-ui/public` · **Default port:** `8091` ·
> **Serve:** `php bin/ninja serve-ui` (from the repo root).

The **tenant-facing back-office console** for Ninja EMP: the mall operator's admin
application. Clean, professional, and easy to navigate — deliberately distinct from the
warm "grandma-friendly" vendor portal design prototype in
`../../docs/prototypes/vendor-portal/` (which is left untouched).

Built as **real PHP templates** (server-rendered) with a **thin mock data layer** so it
runs standalone today and wires to the real DBAL (ADR-0025) later. **No framework**, PSR-12
style, zero Composer dependencies.

---

## Quick start

```bash
# From this directory (apps/tenant-ui)
php -S localhost:8091 -t public public/router.php
```

Then open <http://localhost:8091>.

> **Why `router.php`?** PHP's built-in server does not route unknown paths to a front
> controller. `public/router.php` serves real static files directly and forwards everything
> else to `public/index.php`.

### Requirements

- **PHP 8.1+** (production target is 8.5 per `../../docs/HANDOFF.md`).
- **bcmath** extension — required by `src/Support/Money.php`:
  ```bash
  sudo apt-get install -y php-bcmath
  ```
- No database, no Composer, no build step.

---

## What's inside

| Module | Route | Notes |
|--------|-------|-------|
| Dashboard | `/` | KPIs, 14-day sales trend, booth occupancy, recent sales, low stock |
| Point of Sale | `/pos` | Barcode scan, **instant inventory**, **buy from vendor**, split payments, hold/resume, discounts, tax-free toggle |
| Registers | `/registers` | Create registers, open with a float, close with a count + variance |
| Booths | `/booths` | List + create/edit/delete |
| Booth Map | `/booths/map` | Interactive 2D floor map (click/keyboard select) |
| Vendors | `/vendors` | List + create/edit + per-vendor statement + **buy from vendor** |
| Inventory | `/inventory` | Search + create/edit + item detail |
| Reports | `/reports` | Tender mix, vendor payouts, tax collected |
| Settings | `/settings` | Appearance (theme/mode), editable tenant config, role/permission matrix |
| Login | `/login` | Mock sign-in (role switcher) |

### Vendor-mall model

In a vendor mall, items are generally **not in inventory until they are sold**. The register
therefore has no catalog grid. Instead:

- **Instant inventory** (`/pos/quick-add`) creates an item on the fly and drops it straight
  into the cart. Items are **vendor-owned (consignment) by default**; the store can also add
  its own goods (`owner=store`).
- **Buy from vendor** (`/pos/buy`, `/vendors/{id}/purchase`) records a store purchase: it
  creates a **store-owned** item and increases the **vendor payable** by cost × quantity.
- **Store items** are the store-owned goods the store sells directly; they appear as tiles on
  the POS left rail for one-tap add.

### Roles (RBAC)

Role-aware navigation and route gating. Switch roles from the account menu (top-right) or
with `?role=`:

| Role | Access |
|------|--------|
| `owner` | Everything |
| `manager` | Dashboard, POS, Booths, Vendors, Inventory, Reports |
| `accountant` | Dashboard, Vendors, Reports, Accounting |
| `cashier` | Dashboard, POS |

Gated routes render a friendly **403** page when the role lacks permission.

---

## Theming

Themes are **CSS custom properties** on `:root` and `[data-theme="…"][data-mode="…"]`,
so adding a theme is a matter of adding one block of tokens.

- **Themes:** `neutral` (default, indigo accent) and `dark-blue` (secondary).
- **Modes:** `light` and `dark`.
- Persisted in `localStorage` (`nem-theme`, `nem-mode`) and mirrored to the session.
- Switch at runtime from the topbar, from **Settings → Appearance**, or via query string:
  `?theme=dark-blue&mode=dark`.

> **Precedence note.** The layout applies the persisted theme *before paint* from
> `localStorage` to avoid a flash. The Settings form therefore writes `localStorage` on
> submit (and reflects the applied value on load) so the picker and the topbar agree.

The registry lives in `src/Support/Theme.php`; the tokens live in
`public/assets/css/theme.css`.

---

## Architecture

```
apps/tenant-ui/
  public/
    index.php            ← front controller (all requests route here)
    router.php           ← dev-server router (static passthrough + front controller)
    assets/
      css/theme.css      ← design system: tokens, themes, components
      css/app.css        ← app shell + module islands
      js/app.js          ← shell behavior (sidebar, theme, menus, search)
      js/pos.js          ← POS island (integer-cents money)
      js/booth-map.js    ← booth map island
  src/
    Support/             ← View, Router, Auth, Theme, Money, Flash, Nav
    Data/                ← MockRepository + seed.php  (the ONLY data-source-aware layer)
    Http/
      Controller.php     ← base controller (render, redirect, require, input)
      Controllers/       ← Dashboard, Pos, Register, Booth, Vendor, Inventory, Report, Settings, Auth
    Views/
      layout.php         ← app shell (sidebar + topbar + content)
      layout-bare.php    ← login
      partials/          ← icons, sidebar, topbar
      <module>/          ← module views
      errors/            ← 404, 403
```

The shape intentionally mirrors the real application (PSR-7/15 + attribute routing), so the
swap to the production stack is mechanical.

---

## Wiring the real DBAL (ADR-0025)

`src/Data/MockRepository.php` is the **only** class that knows where data comes from. To go
live, replace its method bodies with DBAL calls — **no controller or view changes required**.

1. **Keep the method signatures.** Controllers depend on the interface, not the source.
2. **Money stays strings end-to-end.** Return `NUMERIC(19,4)` values as strings; format only
   at render via `Money::format()`. Never use floats, never use PostgreSQL `money`.
3. **Use the realtime vendor views** for the Vendors module:
   `v_vendor_balance_realtime`, `v_vendor_sales_realtime`, `v_vendor_sales_today`,
   `v_vendor_payout_available`, `v_vendor_statement`.
4. **Tenders** in `PosController::TENDERS` mirror ADR-0029 (cash / check / card→clearing /
   gift certificate / customer store credit / vendor payable draw).
5. **Posting** is idempotent and append-only (reversal-not-edit) per the ledger ADRs; the POS
   `checkout()` endpoint is where a sale would post.

A minimal DBAL adapter would look like:

```php
final class DbalRepository implements Repository
{
    public function __construct(private \PDO $pdo) {}

    public function vendors(): array
    {
        $stmt = $this->pdo->query('SELECT * FROM v_vendor_balance_realtime ORDER BY name');
        return $stmt->fetchAll(\PDO::FETCH_ASSOC);
    }
    // …one method per MockRepository method
}
```

Then bind `Repository` → `DbalRepository` in `public/index.php` and delete the mock.

---

## Verification

- All routes return **200** (404 for unknown paths); no PHP warnings/notices.
- POST endpoints work: `/pos/scan` returns item JSON, `/pos/checkout` returns a receipt,
  `/pos/quick-add` and `/pos/buy` return the created item JSON.
- CRUD verified: inventory create/edit, vendor create/edit, register create/open/close,
  vendor purchase, and tenant settings update all persist (session-backed mock).
- RBAC gating verified (e.g. `cashier` → 403 on `/reports` and `/settings`).
- Screenshots captured for every module in **light and dark** mode.

---

## Related docs

- `../../docs/TENANT_UI_HANDOFF.md` — the build handoff (decisions, build order, progress).
- `../../docs/HANDOFF.md` — locked technical decisions (PHP 8.5, no frameworks, PSR set).
- `../../docs/DECISIONS.md` — ADR-0002 (money), ADR-0020 (posting_map), ADR-0025 (DBAL),
  ADR-0028 (accrual), ADR-0029 (tenders).
- `../../docs/SRS.md` — Parts 3–5 (Vendor Mall, Consignment, POS domains).
