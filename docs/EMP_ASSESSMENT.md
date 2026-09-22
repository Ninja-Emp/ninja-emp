# EMP Assessment — Independent Review vs. Ninja EMP

**Reviewer:** SuperNinja (autonomous agent)
**Date:** 2026-09-21 (revised after pulling latest Ninja EMP)
**Subject:** `github.com/benanamen/emp` (EMP) — read-only forensic review
**Constraint honored:** No EMP code was modified. Clone was read-only at `/tmp/emp_review`.
**Purpose:** Give an honest opinion of EMP's current state, and state precisely what is *better* and what is *worse* than Ninja EMP.

> **Revision note.** The first version of this report compared EMP against Ninja EMP at commit
> `57cf0c4` (database only). Ninja EMP has since advanced **15 commits** — it now has a **PHP
> application layer** (Part 6), a **tenant back-office UI**, and a **vendor portal UI**. That
> materially changes the comparison, and this revision reflects the current state. The EMP side is
> unchanged.

---

## 0. Method & Evidence Base

EMP was cloned read-only and inspected at the file level. Ninja EMP was pulled fresh from
`origin/main` (commit `9b35bfd`, "Merge pull request #1 … grandma-friendly-vendor-ui"). Every claim
below is backed by a grep/read of the actual repository, not by inference. Verified metrics:

| Metric | EMP | Ninja EMP (current) |
|---|---|---|
| SQL functions | **13** | 344 (incl. helpers) |
| SQL triggers | **6** | 331 |
| SQL LOC | **3,112** | **12,020** |
| Application LOC | **129,617 TS/TSX** | **~16,100 PHP** (src 9,010 + tenant-ui 5,201 + tests 1,935) |
| Application language | TypeScript / NestJS / React | **PHP 8.5, no framework** |
| Tenant migrations | 64 | 45 modules + 6 migrations |
| Open-item layer (`open_item`/`payment_application`) | **absent** | present (`db/45_openitem.sql`) |
| Row-Level Security | **absent** | present (`db/90_rls.sql`) |
| Account determination | **hard-coded in TS** (`account-codes.ts`) | `posting_map` role→account (`db/00_kernel.sql`) |
| Journal hash chain | **present** (`prev_hash`/`entry_hash`) | **absent** |
| Money representation | **bigint minor units** | `NUMERIC(19,4)` + bcmath string `Money` object |
| UI | React SPA | **server-rendered PHP templates** (tenant + vendor) |

The headline is now even starker than before. **EMP puts ~98% of its logic in TypeScript and ~2% in
SQL. Ninja EMP puts its accounting logic in SQL *and* its application logic in PHP** — both
languages a 30-year PHP/SQL master reads fluently. EMP's application layer is in a stack its owner
explicitly cannot read.

---

## 1. What EMP Got Genuinely Right (Strengths Worth Stealing)

I want to be fair. EMP is not a bad system — it is a *well-engineered system built on the wrong
axis for this owner*. Several of its ideas are better than Ninja EMP's and should be adopted.

### 1.1 Hash-chained journal (EMP is better — Ninja EMP should adopt this)

`migrations/tenant/002_ledger_kernel.sql` gives every journal a `prev_hash char(64)` and a
`entry_hash char(64) NOT NULL`, with:

```sql
CONSTRAINT journals_entry_hash_key UNIQUE (book_id, entry_hash),
CREATE UNIQUE INDEX journals_prev_hash_key ON journals (book_id, prev_hash) WHERE prev_hash IS NOT NULL,
CREATE UNIQUE INDEX journals_genesis_key ON journals (book_id) WHERE prev_hash IS NULL;
```

This is a **tamper-evident ledger**. Each entry commits to its predecessor, so any retroactive
edit or deletion breaks the chain and is detectable. Ninja EMP has append-only triggers and
reversal-not-edit, but it has **no cryptographic chain** — a sufficiently privileged actor could
still rewrite history undetectably. For a system whose entire value proposition is "world-class
double-entry accounting," this is a real gap. **Recommendation: port the hash chain into Ninja EMP.**

### 1.2 Money as bigint minor units (EMP is better)

`libs/money/src/money.ts` + `allocate.ts` represent money as `bigint` minor units with
`RoundingMode.HalfEven` and a penny-safe `allocateMinor()` that distributes remainders by
largest-remainder so the parts always sum to the whole. This is textbook-correct and eliminates
an entire class of floating/rounding bugs.

Ninja EMP has since added a `Money` value object (`src/Money/Money.php`) that is **string-backed
with bcmath**, scale 4, and *refuses to accept a float* — which is a strong improvement and closes
most of the gap. But it still stores `NUMERIC(19,4)` in the database, which permits sub-cent values
to exist in the ledger. EMP's minor-unit discipline is stricter. **Recommendation: keep the bcmath
`Money` object, but consider enforcing a scale CHECK so no sub-cent amount can ever be posted.**

### 1.3 Reversal as document status (EMP is structurally immune to Ninja EMP's F1 bug)

EMP's `010_rent_receipt_reversals.sql` models a reversal as a **document state change plus a
linked reversing journal**:

```sql
ADD COLUMN status varchar(16) NOT NULL DEFAULT 'completed',
ADD COLUMN reversal_journal_id uuid REFERENCES journals (journal_id);
ADD CONSTRAINT rent_receipts_void_requires_reversal CHECK (
    (status = 'completed' AND reversal_journal_id IS NULL)
    OR (status = 'reversed' AND reversal_journal_id IS NOT NULL));
```

The CHECK makes it **impossible** to have a reversed document without a reversing journal, or a
completed document with one. This is exactly the discipline Ninja EMP is missing. In Ninja EMP,
`reverse_journal_entry()` mirrors the GL lines but **never touches `open_item` or
`payment_application`** — so reversing a payment leaves the subledger asserting the invoice is
still paid (defect F1, reproduced live, and **still present** in the current code). EMP's design
cannot express that bug because the document's own status is the source of truth and the CHECK ties
it to the journal. **This is the single most important lesson to carry over.**

### 1.4 Deferred balance constraint + append-only triggers (EMP is solid, Ninja EMP is comparable)

EMP enforces balance with a `DEFERRABLE INITIALLY DEFERRED` constraint trigger
(`emp_assert_journal_balanced`) plus a `journals_balanced_chk` CHECK on the header, and blocks
mutation with `emp_block_ledger_mutation()` on both journals and lines. Ninja EMP does the same
class of thing (DB-enforced balance, append-only). **Roughly a tie — both are correct here.**

### 1.5 Period no-overlap trigger (EMP is solid)

EMP's `accounting_periods` uses an open/soft_closed/hard_closed model with a no-overlap trigger.
Ninja EMP has period locking too. **Comparable.**

---

## 2. What EMP Got Wrong (Weaknesses — and Why They Matter Here)

### 2.1 No open-item layer at all — this is the PC failure mode, reincarnated

This is the finding that matters most given the owner's history. EMP has **no `open_item`, no
`payment_application`, no `open_amount` anywhere in the codebase** (verified: grep returns zero
hits across all `.sql` and `.ts`). `rent_charges` has a `journal_id`; `rent_receipts` has a
`party_id` and a `journal_id`; **there is no link between a receipt and the charge it pays.**
Settlement is a *running balance* per party, not an open-item ledger.

The owner's own words: *"I believe the PC fifo problem was payment allocation. It was a giant
cluster fuck."* EMP did not solve that problem — **it deleted the problem by deleting the
feature.** A running balance cannot tell you *which* invoice a payment settled, cannot produce an
aged-AR report, cannot support partial payments against specific invoices, and cannot answer
"what is still owed on invoice #1234?" That is not a simplification; it is a capability
regression. Ninja EMP's `open_item` + `payment_application` layer is the correct architecture,
and EMP's absence of it is a **downgrade**, not a lesson.

### 2.2 No Row-Level Security — isolation is schema-only

EMP isolates tenants by `SET LOCAL search_path TO <schema>, public` in
`apps/api/src/tenancy/tenant-service.ts`. There are **no RLS policies anywhere** (verified: zero
`ENABLE ROW LEVEL SECURITY` / `CREATE POLICY` hits). This means isolation depends entirely on
every query path correctly setting `search_path` — one missed `SET LOCAL`, one connection-pool
leak, one raw query, and a tenant reads another tenant's data. Ninja EMP uses `FORCE ROW LEVEL
SECURITY` with policies as a **defense-in-depth backstop** that holds even if application code is
wrong. **EMP is worse here, and it is a security-grade difference.**

### 2.3 Hard-coded account codes in TypeScript

`apps/api/src/ledger/account-codes.ts` hard-codes the chart of accounts:

```ts
export const ACCOUNT = { cash: '1000', rentReceivable: '1300', holderPayable: '2000', ... }
```

This directly violates Ninja EMP's ADR-0020: account determination must go through
`posting_map` (role_code → account_id) resolved by `posting_account(role)`, never by hard-coded
codes. Hard-coding means a tenant cannot remap their chart of accounts, a renumbering breaks
every posting site, and the mapping is invisible to the database. **EMP is worse.**

### 2.4 Business logic lives in TypeScript, not the database

EMP has **13 SQL functions and 6 triggers** across 3,112 SQL LOC, against **129,617 LOC of
TypeScript**. The accounting invariants — balance, append-only, reversal linkage — are in SQL
(good), but the *business* logic (posting, settlement, payouts, returns) is in TS. This is the
decisive problem, and it is not an accounting problem — it is a **maintainability** problem.

---

## 3. The Decisive Verdict: Maintainability

The owner stated the constraint plainly:

> *"EMP is in typescript, nestjs and react. I do not know those. I must depend 100% on ai to do
> anything with it."*

This is the whole ballgame. EMP's fatal flaw is **not** that it is badly built — it is that its
owner **cannot read it**. A 30-year PHP/SQL master who owns a system he cannot open, cannot
debug, and cannot change without an AI in the loop does not own that system; he rents it. Every
future change becomes a negotiation with a black box. When something breaks at 2am, he cannot
read the code that broke.

Ninja EMP inverts this — and now does so on **both** layers:

- **Database:** 12,020 lines of SQL — a language the owner has mastered for three decades. He can
  open `db/45_openitem.sql`, read the FIFO allocation, and *know* whether it is right. He can run
  the 222 assertions himself. He can point Navicat at it and see the ledger.
- **Application:** ~16,100 lines of **dependency-free PHP 8.5** — PSR-3/4/7/11/12/15, no framework,
  no Composer. `LedgerService`, `OpenItemService`, `Money`, the DBAL, the HTTP kernel, the tenant
  UI templates — all in the language the owner has written for 30 years.

The DB-first approach is not a stylistic preference; it is the difference between **owning** the
system and **depending on** it. And Ninja EMP now delivers that ownership end-to-end, not just at
the database.

EMP's strengths (hash chain, bigint money, reversal-as-status) are real and worth stealing. But
they are *ideas*, and ideas port cleanly into SQL. EMP's weakness (128k LOC of TS the owner
cannot read) is *structural*, and it does not port — it is the reason EMP is the wrong vehicle.

---

## 4. Better / Worse Scorecard

| Dimension | Winner | Notes |
|---|---|---|
| Journal tamper-evidence (hash chain) | **EMP** | Ninja EMP should adopt this |
| Money representation (bigint minor units) | **EMP** | Ninja EMP's bcmath `Money` closes most of the gap; scale CHECK still advised |
| Reversal correctness (document status + CHECK) | **EMP** | Structurally immune to Ninja EMP's F1 bug (still present) |
| Open-item AR/AP (invoice-level settlement) | **Ninja EMP** | EMP has none — the PC failure mode |
| Payment allocation control (direct-to-invoice) | **Ninja EMP** | EMP has no allocation at all |
| Tenant isolation (RLS) | **Ninja EMP** | EMP is schema-only, no RLS |
| Account determination (posting_map) | **Ninja EMP** | EMP hard-codes codes in TS |
| Accounting logic in a language the owner reads | **Ninja EMP** | 12k SQL + 16k PHP vs 128k TS |
| Application layer in a language the owner reads | **Ninja EMP** | PHP 8.5, no framework vs NestJS/React |
| Test coverage of invariants | **Ninja EMP** | 222 SQL assertions + 319 PHP assertions |
| UI (tenant back-office + vendor portal) | **Ninja EMP** | Server-rendered PHP templates; EMP is React |
| Ledger kernel fundamentals (balance, append-only, periods) | **Tie** | Both correct |

**Score: Ninja EMP wins the dimensions that decide the project; EMP wins three ideas that should
be ported into Ninja EMP.**

---

## 5. Recommendations

1. **Do not switch to EMP.** Its architecture is sound but its maintainability axis is fatal for
   this owner. The 128k LOC of TS/NestJS/React is a dependency, not an asset.
2. **Port EMP's three good ideas into Ninja EMP:**
   - Add a `prev_hash`/`entry_hash` chain to the Ninja EMP journal (tamper-evidence).
   - Enforce a scale CHECK so no sub-cent amount can be posted (the bcmath `Money` object already
     refuses floats — this closes the last gap).
   - Adopt EMP's reversal-as-document-status + CHECK pattern to close Ninja EMP's F1 bug
     *structurally*, not just with a patch.
3. **Fix Ninja EMP's settlement defects F1–F6** (already audited, no code changed yet). The
   reversal fix (F1) should use EMP's document-status pattern as the model. **These defects are
   still present in the current code** — the 15 new commits added the application layer but did
   not touch the settlement layer.
4. **Keep Ninja EMP DB-first, and keep the app layer in PHP.** The owner's ability to read and own
   both the SQL and the PHP is the project's single greatest asset. Protect it.

---

## 6. Bottom Line

EMP is a competently engineered system that solved the *accounting* lessons of PC but
re-introduced the *maintainability* problem in a new form: it moved the logic into a stack its
owner cannot read. Ninja EMP keeps the accounting rigor, keeps the logic in SQL the owner owns,
**and now has an application layer in PHP the owner also owns.** EMP's three best ideas —
hash-chained journal, minor-unit money, reversal-as-status — should be lifted into Ninja EMP.
Everything else about EMP is a step backward for this project.

**Verdict: Ninja EMP is the right vehicle — now on both layers. EMP is a valuable source of three
specific ideas.**
