-- Race 1 (counter), session A — posts an entry, which locks the tenant journal
-- counter FOR UPDATE inside the hash-chain trigger, then holds the lock for the
-- sleep and rolls back. Session B must block on that same counter row.
BEGIN;
SELECT post_journal_entry(
  '2091-03-01', 'race counter A', 'race', 'race-counter-a', 'race:counter:a',
  jsonb_build_array(
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f010','debit',100,'currency','USD','fx_rate',1),
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f012','credit',100,'currency','USD','fx_rate',1)
  )
);
SELECT pg_sleep(6);
ROLLBACK;
