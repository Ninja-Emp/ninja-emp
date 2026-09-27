-- Race 2 (period), session B — posts into the period session A is closing. It
-- must block on the period row until A rolls back, then post cleanly. Had A
-- committed the close, this posting would be refused as into-a-closed-period.
BEGIN;
SELECT post_journal_entry(
  '2091-05-01', 'race period B', 'race', 'race-period-b', 'race:period:b',
  jsonb_build_array(
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f010','debit',100,'currency','USD','fx_rate',1),
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f012','credit',100,'currency','USD','fx_rate',1)
  )
);
SELECT 'RACE_B_OK';
ROLLBACK;
