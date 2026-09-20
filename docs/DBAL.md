# Ninja EMP — DBAL Contract (ADR-0011)

**Status:** PROPOSED (needs your sign-off) · **Scope:** the thin, owned data-access layer every domain module depends on.

> This is not an ORM. It is a small, explicit contract over PDO that makes the
> dangerous parts (money typing, tenant context, transactions, pooling) impossible
> to get wrong by accident. It is a bounded context with its own test suite.

---

## 1. Why this exists (the risk)
A hand-rolled DBAL is where bugs that **lose money** live. The specific hazards:
1. **`numeric` → PHP `string`.** PDO returns `NUMERIC` as a **string**, not float. If any code casts money to `float`, we lose exactness. The DBAL must hand back a `Money` value object, never a raw float.
2. **Named-parameter reuse.** PDO named params **cannot be reused** in one statement (`:x` twice fails). The DBAL must rewrite/expand them deterministically.
3. **Tenant context.** `SET LOCAL search_path` and `SET LOCAL app.tenant_id` must be issued **inside** every transaction, or RLS/`search_path` silently misbehave.
4. **Pooling.** PgBouncer transaction mode breaks server-side prepared statements unless configured (ADR-0010).
5. **Unit of work.** A shared connection resolved twice must be the *same* object (this is exactly the container Defect 2 from §10 of the handoff).

---

## 2. Non-goals
- No query builder, no ORM, no lazy-loading, no identity map.
- No schema introspection at runtime.
- No magic. SQL is written by hand and visible.

---

## 3. Core interfaces (PHP 8.5, strict types)

```php
namespace NinjaEMP\Db;

interface Connection
{
    /** Run a SELECT; returns rows as associative arrays with typed values. */
    public function select(string $sql, array $params = []): ResultSet;

    /** Run a SELECT returning exactly one row (or throw). */
    public function selectOne(string $sql, array $params = []): Row;

    /** Run an INSERT/UPDATE/DELETE; returns affected row count. */
    public function execute(string $sql, array $params = []): int;

    /** Call a function returning a scalar (e.g. post_journal_entry). */
    public function scalar(string $sql, array $params = []): mixed;

    /** Run a closure inside a transaction; commits on return, rolls back on throw. */
    public function transactional(callable $work): mixed;

    public function lastInsertId(): string;
}

interface TenantContext
{
    public function tenantId(): string;   // uuid
    public function actorId(): ?string;   // uuid
    public function schema(): string;     // e.g. tenant_acme
}
```

---

## 4. Connection & pooling (ADR-0010)
- **PgBouncer transaction mode.** The DBAL sets, at the start of every transaction:
  ```sql
  SET LOCAL search_path = <tenant_schema>, kernel;
  SET LOCAL app.tenant_id = '<uuid>';
  SET LOCAL app.actor_id = '<uuid>';
  ```
  `SET LOCAL` is transaction-scoped, so it is safe under transaction pooling and cannot leak across tenants.
- **Prepared statements — explicit choice (do not leave implicit):**
  - **Default: `PDO::ATTR_EMULATE_PREPARES = true`.** Client-side prepares are safe under transaction pooling and avoid the `max_prepared_statements` trap. Cost: no server-side plan caching.
  - **Opt-in native prepares** only when PgBouncer ≥ 1.21 is configured with `max_prepared_statements` and the pool is dedicated. The DBAL exposes a per-connection flag; the default is emulated.
- **`SET LOCAL` requires a transaction.** Therefore `transactional()` is the **only** way to run tenant-scoped work. A bare `select()` outside a transaction is a programming error and throws.

---

## 5. Named parameters
- Public API uses **named parameters** (`:name`), per the locked decision.
- The DBAL rewrites each `:name` to a unique positional placeholder (`$1`, `$2`, …) and builds the ordered bind array. This makes **reuse legal** (`:x` may appear many times) and removes PDO's reuse limitation.
- Placeholder parsing is quote-aware (ignores `:x` inside string literals and `::` casts).
- **Rule:** never interpolate values into SQL. Identifiers (schema/table names) are validated against `^[a-z_][a-z0-9_]*$` and quoted with `"`.

---

## 6. Type mapping (the money-critical part)
| PG type | PHP type | Notes |
|---|---|---|
| `numeric` / `money_amount` | `NinjaEMP\Money\Money` (string-backed) | **Never float.** Constructed from the exact string PDO returns. |
| `char(3)` currency | `NinjaEMP\Money\Currency` | Validated ISO-4217. |
| `uuid` | `string` | Lowercase canonical. |
| `bigint` | `int` (or string if > PHP_INT_MAX) | |
| `timestamptz` | `DateTimeImmutable` (UTC) | |
| `date` | `DateTimeImmutable` (00:00 UTC) | |
| `boolean` | `bool` | |
| `jsonb` | `array` | Decoded. |

**Money rule:** `Money` stores the amount as a **string** at scale 4 and does arithmetic via `bcmath` (or a decimal lib) — never `float`. Any operation that would exceed scale 4 must go through the **largest-remainder allocator** (ADR-0009) and emit an explicit adjustment line.

---

## 7. Unit of Work & transactions
- One `Connection` per request, resolved as a **singleton** (container Defect 2 fix).
- `transactional(callable)`:
  1. `BEGIN`
  2. issue `SET LOCAL` for tenant/actor/search_path
  3. run the closure
  4. `COMMIT` on success, `ROLLBACK` on any `Throwable`
- **Nested calls** join the outer transaction (savepoints optional, off by default) — no accidental partial commits.
- The ledger's deferred balance trigger fires at `COMMIT`; the DBAL surfaces that failure as a typed `LedgerBalanceException`.

---

## 8. Error mapping
| SQLSTATE | Exception |
|---|---|
| `23514` check_violation | `ConstraintViolationException` (incl. unbalanced entry, period lock) |
| `23503` foreign_key_violation | `ReferenceException` |
| `23505` unique_violation | `ConflictException` (incl. idempotency) |
| `55000` object_not_in_prerequisite_state | `AppendOnlyViolationException` |
| `40001` serialization_failure | `RetryableException` (caller retries) |

The DBAL never swallows errors. Every failure is typed and logged (PSR-3).

---

## 9. Idempotent posting through the DBAL
```php
$entryId = $db->transactional(fn () => $db->scalar(
    'SELECT post_journal_entry(:date, :memo, :source, :ref, :key, :lines)',
    [
        'date'  => $date,
        'memo'  => $memo,
        'source'=> 'pos',
        'ref'   => $saleId,
        'key'   => $idempotencyKey,      // same key => same entry id
        'lines' => json_encode($lines),  // jsonb
    ]
));
```
Retrying with the same `:key` returns the same `entry_id` — proven by invariant T2.

---

## 10. Test strategy for the DBAL (it is a bounded context)
- **Unit:** placeholder rewriter (quote-aware, reuse, `::` casts), type mapper (numeric→Money, no float), identifier validator.
- **Functional (real PG):** `SET LOCAL` isolation across pooled connections; transaction rollback; deferred-trigger error surfacing; idempotency; RLS interaction.
- **Mutation:** the rewriter and type mapper are prime mutation targets — MSI gate applies.

---

## 11. Open questions for you
1. **Decimal arithmetic:** `bcmath` (bundled) vs a decimal library? I lean `bcmath` (zero deps, we own it).
2. **Savepoints:** support nested transactions via savepoints, or forbid nesting? I lean **forbid** (simpler, fewer footguns).
3. **Native prepares:** default emulated (my recommendation) or invest in `max_prepared_statements` now?
