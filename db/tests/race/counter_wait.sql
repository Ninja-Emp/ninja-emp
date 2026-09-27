-- Race 1 (counter), session B — must block on the tenant journal counter until
-- session A rolls back, then post cleanly and roll back itself. If B returns in
-- well under the sleep, the counter lock was not taken and postings are not
-- serialized (the hash chain would then race).
BEGIN;
SELECT post_journal_entry(
  '2091-03-02', 'race counter B', 'race', 'race-counter-b', 'race:counter:b',
  jsonb_build_array(
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f010','debit',100,'currency','USD','fx_rate',1),
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f012','credit',100,'currency','USD','fx_rate',1)
  )
);
SELECT 'RACE_B_OK';
ROLLBACK;
