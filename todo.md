# Ninja EMP — Application Layer (Part 6)

DB is complete (222 assertions, 10 suites). PHP application layer underway.
Delivered: DBAL (6.1), ledger engine (6.2), auth & tenancy (6.3). 118 unit assertions green.

## A. DBAL (ADR-0025) — `src/Db/` — ✅
- [x] Money value object (string-backed, bcmath) + Currency (ISO-4217)
- [x] Core interfaces: Connection, TenantContext
- [x] ResultSet + Row (typed values)
- [x] PlaceholderRewriter (quote-aware named → positional, reuse legal, `::` casts)
- [x] Identifier validator (`^[a-z_][a-z0-9_]*$`, quoted)
- [x] TypeMapper (numeric→Money, uuid→string, timestamptz→DateTimeImmutable, jsonb→array, …)
- [x] Typed exceptions + SQLSTATE error mapping
- [x] PdoConnection (SET LOCAL tenant context, transactional, emulated prepares)
- [x] ConnectionFactory (DSN, pooling flags)
- [x] Unit tests (rewriter, type mapper, identifier, money)

## B. Ledger engine (ADR-0020/0028/0029) — `src/Ledger/` — ✅
- [x] LedgerService: idempotent post via `post_journal_entry`
- [x] Account determination via `posting_map` (`posting_account`)
- [x] Reversal via `reverse_journal_entry`
- [x] Tender → posting map (ADR-0029)
- [x] Unit tests (line building, balance check, idempotency key)

## C. Auth & tenancy — `src/Auth/`, `src/Tenancy/` — ✅
- [x] Role permission matrix (server-side enforcement)
- [x] PasswordHasher (Argon2id/bcrypt), Csrf (constant-time), SessionAuth (fixation-safe)
- [x] TenantRegistry / TenantRecord / TenantResolver (schema-per-tenant)
- [x] Unit tests

## D. Verify + ship — ✅
- [x] Run unit tests green (118 assertions)
- [x] Update ROADMAP + handoff docs + src/README
- [x] Commit + push to feat/tenant-ui (5583120, bba948d)

## E. Repository layer (swap the mock) — `src/Repository/` — ⏳
- [x] `Repository` interface (mirrors MockRepository signatures exactly)
- [x] `DbalRepository` — real SQL against the normalized schema
- [x] Pure row-mappers (space/vendor/item/register/sale) — unit-testable
- [x] `FakeConnection` test double + `RepositoryTest`
- [ ] Domain services on top (Vendor Mall, Consignment, POS, Inventory)

## F. Routing + middleware — ⏳
- [ ] Wire SessionAuth + TenantResolver into the front controller
- [ ] Attribute-based routing (PSR-15 middleware)

## G. OpenAPI 3.1 surface — ⏳
- [ ] Machine-readable contract for the API-first surface

## H. Quality gate — ⏳
- [ ] PHP-CS-Fixer, PHPStan L10, PHPMD, Deptrac, mutation MSI ≥ 80%

## Notes
- No live PostgreSQL in this sandbox: functional DBAL tests auto-skip; repository
  SQL is written against the verified schema and unit-tested via a fake Connection.
- Push often to feat/tenant-ui.
