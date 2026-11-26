-- Stage 1A-2: root-pattern investigation of negative waits (DECISIONS D11). READ-ONLY.
-- wait_seconds = pickup - request (see sql/01_scope.sql). Association language only.
-- Heavier queries (quantiles over ~20M rows) are at the bottom; run them one at a time if the Mac gets warm.

-- name: negative_by_company_flags
-- Separates company mix from flag effects: is the WAV pattern one company or both?
SELECT
    hvfhs_license_num,
    wav_request_flag,
    wav_match_flag,
    shared_request_flag,
    COUNT(*)                                                               AS n_rows,
    COUNT(*) FILTER (WHERE wait_seconds < 0)                               AS n_negative,
    ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)  AS pct_negative
FROM trips_scoped
GROUP BY ALL
ORDER BY hvfhs_license_num, n_rows DESC;

-- name: uber_order_patterns
-- Mutually exclusive ordering patterns of request (a), on_scene (s), pickup (p) for Uber rows.
-- C+D+E = Uber negative-wait rows. B+C+(part of D) = on_scene_before_request. D+E+F = on_scene_after_pickup.
SELECT
    CASE
        WHEN on_scene_datetime IS NULL
            THEN 'G_on_scene_null'
        WHEN request_datetime <= pickup_datetime
         AND request_datetime <= on_scene_datetime
         AND on_scene_datetime <= pickup_datetime
            THEN 'A_normal: request<=on_scene<=pickup'
        WHEN request_datetime <= pickup_datetime AND on_scene_datetime < request_datetime
            THEN 'B_wait_ok_but_on_scene_before_request'
        WHEN request_datetime <= pickup_datetime AND on_scene_datetime > pickup_datetime
            THEN 'F_wait_ok_but_on_scene_after_pickup'
        WHEN on_scene_datetime <= pickup_datetime
            THEN 'C_negative: on_scene<=pickup<request'
        WHEN on_scene_datetime <= request_datetime
            THEN 'D_negative: pickup<on_scene<=request'
        ELSE 'E_negative: pickup<request<on_scene'
    END                                                          AS order_pattern,
    COUNT(*)                                                     AS n_rows,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3)           AS pct_of_uber
FROM trips_scoped
WHERE hvfhs_license_num = 'HV0003'
GROUP BY 1
ORDER BY 1;

-- name: request_lateness_uber
-- Uber rows where the driver was on scene BEFORE the recorded request: by how much, and what wait do they show?
SELECT
    CASE WHEN wait_seconds < 0 THEN 'negative_wait' ELSE 'nonneg_wait' END       AS wait_group,
    CASE WHEN date_diff('second', on_scene_datetime, request_datetime) < 60    THEN 'a: under 1 min'
         WHEN date_diff('second', on_scene_datetime, request_datetime) < 600   THEN 'b: 1 to 10 min'
         WHEN date_diff('second', on_scene_datetime, request_datetime) < 3600  THEN 'c: 10 to 60 min'
         ELSE                                                                       'd: 60 min or more' END AS request_after_on_scene,
    COUNT(*)                                                                     AS n_rows,
    quantile_cont(wait_seconds, 0.5)                                             AS median_wait_s
FROM trips_scoped
WHERE hvfhs_license_num = 'HV0003'
  AND on_scene_datetime < request_datetime
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: negative_by_hour_company
-- Is the negative-wait rate tied to time of day? (hour of pickup, by company)
SELECT
    hour(pickup_datetime)                                                        AS pickup_hour,
    hvfhs_license_num,
    COUNT(*)                                                                     AS n_rows,
    COUNT(*) FILTER (WHERE wait_seconds < 0)                                     AS n_negative,
    ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)        AS pct_negative
FROM trips_scoped
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: negative_by_zone_top
-- Are negative waits concentrated in a few pickup zones? Top 15 by count, with cumulative share.
WITH z AS (
    SELECT
        PULocationID,
        COUNT(*)                                  AS n_rows,
        COUNT(*) FILTER (WHERE wait_seconds < 0)  AS n_negative
    FROM trips_scoped
    GROUP BY 1
)
SELECT
    z.PULocationID,
    zn.Borough,
    zn.Zone,
    z.n_rows,
    z.n_negative,
    ROUND(100.0 * z.n_negative / z.n_rows, 3)                                              AS pct_negative_in_zone,
    ROUND(100.0 * z.n_negative / SUM(z.n_negative) OVER (), 2)                             AS share_of_all_negatives,
    ROUND(100.0 * SUM(z.n_negative) OVER (ORDER BY z.n_negative DESC, z.PULocationID)
                / SUM(z.n_negative) OVER (), 2)                                            AS cumulative_share
FROM z
LEFT JOIN zones zn ON zn.LocationID = z.PULocationID
ORDER BY z.n_negative DESC, z.PULocationID
LIMIT 15;

-- name: pickup_dropoff_consistency
-- Independent check on pickup_datetime: does (dropoff - pickup) match the reported trip_time?
-- If negative-wait rows look like normal rows here, pickup is probably fine and request is the odd timestamp.
SELECT
    hvfhs_license_num,
    CASE WHEN wait_seconds < 0 THEN 'negative_wait' ELSE 'nonneg_wait' END       AS wait_group,
    COUNT(*)                                                                     AS n_rows,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE date_diff('second', pickup_datetime, dropoff_datetime) = trip_time) / COUNT(*), 2) AS pct_exact_match,
    quantile_cont(date_diff('second', pickup_datetime, dropoff_datetime) - trip_time, 0.05) AS p05_diff_s,
    quantile_cont(date_diff('second', pickup_datetime, dropoff_datetime) - trip_time, 0.50) AS median_diff_s,
    quantile_cont(date_diff('second', pickup_datetime, dropoff_datetime) - trip_time, 0.95) AS p95_diff_s
FROM trips_scoped
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: negative_vs_normal_profile
-- Do negative-wait rows look like ordinary trips on miles, duration, fare and pay? (supports keeping them for pay/volume)
SELECT
    hvfhs_license_num,
    CASE WHEN wait_seconds < 0 THEN 'negative_wait' ELSE 'nonneg_wait' END       AS wait_group,
    COUNT(*)                                                                     AS n_rows,
    quantile_cont(trip_miles, 0.5)                                               AS median_miles,
    quantile_cont(trip_time / 60.0, 0.5)                                         AS median_trip_min,
    quantile_cont(base_passenger_fare, 0.5)                                      AS median_base_fare,
    quantile_cont(driver_pay, 0.5)                                               AS median_driver_pay
FROM trips_scoped
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: exclusion_sensitivity
-- Worst-case bounds: if the excluded rows' TRUE waits were all the lowest possible, or all the highest possible,
-- how far could each company's median and p90 move? Narrow bounds => the exclusion choice cannot change conclusions much.
SELECT
    hvfhs_license_num,
    COUNT(*)                                                                      AS n_rows,
    COUNT(*) FILTER (WHERE wait_seconds < 0)                                      AS n_excluded,
    ROUND(quantile_cont(wait_seconds, 0.5) FILTER (WHERE wait_seconds >= 0) / 60.0, 3)                       AS median_min_excluded,
    ROUND(quantile_cont(CASE WHEN wait_seconds < 0 THEN 0 ELSE wait_seconds END, 0.5) / 60.0, 3)             AS median_min_if_all_low,
    ROUND(quantile_cont(CASE WHEN wait_seconds < 0 THEN 1000000000 ELSE wait_seconds END, 0.5) / 60.0, 3)    AS median_min_if_all_high,
    ROUND(quantile_cont(wait_seconds, 0.9) FILTER (WHERE wait_seconds >= 0) / 60.0, 3)                       AS p90_min_excluded,
    ROUND(quantile_cont(CASE WHEN wait_seconds < 0 THEN 0 ELSE wait_seconds END, 0.9) / 60.0, 3)             AS p90_min_if_all_low,
    ROUND(quantile_cont(CASE WHEN wait_seconds < 0 THEN 1000000000 ELSE wait_seconds END, 0.9) / 60.0, 3)    AS p90_min_if_all_high
FROM trips_scoped
GROUP BY 1
ORDER BY 1;