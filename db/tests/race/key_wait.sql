-- Race 4 (key), session B — posts the same idempotency key. It must block until
-- session A rolls back, then post cleanly. This is the idempotency race: two
-- identical postings cannot both commit, and the loser is serialized rather than
-- failing on a duplicate key.
BEGIN;
SELECT post_journal_entry(
  '2091-07-02', 'race key B', 'race', 'race-key-b', 'race:key',
  jsonb_build_array(
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f010','debit',100,'currency','USD','fx_rate',1),
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f012','credit',100,'currency','USD','fx_rate',1)
  )
);
SELECT 'RACE_B_OK';
ROLLBACK;
