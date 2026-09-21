# Ninja EMP — Application Layer (Part 6)

DB is complete (222 assertions, 10 suites). Now building the PHP application layer.
Immediate focus: **Part 6, step 1 — the DBAL (ADR-0025)**, then **step 2 — the ledger engine**.

## A. DBAL (ADR-0025) — `src/Db/`
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

## B. Ledger engine (ADR-0020/0028/0029) — `src/Ledger/`
- [x] LedgerService: idempotent post via `post_journal_entry`
- [x] Account determination via `posting_map` (`posting_account`)
- [x] Reversal via `reverse_journal_entry`
- [x] Tender → posting map (ADR-0029)
- [x] Unit tests (line building, balance check, idempotency key)

## C. Verify + ship
- [x] Run unit tests green (83 assertions)
- [x] Update ROADMAP + handoff docs
- [x] Commit + push to feat/tenant-ui
