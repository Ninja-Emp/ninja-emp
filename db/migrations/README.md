# Migrations

`provision.sh` builds a database **from scratch**. That is correct for greenfield work and useless the
moment a tenant has real data. This directory is how the schema evolves after go-live.

## Rules

1. **Migrations are append-only.** Never edit a migration that has been applied anywhere but your own
   laptop. Write a new one.
2. **Every migration is idempotent.** Use `IF NOT EXISTS`, `CREATE OR REPLACE`, and `ON CONFLICT DO
   NOTHING`. A half-applied migration must be safe to re-run.
3. **Every migration is transactional** unless it physically cannot be (concurrent index builds). The
   runner wraps each file in a transaction; a failure rolls that file back entirely.
4. **Filename format:** `NNNN_short_description.sql`, zero-padded, strictly increasing.
5. **Schema-qualified or search_path-aware.** The runner sets `search_path` per tenant schema and runs
   the migration once per tenant.

## Applying

```bash
./scripts/migrate.sh              # apply all pending, all tenants
./scripts/migrate.sh --dry-run    # show what would run, change nothing
./scripts/migrate.sh --status     # what is applied vs pending
./scripts/migrate.sh --tenant tenant_demo
```

State is recorded in `kernel.schema_migration`, keyed by `(tenant_schema, version)`. The runner is
**resumable**: it applies only what is missing, so an interrupted run is fixed by running it again.

## Checksums

The runner stores a SHA-256 of each migration when it applies it. If a previously applied file changes
on disk, the runner **refuses to continue** rather than silently running a different script than the one
recorded. Override only if you know exactly why:

```bash
./scripts/migrate.sh --allow-checksum-drift
```
