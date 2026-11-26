-- Stage 1B: audit of VALID waits (wait_seconds >= 0 under D11 rule R1). READ-ONLY.
-- Bins and buckets below are DISPLAY bins to look at the distribution. They are not cleaning thresholds.
-- Reconcile first: n_valid should be 15,235,488 (Uber) and 4,970,390 (Lyft), total 20,205,878.

-- name: wait_percentiles_valid
SELECT
    hvfhs_license_num,
    COUNT(*)                                            AS n_valid,
    ROUND(AVG(wait_seconds) / 60.0, 3)                  AS mean_min,
    ROUND(quantile_cont(wait_seconds, 0.50)  / 60.0, 3) AS p50_min,
    ROUND(quantile_cont(wait_seconds, 0.75)  / 60.0, 3) AS p75_min,
    ROUND(quantile_cont(wait_seconds, 0.90)  / 60.0, 3) AS p90_min,
    quantile_cont(wait_seconds, 0.90)                   AS p90_seconds,
    ROUND(quantile_cont(wait_seconds, 0.95)  / 60.0, 3) AS p95_min,
    ROUND(quantile_cont(wait_seconds, 0.99)  / 60.0, 3) AS p99_min,
    ROUND(quantile_cont(wait_seconds, 0.999) / 60.0, 3) AS p999_min,
    ROUND(MAX(wait_seconds) / 60.0, 3)                  AS max_min
FROM trips_scoped
WHERE wait_seconds >= 0
GROUP BY 1
ORDER BY 1;

-- name: wait_bins_valid
-- Histogram-ready bins. The zero bin answers: how many waits are exactly 0 seconds?
SELECT
    hvfhs_license_num,
    CASE WHEN wait_seconds = 0     THEN '00: exactly 0 s'
         WHEN wait_seconds < 60    THEN '01: under 1 min'
         WHEN wait_seconds < 120   THEN '02: 1 to 2 min'
         WHEN wait_seconds < 300   THEN '03: 2 to 5 min'
         WHEN wait_seconds < 600   THEN '04: 5 to 10 min'
         WHEN wait_seconds < 1200  THEN '05: 10 to 20 min'
         WHEN wait_seconds < 1800  THEN '06: 20 to 30 min'
         WHEN wait_seconds < 3600  THEN '07: 30 to 60 min'
         WHEN wait_seconds < 7200  THEN '08: 1 to 2 h'
         ELSE                           '09: 2 h or more' END                   AS wait_bin,
    COUNT(*)                                                                    AS n_rows,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY hvfhs_license_num), 3) AS pct_of_company_valid
FROM trips_scoped
WHERE wait_seconds >= 0
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: longest_valid_waits
-- Eyeball the 15 longest valid waits: do they look like real waits or like bad timestamps?
SELECT
    hvfhs_license_num,
    request_datetime,
    on_scene_datetime,
    pickup_datetime,
    dropoff_datetime,
    ROUND(wait_seconds / 60.0, 1) AS wait_min,
    PULocationID,
    DOLocationID,
    trip_miles,
    trip_time,
    driver_pay
FROM trips_scoped
WHERE wait_seconds >= 0
ORDER BY wait_seconds DESC
LIMIT 15;

-- name: dec31_requests
-- The requests made before 2025-01-01 (pickup in January). Expect 1,164 rows in total.
SELECT
    hvfhs_license_num,
    COUNT(*)                                         AS n_rows,
    COUNT(*) FILTER (WHERE wait_seconds < 0)         AS n_negative,
    ROUND(MIN(wait_seconds) / 60.0, 1)               AS min_wait_min,
    ROUND(quantile_cont(wait_seconds, 0.5) / 60.0, 1) AS median_wait_min,
    ROUND(MAX(wait_seconds) / 60.0, 1)               AS max_wait_min
FROM trips_scoped
WHERE request_datetime < TIMESTAMP '2025-01-01 00:00:00'
GROUP BY 1
ORDER BY 1;

-- name: request_second_pattern
-- Hypothesis test (H2, pre-booked rides): if request_datetime sometimes holds a scheduled time, round values
-- (second = 0, minute on a 5-minute mark) should be over-represented in the suspect groups.
-- Reference point: if request seconds were arbitrary, about 1.7% of rows would have second = 0 and about 0.3% a 5-minute mark.
SELECT
    hvfhs_license_num,
    CASE WHEN wait_seconds < 0 THEN 'negative_wait' ELSE 'nonneg_wait' END                AS wait_group,
    CASE WHEN on_scene_datetime < request_datetime THEN 'on_scene_before_request'
         ELSE 'other' END                                                                  AS on_scene_vs_request,
    COUNT(*)                                                                               AS n_rows,
    ROUND(100.0 * COUNT(*) FILTER (WHERE second(request_datetime) = 0) / COUNT(*), 2)      AS pct_request_second_zero,
    ROUND(100.0 * COUNT(*) FILTER (WHERE second(request_datetime) = 0
                                     AND minute(request_datetime) % 5 = 0) / COUNT(*), 2)  AS pct_request_5min_mark
FROM trips_scoped
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- name: negative_airport_profile
-- Hypothesis test (H2): are negative-wait trips more often airport trips? (zone names containing "Airport")
-- n_rows across both companies must sum to 20,405,666 (checks the zone joins add no rows).
SELECT
    t.hvfhs_license_num,
    CASE WHEN t.wait_seconds < 0 THEN 'negative_wait' ELSE 'nonneg_wait' END               AS wait_group,
    COUNT(*)                                                                               AS n_rows,
    ROUND(100.0 * COUNT(*) FILTER (WHERE zd.Zone ILIKE '%airport%') / COUNT(*), 2)         AS pct_dropoff_airport_zone,
    ROUND(100.0 * COUNT(*) FILTER (WHERE zp.Zone ILIKE '%airport%') / COUNT(*), 2)         AS pct_pickup_airport_zone
FROM trips_scoped t
LEFT JOIN zones zd ON zd.LocationID = t.DOLocationID
LEFT JOIN zones zp ON zp.LocationID = t.PULocationID
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: uber_b_sensitivity
-- Uber rows with on_scene before request but a non-negative wait (58,321 rows, pattern B). Kept in wait stats under R1.
-- How far could they move Uber's median and p90 in the worst case (all treated as the highest possible wait)?
SELECT
    COUNT(*)                                                                                         AS n_valid_uber,
    COUNT(*) FILTER (WHERE on_scene_datetime < request_datetime)                                     AS n_pattern_b,
    ROUND(quantile_cont(wait_seconds, 0.5) / 60.0, 3)                                                AS median_min_as_is,
    ROUND(quantile_cont(wait_seconds, 0.5) FILTER (WHERE NOT (on_scene_datetime < request_datetime)) / 60.0, 3) AS median_min_without_b,
    ROUND(quantile_cont(CASE WHEN on_scene_datetime < request_datetime THEN 1000000000 ELSE wait_seconds END, 0.5) / 60.0, 3) AS median_min_b_as_high,
    ROUND(quantile_cont(wait_seconds, 0.9) / 60.0, 3)                                                AS p90_min_as_is,
    ROUND(quantile_cont(wait_seconds, 0.9) FILTER (WHERE NOT (on_scene_datetime < request_datetime)) / 60.0, 3) AS p90_min_without_b,
    ROUND(quantile_cont(CASE WHEN on_scene_datetime < request_datetime THEN 1000000000 ELSE wait_seconds END, 0.9) / 60.0, 3) AS p90_min_b_as_high
FROM trips_scoped
WHERE hvfhs_license_num = 'HV0003'
  AND wait_seconds >= 0;