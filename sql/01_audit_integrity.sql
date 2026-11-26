-- Stage 1D: integrity audit on trips_scoped. READ-ONLY: nothing is cleaned or removed here.
-- Order: cheap checks first (zones, flags, fee timing), heavier checks last (duplicates, column summary).
-- Convention: blocks named create_* are DDL; run them once before the checks.

-- name: create_trips_hashed
-- One 64-bit hash per row, so duplicate detection groups on 8 bytes instead of 25 columns (lighter on the Mac).
-- h_exact = all 25 raw columns. h_fp = a "trip fingerprint": company, three timestamps, both zones, miles, time, fare, pay.
-- A 64-bit hash collision is not impossible (roughly 1 in 90,000 odds of even one across 20M rows), so any duplicate
-- group found here must be confirmed on the real columns before a rule is written.
CREATE OR REPLACE VIEW trips_hashed AS
SELECT
    hvfhs_license_num,
    wait_seconds,
    hash(ROW(hvfhs_license_num, dispatching_base_num, originating_base_num, request_datetime, on_scene_datetime,
             pickup_datetime, dropoff_datetime, PULocationID, DOLocationID, trip_miles, trip_time,
             base_passenger_fare, tolls, bcf, sales_tax, congestion_surcharge, airport_fee, tips, driver_pay,
             shared_request_flag, shared_match_flag, access_a_ride_flag, wav_request_flag, wav_match_flag,
             cbd_congestion_fee)) AS h_exact,
    hash(ROW(hvfhs_license_num, request_datetime, pickup_datetime, dropoff_datetime, PULocationID, DOLocationID,
             trip_miles, trip_time, base_passenger_fare, driver_pay)) AS h_fp
FROM trips_scoped;

-- name: zones_key_check
-- Is LocationID a clean key? (a LEFT JOIN only stays row-for-row if it is unique)
SELECT
    COUNT(*)                                                                    AS n_rows,
    COUNT(DISTINCT LocationID)                                                  AS n_distinct_ids,
    MIN(LocationID)                                                             AS min_id,
    MAX(LocationID)                                                             AS max_id,
    COUNT(*) FILTER (WHERE Borough IS NULL OR Zone IS NULL OR service_zone IS NULL) AS n_rows_with_true_null
FROM zones;

-- name: zones_special_rows
-- Placeholder rows in the lookup (EWR, "Unknown", "N/A", true nulls). pandas turns "N/A" text into NaN; DuckDB keeps it as text.
SELECT *
FROM zones
WHERE LocationID IN (1, 264, 265)
   OR Borough IS NULL OR Zone IS NULL OR service_zone IS NULL
   OR Borough IN ('Unknown', 'N/A') OR Zone IN ('Unknown', 'N/A') OR service_zone IN ('Unknown', 'N/A')
ORDER BY LocationID;

-- name: join_reconcile
-- Row counts must not change when zones are joined, and no trip should point at a zone missing from the lookup.
SELECT
    (SELECT COUNT(*) FROM trips_scoped)                                                       AS scoped_rows,
    (SELECT COUNT(*) FROM trips_scoped t
        LEFT JOIN zones zp ON zp.LocationID = t.PULocationID
        LEFT JOIN zones zd ON zd.LocationID = t.DOLocationID)                                 AS joined_rows,
    (SELECT COUNT(*) FROM trips_scoped t
        LEFT JOIN zones zp ON zp.LocationID = t.PULocationID WHERE zp.LocationID IS NULL)     AS pickup_unmatched,
    (SELECT COUNT(*) FROM trips_scoped t
        LEFT JOIN zones zd ON zd.LocationID = t.DOLocationID WHERE zd.LocationID IS NULL)     AS dropoff_unmatched;

-- name: borough_coverage
-- Where do trips start and end, by borough label? Shows how many land in EWR / Unknown / unmatched.
SELECT 'pickup' AS side,
       COALESCE(z.Borough, '(unmatched)')                                    AS borough,
       COUNT(*)                                                              AS n_rows,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3)                    AS pct_of_rows
FROM trips_scoped t
LEFT JOIN zones z ON z.LocationID = t.PULocationID
GROUP BY 2
UNION ALL
SELECT 'dropoff',
       COALESCE(z.Borough, '(unmatched)'),
       COUNT(*),
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3)
FROM trips_scoped t
LEFT JOIN zones z ON z.LocationID = t.DOLocationID
GROUP BY 2
ORDER BY side, n_rows DESC;

-- name: unknown_zone_trips
-- Pickups in placeholder zones (EWR, Unknown, N/A): how many, and how many have a valid wait?
SELECT
    t.PULocationID,
    z.Borough,
    z.Zone,
    COUNT(*)                                          AS n_rows,
    COUNT(*) FILTER (WHERE t.wait_seconds >= 0)       AS n_valid_wait
FROM trips_scoped t
LEFT JOIN zones z ON z.LocationID = t.PULocationID
WHERE t.PULocationID IN (1, 264, 265)
   OR z.Borough IS NULL OR z.Zone IS NULL
   OR z.Borough IN ('Unknown', 'N/A') OR z.Zone IN ('Unknown', 'N/A')
GROUP BY ALL
ORDER BY n_rows DESC;

-- name: flag_values
-- Every distinct value of every Y/N flag (including NULL or unexpected values).
SELECT 'shared_request_flag' AS flag, shared_request_flag AS val, COUNT(*) AS n_rows FROM trips_scoped GROUP BY 2
UNION ALL
SELECT 'shared_match_flag',   shared_match_flag,   COUNT(*) FROM trips_scoped GROUP BY 2
UNION ALL
SELECT 'access_a_ride_flag',  access_a_ride_flag,  COUNT(*) FROM trips_scoped GROUP BY 2
UNION ALL
SELECT 'wav_request_flag',    wav_request_flag,    COUNT(*) FROM trips_scoped GROUP BY 2
UNION ALL
SELECT 'wav_match_flag',      wav_match_flag,      COUNT(*) FROM trips_scoped GROUP BY 2
ORDER BY flag, val;

-- name: flag_consistency
-- Logical checks between flags, by company. Counts only; nothing is removed.
SELECT
    hvfhs_license_num,
    COUNT(*)                                                                         AS n_rows,
    COUNT(*) FILTER (WHERE shared_match_flag = 'Y' AND shared_request_flag = 'N')    AS shared_match_without_request,
    COUNT(*) FILTER (WHERE wav_request_flag = 'Y' AND wav_match_flag = 'N')          AS wav_requested_not_matched,
    COUNT(*) FILTER (WHERE access_a_ride_flag = 'Y')                                 AS access_a_ride_y,
    COUNT(*) FILTER (WHERE access_a_ride_flag = 'Y' AND wav_request_flag = 'Y')      AS access_a_ride_and_wav_request
FROM trips_scoped
GROUP BY 1
ORDER BY 1;

-- name: cbd_fee_timing
-- The dictionary says the congestion relief fee starts Jan 5, 2025. Does the data agree?
SELECT
    CASE WHEN pickup_datetime < TIMESTAMP '2025-01-05 00:00:00' THEN '1_before_jan5' ELSE '2_jan5_onward' END AS period,
    COUNT(*)                                                                      AS n_rows,
    COUNT(*) FILTER (WHERE cbd_congestion_fee > 0)                                AS n_fee_positive,
    ROUND(100.0 * COUNT(*) FILTER (WHERE cbd_congestion_fee > 0) / COUNT(*), 3)   AS pct_fee_positive
FROM trips_scoped
GROUP BY 1
ORDER BY 1;

-- name: duplicate_summary
-- HEAVIER. Rows vs distinct hashes. "Excess" = rows beyond the first copy in each group.
SELECT
    COUNT(*)                                  AS n_rows,
    COUNT(DISTINCT h_exact)                   AS n_distinct_exact,
    COUNT(*) - COUNT(DISTINCT h_exact)        AS exact_duplicate_excess_rows,
    COUNT(DISTINCT h_fp)                      AS n_distinct_fingerprint,
    COUNT(*) - COUNT(DISTINCT h_fp)           AS fingerprint_duplicate_excess_rows
FROM trips_hashed;

-- name: duplicate_groups
-- Fingerprint groups with more than one row: how big, and are the copies identical on all 25 columns?
-- n_exact_variants = 1 means exact copies; more than 1 means same trip fingerprint but other columns differ.
-- An empty result means no fingerprint duplicates exist.
WITH g AS (
    SELECT h_fp, COUNT(*) AS n_rows, COUNT(DISTINCT h_exact) AS n_exact_variants
    FROM trips_hashed
    GROUP BY h_fp
    HAVING COUNT(*) > 1
)
SELECT
    n_rows                AS group_size,
    n_exact_variants,
    COUNT(*)              AS n_groups,
    SUM(n_rows)           AS n_rows_in_groups
FROM g
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: duplicate_by_company
-- If fingerprint duplicates exist: which company, and how many wait-valid rows would they touch?
WITH g AS (
    SELECT h_fp,
           MIN(hvfhs_license_num)                   AS company,
           COUNT(*)                                 AS n_rows,
           COUNT(*) FILTER (WHERE wait_seconds >= 0) AS n_valid
    FROM trips_hashed
    GROUP BY h_fp
    HAVING COUNT(*) > 1
)
SELECT company, COUNT(*) AS n_groups, SUM(n_rows) AS n_rows_in_groups, SUM(n_rows - 1) AS excess_rows, SUM(n_valid) AS n_valid_wait_rows
FROM g
GROUP BY 1
ORDER BY 1;

-- name: column_summary
-- HEAVIEST. One scan: type, min, max, approx distinct and null % for every column (covers tolls, bcf, sales_tax,
-- congestion_surcharge, airport_fee, tips, cbd_congestion_fee that have not been audited yet).
SUMMARIZE SELECT * FROM trips_scoped;