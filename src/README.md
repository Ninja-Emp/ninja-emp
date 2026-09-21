# Ninja EMP — Application Source (`src/`)

The real application layer (Part 6 of the roadmap). **No framework, zero Composer
dependencies** (HANDOFF.md §2). PSR-12, strict types, PHP 8.2+ (target 8.5).

This is the foundation every domain module sits on. It is being built bottom-up:
the **DBAL** first (ADR-0025), then the **ledger engine** (ADR-0020/0028/0029).

## Layout

```
src/
  autoload.php                 ← minimal PSR-4 autoloader (NinjaEMP\ → src/, Psr\Log\ → src/Psr/Log/)
  Money/
    Money.php                  ← exact, string-backed, bcmath. NEVER float (ADR-0002)
    Currency.php               ← ISO-4217 alpha-3 value object
    Exception/CurrencyMismatchException.php
  Db/                          ← the DBAL (ADR-0025)
    Connection.php             ← the contract: select/selectOne/execute/scalar/transactional
    TenantContext.php          ← tenantId / actorId / schema
    PdoConnection.php          ← PDO impl: SET LOCAL context, typed errors, typed values
    ConnectionFactory.php      ← builds pooling-safe PDO connections
    ResultSet.php / Row.php    ← typed result containers
    ErrorMapper.php            ← SQLSTATE → typed exception
    Sql/PlaceholderRewriter.php← quote-aware :name → $n (reuse legal)
    Sql/Identifier.php         ← validate + quote identifiers
    Type/TypeMapper.php        ← numeric→Money, jsonb→array, timestamptz→DateTimeImmutable, …
    Value/Tenant.php           ← immutable TenantContext
    Exception/*.php            ← typed failures
  Ledger/                      ← the ledger engine
    LedgerService.php          ← idempotent post / reverse / account resolution
    JournalEntry.php           ← balanced entry (validated in PHP before the DB)
    JournalLine.php            ← debit XOR credit, subledger tagging
    Tender.php                 ← tender → posting role map (ADR-0029)
  Auth/                        ← authentication & RBAC
    Role.php                   ← role → permission matrix (server-side authority)
    User.php                   ← authenticated principal
    PasswordHasher.php         ← Argon2id/bcrypt hashing (never plaintext)
    Csrf.php                   ← CSRF token generate/validate (constant-time)
    SessionAuth.php            ← session login/logout, fixation-safe
  Tenancy/                     ← schema-per-tenant resolution (ADR-0008)
    TenantRegistry.php         ← control-plane seam (findBySlug / findByHost)
    TenantRecord.php           ← a control.tenant row (validates schema name)
    InMemoryTenantRegistry.php ← test/dev registry
    TenantResolver.php         ← request → TenantContext
  Support/Log/NullLogger.php   ← PSR-3 no-op (swap for Monolog in prod)
  Psr/Log/*.php                ← vendored PSR-3 interfaces (no Composer)
```

## The money rule (the one that matters)

`NUMERIC(19,4)` comes back from PDO as a **string**. `Money` preserves that exact
string and does all arithmetic through `bcmath`. There is no code path that turns
money into a `float`. `Money::fromDatabase()` throws if handed a float — that
throw means someone bypassed the DBAL.

## The DBAL contract (ADR-0025)

- **Named parameters** in the public API; rewritten to positional `$n` internally
  so reuse is legal. The scanner is quote-aware (ignores `:x` in string literals,
  dollar-quotes, comments, and `::` casts).
- **`transactional()` is the only way to run tenant-scoped work.** `SET LOCAL
  search_path` / `app.tenant_id` / `app.actor_id` require a transaction, so a bare
  `select()` throws `TransactionRequiredException`.
- **Emulated prepares by default** (PgBouncer transaction-mode safe).
- **Typed errors**: `23514`→`ConstraintViolationException` (ledger balance →
  `LedgerBalanceException`), `23503`→`ReferenceException`, `23505`→`ConflictException`,
  `55000`→`AppendOnlyViolationException`, `40001`→`RetryableException`.
- **Nested `transactional()` joins the outer transaction** — no partial commits.

## Ledger engine

`LedgerService::post(JournalEntry)` resolves each line's posting role through
`posting_map` (ADR-0020), serialises the lines to jsonb, and calls the database's
`post_journal_entry()` — which is idempotent on `idempotency_key`. `reverse()`
posts a mirror entry; the original is never edited.

## Auth & tenancy

`Auth\Role` holds the permission matrix (the enforcement point; the UI gates for
UX only). `SessionAuth` stores only id/role/tenant in the session and regenerates
the session id on login. `Csrf` issues a 32-byte token validated with
`hash_equals`. `Tenancy\TenantResolver` maps a request (slug, then host) to a
`TenantContext`, rejecting suspended/unknown tenants and unsafe schema names.

## Running the tests

```bash
php tests/run.php
```

118 assertions, zero dependencies. The functional DBAL tests auto-skip unless a
live database is configured:

```bash
NINJA_EMP_DSN="pgsql:host=127.0.0.1;dbname=ninja_emp" \
NINJA_EMP_USER=ninja_app NINJA_EMP_PASSWORD=... \
NINJA_EMP_TENANT_ID=11111111-1111-7111-8111-111111111111 \
NINJA_EMP_SCHEMA=tenant_demo \
php tests/run.php
```

## What's next

Per `docs/ROADMAP.md` Part 6: feature modules + service contracts, routing +
middleware + auth, the vendor portal UI (the realtime views already exist), the
OpenAPI 3.1 surface, and the quality gate (PHP-CS-Fixer, PHPStan L10, PHPMD,
Deptrac, mutation MSI ≥ 80%).
