# Ninja EMP — API

> **Document root:** `apps/api/public` · **Default port:** `8092` ·
> **Serve:** `php bin/ninja serve-api` (from the repo root).

The **API-first HTTP surface** for Ninja EMP: a small, framework-free PSR-7/PSR-15
application that exposes the platform's JSON endpoints and its OpenAPI 3.1 contract.

## Endpoints

| Route | What it is |
|-------|------------|
| `GET /api/health` | Liveness/readiness probe |
| `GET /api/openapi.json` | The OpenAPI 3.1 contract (machine-readable) |
| `GET /api/docs` | Human-readable API docs |
| `GET /api/me` | The authenticated principal (401 when unauthenticated) |
| `GET /api/reporting/...` | Reporting endpoints |
| `POST /api/shifts/...` | Shift open/close |
| `POST /api/stored-value/...` | Stored-value (gift certificate / store credit) operations |
| `GET /api/vendors/...` | Vendor reads |

## Layout

```
apps/api/
  public/
    index.php            ← front controller (all requests route here)
    router.php           ← dev-server router (static passthrough + front controller)
  src/
    Container.php        ← PSR-11 service container wiring
    Http/Controllers/    ← one controller per resource
```

## Running it

From the repository root:

```bash
php bin/ninja serve-api      # API only, on http://127.0.0.1:8092
php bin/ninja serve          # API + Tenant UI together
```

Then:

```bash
curl http://127.0.0.1:8092/api/health
curl http://127.0.0.1:8092/api/openapi.json
```

## Related docs

- `../../docs/HANDOFF.md` — locked technical decisions (PHP 8.5, no frameworks, PSR set).
- `../../docs/DECISIONS.md` — ADR-0025 (DBAL), ADR-0029 (tenders), and the ledger ADRs.
- `../../docs/DBAL.md` — the database abstraction layer design.
