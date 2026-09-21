# Ninja EMP — Grandma-Friendly Vendor Portal UI

A warm, accessible, plain-language **vendor portal** for the Ninja EMP mall + consignment
platform. This is the Part 6 "Vendor portal UI" + "map island" from `docs/ROADMAP.md`,
delivered as a dependency-free static prototype that maps 1:1 to the realtime ledger views
(`v_vendor_balance_realtime`, `v_vendor_sales_today`, `v_vendor_payout_available`,
`v_vendor_statement`) and the physical-inventory tables (`location` → `floor` → `space`).

## Why "grandma-friendly"?

Many mall vendors and consignors are older small-business owners. The design assumes the
reader may be a first-time computer user, may have low vision, and may be nervous about
"the computer." Every choice follows from that:

- **Big type.** 20px base, up to 64px for the headline money numbers. A one-press
  **Bigger Text** toggle scales the whole page and remembers the choice.
- **Plain language.** No accounting jargon. "The mall owes you," not "consignor payable
  subledger balance." "What sold," not "sales journal."
- **Huge touch targets.** Buttons are at least 64px tall; nav items are pill-shaped and
  generous.
- **High contrast.** Warm near-black ink on cream paper (≈13.5:1), WCAG AA+ throughout.
- **Read aloud.** A **Read This Page** button uses the browser's speech synthesis to read
  the page in a calm, slightly slowed voice.
- **Reassurance everywhere.** Friendly notices ("Your booth rent is all paid up"), a big
  phone number, and a plain-language FAQ.
- **Legible font.** [Atkinson Hyperlegible](https://www.brailleinstitute.org/freefont/),
  designed by the Braille Institute for low-vision readers.

## Pages

| File | What it is | Backed by |
|------|------------|-----------|
| `index.html` | Home — today's earnings, money owed, quick facts | `v_vendor_sales_today`, `v_vendor_balance_realtime` |
| `sales.html` | "What Sold Today" — every item, with the commission split | `v_vendor_sales_realtime` |
| `money.html` | "My Money" — payout available + plain-language history | `v_vendor_payout_available`, `v_vendor_statement` |
| `space.html` | "My Booth" — interactive mall floor plan (map island) | `location`/`floor`/`space` |
| `help.html` | "Need Help?" — plain-language FAQ + big phone number | — |

## Structure

```
ui/
  index.html      Home / dashboard
  sales.html      What sold today
  money.html      My money
  space.html      My booth + floor plan
  help.html       Need help?
  css/styles.css  Design system (warm palette, large type, print + reduced-motion)
  js/app.js       Bigger Text + Read Aloud toggles, nav highlighting, money formatting
  js/map.js       Map island — click/keyboard a booth to see its details
```

## Accessibility notes

- Skip link, semantic landmarks (`header`/`nav`/`main`/`footer`), and a polite live region
  for screen-reader announcements.
- The floor plan is a real SVG with `role="button"`, `tabindex`, and `aria-label` on every
  booth — fully keyboard operable (Tab to move, Enter/Space to select).
- Visible 4px focus rings; `prefers-reduced-motion` disables all animation.
- Print stylesheet strips chrome so a vendor can print a clean statement.

## Running it

It is plain static HTML/CSS/JS — no build step. Open `index.html` directly, or serve it:

```bash
cd ui
python3 -m http.server 8090
# then visit http://localhost:8090/
```

## Wiring it to the real app (Part 6)

This prototype is intentionally data-light. In the real application layer:

1. The **DBAL** (ADR-0025) issues `SET LOCAL search_path = <tenant>, kernel` per transaction.
2. A thin controller reads the `v_vendor_*` views for the signed-in vendor's `party_id`.
3. The templates here become the server-rendered views; `js/map.js` stays a single island
   fed by the `space` table instead of the inline `BOOTHS` object.
4. Money is passed as **strings** (bcmath) and formatted for display only — never floated.
