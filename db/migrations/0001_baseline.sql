-- ============================================================================
-- 0001_baseline.sql
--
-- Marks the schema produced by db/provision.sh as migration baseline 0001.
-- Deliberately does almost nothing: a database built by provision.sh is already
-- at this version, so applying this migration must be a no-op.
--
-- Every schema change AFTER the initial build gets its own numbered file.
-- ============================================================================

-- Sanity check: this migration only makes sense against a provisioned schema.
DO $$
BEGIN
  IF to_regclass(current_schema() || '.journal_entry') IS NULL THEN
    RAISE EXCEPTION
      'Baseline migration applied to a schema with no journal_entry table. '
      'Run db/provision.sh first — migrations evolve an existing schema, they do not create one.'
      USING ERRCODE='42P01';
  END IF;
END $$;
