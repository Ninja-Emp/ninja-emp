-- ============================================================================
-- 0002_person_org_updated_by.sql
--
-- BUG FIX. person and organization carry a BEFORE UPDATE trigger that runs
-- kernel.touch_audit(), which assigns NEW.updated_by. Neither table had an
-- updated_by column, so EVERY UPDATE to either table failed outright with:
--
--     ERROR: record "new" has no field "updated_by"
--
-- This was not caught earlier because the test suites only ever INSERT parties;
-- nothing renamed a person or corrected a legal name. It surfaced while
-- building the dev-data scrubber, which is the first code to UPDATE person.
--
-- Adding the columns (rather than dropping the trigger) is the correct fix:
-- the audit trail is the requirement, the missing column is the defect.
--
-- Idempotent and safe to re-run.
-- ============================================================================

ALTER TABLE person       ADD COLUMN IF NOT EXISTS created_by uuid;
ALTER TABLE person       ADD COLUMN IF NOT EXISTS updated_by uuid;
ALTER TABLE organization ADD COLUMN IF NOT EXISTS created_by uuid;
ALTER TABLE organization ADD COLUMN IF NOT EXISTS updated_by uuid;

-- Verify the fix in the same transaction that applies it: every table wired to
-- touch_audit() must expose the columns that function writes.
DO $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(relname, ', ')
    INTO v_bad
    FROM (
      SELECT c.relname
        FROM pg_trigger t
        JOIN pg_class c     ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
                           AND NOT a.attisdropped
       WHERE n.nspname = current_schema()
         AND t.tgfoid  = 'kernel.touch_audit'::regproc
       GROUP BY c.relname
      HAVING NOT bool_or(a.attname = 'updated_by')
          OR NOT bool_or(a.attname = 'updated_at')
          OR NOT bool_or(a.attname = 'version')
    ) s;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'touch_audit() is attached to table(s) missing audit columns: %', v_bad;
  END IF;
END $$;
