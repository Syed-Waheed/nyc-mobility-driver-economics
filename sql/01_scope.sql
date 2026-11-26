-- Stage 1: scope rule (DECISIONS D8) and reconciliation.
-- Layers:  trips_raw    = every row in the file (never modified)
--          trips_scoped = scope rule + derived wait_seconds, NO other filtering
--          trips_clean  = built at the END of Stage 1, only after each rule is evidenced
-- Convention: blocks named create_* are DDL and run once at notebook start.

-- name: create_trips_scoped
CREATE OR REPLACE VIEW trips_scoped AS
SELECT
    *,
    date_diff('second', request_datetime, pickup_datetime) AS wait_seconds
FROM trips_raw
WHERE pickup_datetime >= TIMESTAMP '2025-01-01 00:00:00'
  AND pickup_datetime <  TIMESTAMP '2025-02-01 00:00:00';

-- name: scope_reconcile
SELECT
    (SELECT COUNT(*) FROM trips_raw)                                        AS raw_rows,
    (SELECT COUNT(*) FROM trips_scoped)                                     AS scoped_rows,
    (SELECT COUNT(*) FROM trips_raw) - (SELECT COUNT(*) FROM trips_scoped)  AS rows_removed_by_scope;