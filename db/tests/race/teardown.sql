-- Race harness teardown. Removes the setup rows in dependency order. Safe only
-- because every race transaction rolled back: nothing references the accounts or
-- the period.
\set ON_ERROR_STOP on

DELETE FROM fiscal_period WHERE id = '01900000-0000-7000-8000-00000000f021';
DELETE FROM account
 WHERE id IN ('01900000-0000-7000-8000-00000000f010',
              '01900000-0000-7000-8000-00000000f012');
