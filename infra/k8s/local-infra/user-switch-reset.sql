-- The user database, reset for a switch between the Scala and Rust user-service
-- (ADR 0028 decision 5): each keeps its own migration history, and there is no
-- production data. Run by bin/k8s-local-up; rehearsed by tests/contract
-- tests/integration/test_cdc_stack.py.
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
DROP PUBLICATION IF EXISTS dbz_publication;

-- Debezium's slot goes too. Kept, it would replay WAL from before the switch, where
-- the publication it recreates on restart doesn't exist yet: pgoutput fails with
-- 'publication "dbz_publication" does not exist' while the connector reports RUNNING
-- (RUST-5.2). Its walsender is ended first, as an active slot can't be dropped; the
-- connector creates a fresh slot when it restarts.
DO $$
DECLARE
  deadline timestamptz := clock_timestamp() + interval '10 seconds';
BEGIN
  PERFORM pg_terminate_backend(active_pid) FROM pg_replication_slots
   WHERE slot_name = 'debezium_user' AND active_pid IS NOT NULL;
  WHILE EXISTS (SELECT FROM pg_replication_slots
                 WHERE slot_name = 'debezium_user' AND active_pid IS NOT NULL) LOOP
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'slot debezium_user is still in use';
    END IF;
    PERFORM pg_sleep(0.1);
  END LOOP;
  PERFORM pg_drop_replication_slot('debezium_user')
     FROM pg_replication_slots WHERE slot_name = 'debezium_user';
END
$$;
