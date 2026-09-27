# Ninja EMP — Database (DB-first foundation)

PostgreSQL **18** (verified on 18.6). **Two databases** (ADR-0008): `ninja_control` (control plane) + `ninja_emp` (kernel + tenant schemas). Schema-per-tenant (ADR-0002); shared `kernel` schema holds domains, helpers, and global reference data.

## Layout
| File | Scope | Purpose |
|------|-------|---------|
| `00_bootstrap.sql` | once/db (`ninja_control`) | Control plane: tenant registry (`control` schema) |
| `00_kernel.sql` | once/db (`ninja_emp`) | Extensions (into `kernel`), domains, helper fns, global reference data |
| `01_guard.sql` | once/db (`ninja_emp`) | Append-only guard functions + event triggers (TRUNCATE, `DISABLE`/`DROP`, replica mode) |
| `99_roles.sql` | cluster | `ninja_app` (NOBYPASSRLS) + `ninja_migrator` (BYPASSRLS) |
| `05_audit.sql` | per-tenant | Append-only `audit_log` + row-history triggers (ADR-0017) |
| `10_party.sql` | per-tenant | Party Model + PII encryption/masking (ADR-0018) |
| `20_money.sql` | per-tenant | Currency, FX, tenant config |
| `30_ledger.sql` | per-tenant | **Ledger core** (CoA, journal, invariants, posting API, `posting_map`) |
| `35_coa_seed.sql` | per-tenant | Standard mall chart of accounts + `posting_map` seed (ADR-0020) |
| `36_tenant_seed.sql` | per-tenant | Fiscal calendar generator (`ensure_fiscal_calendar`) |
| `37_coa_consignment.sql` | per-tenant | Consignment CoA additions (consignor payable control, commission revenue, consignment COGS) + posting roles |
| `38_coa_pos.sql` | per-tenant | POS CoA additions (undeposited funds, card clearing, merchant fees, cash over/short) + posting roles |
| `40_subledger.sql` | per-tenant | Subledger views + control-account tie-out |
| `45_openitem.sql` | per-tenant | **Open-item AR/AP** (ADR-0023): `open_item`, `payment_application`, FIFO `apply_payment()`, aging + control tie-out |
| `50_vendormall.sql` | per-tenant | **Vendor Mall domain** (location→floor→space, waitlist, lease, rent, deposit, delinquency) |
| `55_vendormall_posting.sql` | per-tenant | Rent invoice + deposit posting (idempotent, `posting_map`-driven); opens AR open items |
| `60_consignment.sql` | per-tenant | **Consignment domain** (agreement, commission rules, items, sales, settlements, payouts) |
| `65_consignment_posting.sql` | per-tenant | Consignment sale + consignor payout posting (idempotent); opens/settles AP open items |
| `70_pos.sql` | per-tenant | **POS domain** (tender types, tax, register/shift, sale/line, payment/tender, merchant settlement) |
| `75_pos_posting.sql` | per-tenant | `post_sale` / `post_refund` / `post_shift_close` / `post_merchant_settlement` (idempotent) |
| `80_vendor_portal.sql` | per-tenant | **Realtime vendor portal** views + `vendor_portal_check()` tie-out |
| `90_rls.sql` | per-tenant | RLS defense-in-depth (journal tables excluded — ADR-0007) |
| `98_append_only_guard.sql` | per-tenant | Arms the append-only guards: `ENABLE ALWAYS` triggers, TRUNCATE guards, `DISABLE`/`DROP` event triggers |
| `tests/invariants.sql` | per-tenant | Proves the accounting + enterprise-data invariants on real PG |
| `tests/vendormall.sql` | per-tenant | Vendor Mall domain + ledger integration |
| `tests/partition.sql` | per-tenant | Proves the journal design is partition-ready (ADR-0019) |
| `tests/consignment.sql` | per-tenant | Consignment domain + ledger integration |
| `tests/pos.sql` | per-tenant | POS, tenders, tax, refunds, drawer, merchant fees, realtime portal |
| `tests/rls_benchmark.sql` | per-tenant | Measures RLS cost on the hot journal path |
| `tests/append_only_guard.sql` | per-tenant | Proves the append-only guards survive replica mode, TRUNCATE, and `DISABLE`/`DROP` |
| `tests/run-race.sh` + `tests/race/*.sql` | per-tenant | **Concurrency (race) proof harness** — two sessions per scenario (counter/period/account/key) |
| `migrations/0008_posting_serialization.sql` | per-tenant | Posting serialization, lock order, posting seal, singleton config, IANA timezone |

## Run
```bash
bash db/provision.sh tenant_demo          # build from scratch (destructive)
bash scripts/run_tests.sh                 # every SQL suite + the race harness
bash scripts/run_tests.sh close pos       # only named SQL suites
bash db/tests/run-race.sh tenant_demo     # the concurrency proof harness alone
```
All SQL suites are **idempotent** (safe to re-run against a live tenant). The race
harness runs two concurrent `psql` sessions per scenario and is a hard gate: if
session B returns without waiting on session A's lock, the run is red.

## Test results (all green, re-runnable)
| Suite | Assertions | Result |
|-------|-----------|--------|
| `invariants.sql` | 28 | **28/28 PASS** |
| `consignment.sql` | 12 | **12/12 PASS** |
| `vendormall.sql` | 20 | **20/20 PASS** |
| `pos.sql` | 27 | **27/27 PASS** |
| `partition.sql` | 6 | **6/6 PASS** |
| `close.sql` | 23 | **23/23 PASS** |
| `inventory.sql` | 30 | **30/30 PASS** |
| `tax1099.sql` | 19 | **19/19 PASS** |
| `lease.sql` | 20 | **20/20 PASS** |
| `retail.sql` | 37 | **37/37 PASS** |
| `settlement.sql` | 19 | **19/19 PASS** |
| `append_only_guard.sql` | 10 | **10/10 PASS** |
| `run-race.sh` (counter/period/account/key) | 4 | **4/4 RACE_OK** |

**Concurrency proven (ported from the sibling kernel):** postings serialize on the tenant
`journal_counter` — the hash chain can no longer race two posters to the same predecessor ·
the posting lock order is total and identical for every poster (counter → period → account), so a
deadlock is impossible by construction · a `journal_entry` is sealed to its posting transaction
(`posting_xid`), so a line cannot be appended after it is posted · `tenant_config` is a true
singleton · `timezone` columns are validated IANA names.

**Invariants proven:** trial balance = 0 · unbalanced entry rejected · append-only enforced ·
reversal nets to zero · idempotent posting · period lock · subledger↔control account ·
subledger ties to GL · debit XOR credit · RLS isolation · migrator BYPASSRLS ·
RESTRICT on financial FKs · optimistic locking (`version`) · PII encrypted at rest + masked ·
`posting_map` account determination.

**Vendor Mall proven:** active lease visible · unique active lease per space · rent components
total · rent entry balances · AR subledger ties to control · rent invoice idempotent ·
deposit held + linked + ties · delinquency snapshot · AR open item opened · payment settles
open items and ties to control · aging buckets · trial balance = 0.

**Open-item AR/AP proven:** invoice opens an open item · FIFO payment application ·
open items tie to the GL control account · aging buckets (0-30/31-60/61-90/90+) · idempotent.

**Consignment proven:** agreement + non-overlapping commission rules · item intake ·
exact commission split (commission + net = sale price) · sale posting balances + ties to
consignor payable control · idempotent sale posting · settlement + payout settle open items ·
trial balance = 0.

**POS & Payments proven:** tender types (card = clearing, not cash) · liability tender requires a
subledger · sale totals invariant · split tenders sum to total · sale entry balances · sales tax to
tax payable · **consignor payable accrued AT SALE** · idempotent posting · **realtime portal = GL
control** · refund balances and reverses the accrual · refund relieves open items · original entry
untouched · drawer over/short · merchant fee expensed (not netted) · clearing released ·
trial balance = 0.

**Partition-readiness proven:** balanced partitioned entry accepted · unbalanced rejected ·
partition pruning · entries land in the correct year partition.

## Key decisions applied
- **ADR-0006:** `journal_line.id` is `bigint` identity (highest-volume table).
- **ADR-0007:** RLS measured ~3× on the hot journal path → disabled on `journal_entry`/`journal_line`; kept elsewhere. `ninja_migrator` has `BYPASSRLS`.
- **ADR-0008:** control plane is a separate database.
- **ADR-0015:** enterprise data standards are normative (`docs/DATA_STANDARDS.md`).
- **ADR-0016:** financial/master FKs use `ON DELETE RESTRICT` (corrects round-1 CASCADE).
- **ADR-0017:** audit columns + optimistic locking + soft delete are mandatory on mutable tables.
- **ADR-0018 / ADR-0027:** PII classified, encrypted at rest (`pgcrypto`), masked in views; envelope encryption (KMS master key wraps per-tenant data key).
- **ADR-0019 / ADR-0026:** journal is partition-ready (range by `entry_date`); partition-enable threshold = 20M `journal_line` rows/tenant.
- **ADR-0020:** account determination via `posting_map`; domain code never hard-codes account codes.
- **ADR-0021:** effective-dated rows must not overlap (GiST exclusion constraints).
- **ADR-0022:** accrual is the book of record; cash basis is a DERIVED report from open items.
- **ADR-0023:** open-item AR/AP (invoice↔payment matching) drives aging + cash-basis conversion.
- **ADR-0028:** consignor/vendor liability accrues **at sale** → realtime vendor portal reads the live ledger.
- **ADR-0029:** split tenders; card → clearing (not cash); merchant fees expensed; drawer over/short.
- `uuidv7()` is native in PG 18 (no extension).
