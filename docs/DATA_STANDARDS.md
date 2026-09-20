# Ninja EMP — Enterprise Data Standards

**Status:** NORMATIVE. Every table, column, and migration MUST conform. Deviations require an ADR.
**Scope:** all schemas (`kernel`, `control`, `tenant_*`). This is the standard that makes the schema auditable, consistent, and enterprise-grade.

---

## 1. Naming conventions
| Object | Convention | Example |
|---|---|---|
| Schema | `snake_case` | `tenant_acme` |
| Table | **singular**, `snake_case` | `party`, `journal_entry` |
| Column | `snake_case` | `display_name` |
| Primary key | `id` | `id` |
| Foreign key | `<referenced_table>_id` | `party_id`, `lease_id` |
| Boolean | `is_*` / `has_*` | `is_active`, `is_house` |
| Timestamp | `*_at` (`timestamptz`) | `created_at` |
| Date | `*_date` (`date`) | `entry_date` |
| Money | `*_amount` or `debit`/`credit` | `deposit_amount` |
| Enum code | `*_code` (FK to lookup) | `space_type_code` |
| Index | `ix_<table>_<cols>` | `ix_journal_line_account` |
| Unique index | `ux_<table>_<cols>` | `ux_party_role_active` |
| FK constraint | `fk_<table>_<col>` | `fk_lease_lessee` |
| Check constraint | `ck_<table>_<desc>` | `ck_lease_dates` |
| Trigger | `trg_<table>_<desc>` | `trg_party_audit` |
| Function | `snake_case` verb-first | `post_journal_entry` |

**Rule:** no reserved words as identifiers; no quoted mixed-case identifiers.

---

## 2. Audit & optimistic concurrency (every mutable table)
Every **mutable** table carries this exact block:
```sql
created_at timestamptz NOT NULL DEFAULT now(),
created_by uuid,
updated_at timestamptz NOT NULL DEFAULT now(),
updated_by uuid,
version    integer NOT NULL DEFAULT 1
```
plus:
```sql
CREATE TRIGGER trg_<table>_audit BEFORE UPDATE ON <table>
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();
```
`kernel.touch_audit()` stamps `updated_at`/`updated_by` and increments `version`.
**Optimistic locking:** updates MUST include `AND version = :expected`; a zero-row result is a `ConflictException`. This prevents lost updates on concurrent edits (e.g. two clerks editing a lease).

**Append-only tables** (`journal_entry`, `journal_line`) are exempt: they carry `created_at`/`created_by` only and reject UPDATE/DELETE.

---

## 3. Soft delete
- **Master data** (party, space, lease, account, …) is **soft-deleted**: `deleted_at timestamptz`, `deleted_by uuid`. Never hard-delete referenced master data.
- **Ledger** is never deleted — corrections are reversals (ADR-0004).
- **Child detail** (subtypes, contact mechanisms) may be hard-deleted via `ON DELETE CASCADE` from their parent.
- All read paths filter `deleted_at IS NULL` (enforced by views or the repository layer).

---

## 4. Temporal modeling
- **Business date vs system time are distinct.** `entry_date` (business) ≠ `posting_date`/`created_at` (system). Never conflate them.
- **Time-bounded relationships** use `from_date`/`thru_date` (inclusive start, exclusive/NULL end). `thru_date IS NULL` = current.
- **Effective-dated rows must not overlap** on their business key. Enforce with a GiST exclusion constraint (`btree_gist`): `EXCLUDE USING gist (key WITH =, daterange(effective_from, effective_thru, '[]') WITH &&)`. Application-level checks alone are insufficient (ADR-0021).
- **All instants are `timestamptz`** (stored UTC). All calendar dates are `date`. No `timestamp without time zone` anywhere.

---

## 5. Money & precision
- Domain types only: `kernel.money_amount` (`numeric(19,4)`), `kernel.currency_code` (`char(3)`), `kernel.fx_rate` (`numeric(19,10)`), `kernel.percent_rate` (`numeric(9,6)`).
- **Never** PG `money`, never `float`/`real`/`double precision` for money.
- Every amount carries its `currency`. Base amounts (`base_debit`/`base_credit`) are in the tenant functional currency.
- Forced rounding is an **explicit adjustment line** (ADR-0009), never silent.

---

## 6. Data classification & PII
Every column is classified. PII columns are tagged and protected.
| Class | Meaning | Handling |
|---|---|---|
| `public` | Non-sensitive | none |
| `internal` | Business data | access-controlled |
| `confidential` | Financial/contract | access-controlled + audited |
| `pii` | Personal data | masked in views; encrypted at rest where feasible |
| `pii_sensitive` | Tax id, SSN, DOB | encrypted at rest (pgcrypto) + masked + access-logged |

- Registry: `kernel.data_classification` (column → class).
- `party_identifier` values (tax_id, ssn) are `pii_sensitive`: stored encrypted, exposed only via a masked view.
- `person.date_of_birth` is `pii_sensitive`.

---

## 7. Referential integrity
- **Financial references use `ON DELETE RESTRICT`** (default). You may never cascade-delete a party, account, lease, or journal row that has financial history. *(This corrects round-1's `ON DELETE CASCADE` on party children — see ADR-0016.)*
- **Child detail** (subtypes, contact mechanisms, attributes) may use `ON DELETE CASCADE` from their parent.
- Every FK is indexed (PG does not auto-index FKs).

---

## 8. Partitioning & scale
- **`journal_line` and `journal_entry` are partition-ready**: range-partition by `entry_date` (yearly). The partition key is part of the PK where required.
- Partitioning is enabled when a tenant exceeds a threshold (documented in the migration runner); the schema is designed so enabling it is a migration, not a redesign.
- All lines of one entry share `entry_date`, so the deferred balance trigger operates within a single partition.

---

## 9. Idempotency
- Every externally-triggered write carries an `idempotency_key` (unique per tenant). Retries return the original result.
- Applies to: journal posting, rent invoicing, settlement, POS sale capture.

---

## 10. Human-readable numbering
- User-facing documents (journal entry, lease, invoice) get a monotonic `*_no` via `GENERATED ALWAYS AS IDENTITY` (or a per-tenant sequence). Never reuse numbers.

---

## 11. Enumerations
- **Closed, stable sets** → `CHECK` constraint (e.g. `party_type IN ('person','organization')`).
- **Extensible sets** (roles, account types, space types) → **lookup table** in `kernel` with a `*_code` FK. Never PG `enum` type (painful to extend, no metadata).

---

## 12. Indexing
- Every FK indexed.
- Partial indexes for "active" predicates (`WHERE thru_date IS NULL`).
- No speculative indexes; each index justified by a query.

---

## 13. Migrations
- Resumable, batched, per-schema; tracked in `kernel.migration`.
- Forward-only; destructive changes require a documented backfill + ADR.
- Every migration is idempotent and re-runnable.

---

## 14. Compliance checklist (per table)
- [ ] Singular snake_case name; `id` PK
- [ ] `tenant_id` + RLS policy (unless append-only journal — ADR-0007)
- [ ] Audit block + `touch_audit` trigger (if mutable)
- [ ] Soft-delete columns (if master data)
- [ ] FKs indexed; financial FKs `RESTRICT`
- [ ] Money uses kernel domains; currency present
- [ ] Columns classified (PII tagged)
- [ ] `COMMENT ON` for the table and non-obvious columns
