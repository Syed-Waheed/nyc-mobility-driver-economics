-- Stage 1A: timestamp audit on trips_scoped. READ-ONLY: nothing is cleaned or removed here.
-- wait_seconds = pickup_datetime - request_datetime (see sql/01_scope.sql).

-- name: wait_sign_summary
-- How many rows have negative / zero / positive wait? (negative count should equal 199,788)
SELECT
    CASE WHEN wait_seconds < 0 THEN '1_negative'
         WHEN wait_seconds = 0 THEN '2_zero'
         ELSE '3_positive' END                                   AS wait_sign,
    COUNT(*)                                                     AS n_rows,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3)           AS pct_rows
FROM trips_scoped
GROUP BY 1
ORDER BY 1;

-- name: negative_magnitude
-- How far "before" is pickup? Tiny gaps suggest clock/rounding noise; big gaps suggest a structural issue.
SELECT
    CASE WHEN wait_seconds <= -3600 THEN 'a: 60 min or more'
         WHEN wait_seconds <= -600  THEN 'b: 10 to 60 min'
         WHEN wait_seconds <= -60   THEN 'c: 1 to 10 min'
         ELSE                            'd: under 1 min' END    AS gap_before_request,
    COUNT(*)                                                     AS n_rows,
    MIN(wait_seconds)                                            AS min_wait_s,
    quantile_cont(wait_seconds, 0.5)                             AS median_wait_s,
    MAX(wait_seconds)                                            AS max_wait_s
FROM trips_scoped
WHERE wait_seconds < 0
GROUP BY 1
ORDER BY 1;

-- name: negative_by_company
-- Is the problem concentrated in one company? (affects Uber vs Lyft comparability)
SELECT
    hvfhs_license_num,
    COUNT(*)                                                                     AS n_rows,
    COUNT(*) FILTER (WHERE wait_seconds < 0)                                     AS n_negative,
    ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)        AS pct_negative,
    COUNT(*) FILTER (WHERE wait_seconds = 0)                                     AS n_zero,
    ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds = 0) / COUNT(*), 3)        AS pct_zero
FROM trips_scoped
GROUP BY 1
ORDER BY 1;

-- name: negative_by_segment
-- Is it concentrated in shared / WAV / Access-a-Ride trips?
SELECT 'shared_request_flag' AS dim, shared_request_flag AS val, COUNT(*) AS n_rows,
       COUNT(*) FILTER (WHERE wait_seconds < 0) AS n_negative,
       ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3) AS pct_negative
FROM trips_scoped GROUP BY 2
UNION ALL
SELECT 'shared_match_flag', shared_match_flag, COUNT(*),
       COUNT(*) FILTER (WHERE wait_seconds < 0),
       ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)
FROM trips_scoped GROUP BY 2
UNION ALL
SELECT 'wav_request_flag', wav_request_flag, COUNT(*),
       COUNT(*) FILTER (WHERE wait_seconds < 0),
       ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)
FROM trips_scoped GROUP BY 2
UNION ALL
SELECT 'wav_match_flag', wav_match_flag, COUNT(*),
       COUNT(*) FILTER (WHERE wait_seconds < 0),
       ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)
FROM trips_scoped GROUP BY 2
UNION ALL
SELECT 'access_a_ride_flag', access_a_ride_flag, COUNT(*),
       COUNT(*) FILTER (WHERE wait_seconds < 0),
       ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)
FROM trips_scoped GROUP BY 2
ORDER BY dim, val;

-- name: negative_by_day
-- Is it spread evenly, or does one day look like a logging problem?
SELECT
    CAST(pickup_datetime AS DATE)                                                AS pickup_date,
    COUNT(*)                                                                     AS n_rows,
    COUNT(*) FILTER (WHERE wait_seconds < 0)                                     AS n_negative,
    ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)        AS pct_negative
FROM trips_scoped
GROUP BY 1
ORDER BY 1;

-- name: timestamp_order_violations
-- Expected order: request <= on_scene <= pickup <= dropoff. Count each violation by company.
SELECT
    hvfhs_license_num,
    COUNT(*)                                                         AS n_rows,
    COUNT(*) FILTER (WHERE pickup_datetime  < request_datetime)      AS pickup_before_request,
    COUNT(*) FILTER (WHERE dropoff_datetime < pickup_datetime)       AS dropoff_before_pickup,
    COUNT(*) FILTER (WHERE dropoff_datetime = pickup_datetime)       AS dropoff_equals_pickup,
    COUNT(*) FILTER (WHERE on_scene_datetime < request_datetime)     AS on_scene_before_request,
    COUNT(*) FILTER (WHERE on_scene_datetime > pickup_datetime)      AS on_scene_after_pickup
FROM trips_scoped
GROUP BY 1
ORDER BY 1;

-- name: onscene_position_negative
-- For negative-wait rows only: where does on_scene fall relative to pickup and request?
SELECT
    hvfhs_license_num,
    CASE WHEN on_scene_datetime IS NULL              THEN '0_on_scene_null'
         WHEN on_scene_datetime <= pickup_datetime   THEN '1_on_scene_at_or_before_pickup'
         WHEN on_scene_datetime <= request_datetime  THEN '2_on_scene_between_pickup_and_request'
         ELSE                                             '3_on_scene_after_request' END AS on_scene_position,
    COUNT(*)                                         AS n_rows
FROM trips_scoped
WHERE wait_seconds < 0
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: lyft_onscene_profile
-- What are the 14,076 Lyft rows that DO have on_scene_datetime?
SELECT
    wav_request_flag,
    wav_match_flag,
    shared_request_flag,
    COUNT(*)                  AS n_rows,
    COUNT(on_scene_datetime)  AS n_with_on_scene
FROM trips_scoped
WHERE hvfhs_license_num = 'HV0005'
GROUP BY ALL
ORDER BY n_with_on_scene DESC, n_rows DESC;