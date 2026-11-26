-- Stage 1D follow-ups. READ-ONLY: nothing is removed or relabeled.
-- Finding 1: 424 Lyft rows with shared_match_flag = 'Y' and shared_request_flag = 'N'.
-- Finding 2: rows picked up before 2025-01-05 with cbd_congestion_fee > 0.

-- name: lyft_shared_exception_flags
-- The 424 rows by the other flags. (Earlier flag table: all have wav_request = N; 372 wav_match = N, 52 wav_match = Y.)
SELECT
    wav_request_flag,
    wav_match_flag,
    access_a_ride_flag,
    COUNT(*) AS n_rows
FROM trips_scoped
WHERE shared_match_flag = 'Y' AND shared_request_flag = 'N'
GROUP BY ALL
ORDER BY n_rows DESC;

-- name: lyft_shared_exception_by_base
-- Is the exception concentrated in one dispatching base? Compare with all Lyft rows.
SELECT
    dispatching_base_num,
    originating_base_num,
    COUNT(*) FILTER (WHERE shared_match_flag = 'Y' AND shared_request_flag = 'N')   AS n_exception,
    COUNT(*)                                                                        AS n_lyft_rows,
    ROUND(100.0 * COUNT(*) FILTER (WHERE shared_match_flag = 'Y' AND shared_request_flag = 'N') / COUNT(*), 4) AS pct_exception
FROM trips_scoped
WHERE hvfhs_license_num = 'HV0005'
GROUP BY ALL
ORDER BY n_lyft_rows DESC;

-- name: lyft_shared_exception_by_day
-- Is the exception clustered on particular days? (31 rows)
SELECT
    CAST(pickup_datetime AS DATE)                                                   AS pickup_date,
    COUNT(*) FILTER (WHERE shared_match_flag = 'Y' AND shared_request_flag = 'N')   AS n_exception,
    COUNT(*)                                                                        AS n_lyft_rows,
    ROUND(100.0 * COUNT(*) FILTER (WHERE shared_match_flag = 'Y' AND shared_request_flag = 'N') / COUNT(*), 4) AS pct_exception
FROM trips_scoped
WHERE hvfhs_license_num = 'HV0005'
GROUP BY 1
ORDER BY 1;

-- name: shared_exception_profile
-- Do the 424 rows behave like ordinary Lyft trips, or like Uber shared-and-matched trips?
-- Shared trips usually show more minutes per mile and less fare per mile than comparable solo trips.
SELECT
    CASE
        WHEN hvfhs_license_num = 'HV0005' AND shared_match_flag = 'Y' AND shared_request_flag = 'N' THEN '1_lyft_match_without_request'
        WHEN hvfhs_license_num = 'HV0005'                                                           THEN '2_lyft_other'
        WHEN shared_match_flag = 'Y'                                                                THEN '3_uber_shared_matched'
        WHEN shared_request_flag = 'Y'                                                              THEN '4_uber_shared_requested_not_matched'
        ELSE                                                                                             '5_uber_not_shared'
    END                                                                              AS grp,
    COUNT(*)                                                                         AS n_rows,
    ROUND(quantile_cont(trip_miles, 0.5), 3)                                         AS median_miles,
    ROUND(quantile_cont(trip_time / 60.0, 0.5), 2)                                   AS median_trip_min,
    ROUND(quantile_cont((trip_time / 60.0) / NULLIF(trip_miles, 0), 0.5), 3)         AS median_min_per_mile,
    ROUND(quantile_cont(base_passenger_fare / NULLIF(trip_miles, 0), 0.5), 3)        AS median_fare_per_mile,
    ROUND(quantile_cont(driver_pay, 0.5), 2)                                         AS median_driver_pay,
    ROUND(quantile_cont(wait_seconds, 0.5) FILTER (WHERE wait_seconds >= 0) / 60.0, 3) AS median_valid_wait_min,
    ROUND(100.0 * COUNT(*) FILTER (WHERE wait_seconds < 0) / COUNT(*), 3)            AS pct_negative_wait
FROM trips_scoped
GROUP BY 1
ORDER BY 1;

-- name: cbd_prejan5_by_day_dropoff
-- Midnight-crossing test: are the pre-Jan-5 fee-positive rows trips that END on or after Jan 5 00:00?
SELECT
    CAST(pickup_datetime AS DATE)                                                     AS pickup_date,
    CASE WHEN dropoff_datetime >= TIMESTAMP '2025-01-05 00:00:00'
         THEN 'dropoff_on_or_after_jan5' ELSE 'dropoff_before_jan5' END               AS dropoff_period,
    COUNT(*)                                                                          AS n_rows,
    COUNT(*) FILTER (WHERE cbd_congestion_fee > 0)                                    AS n_fee_positive
FROM trips_scoped
WHERE pickup_datetime < TIMESTAMP '2025-01-05 00:00:00'
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: cbd_prejan5_positive_by_hour
-- For the fee-positive pre-Jan-5 rows: which pickup hours? (late Jan 4 would fit a midnight-crossing story)
SELECT
    CAST(pickup_datetime AS DATE)   AS pickup_date,
    hour(pickup_datetime)           AS pickup_hour,
    COUNT(*)                        AS n_fee_positive
FROM trips_scoped
WHERE pickup_datetime < TIMESTAMP '2025-01-05 00:00:00'
  AND cbd_congestion_fee > 0
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: cbd_fee_values
-- Fee amounts by period and company (only rows with a positive fee).
SELECT
    CASE WHEN pickup_datetime < TIMESTAMP '2025-01-05 00:00:00' THEN '1_before_jan5' ELSE '2_jan5_onward' END AS period,
    hvfhs_license_num,
    cbd_congestion_fee,
    COUNT(*)                         AS n_rows
FROM trips_scoped
WHERE cbd_congestion_fee > 0
GROUP BY ALL
ORDER BY 1, 2, 3;

-- name: cbd_prejan5_zones
-- Top pickup and dropoff zones of the fee-positive pre-Jan-5 rows.
WITH x AS (
    SELECT PULocationID, DOLocationID
    FROM trips_scoped
    WHERE pickup_datetime < TIMESTAMP '2025-01-05 00:00:00'
      AND cbd_congestion_fee > 0
)
(SELECT 'pickup' AS side, z.Borough, z.Zone, COUNT(*) AS n_rows
 FROM x JOIN zones z ON z.LocationID = x.PULocationID
 GROUP BY 2, 3 ORDER BY n_rows DESC LIMIT 8)
UNION ALL
(SELECT 'dropoff', z.Borough, z.Zone, COUNT(*)
 FROM x JOIN zones z ON z.LocationID = x.DOLocationID
 GROUP BY 2, 3 ORDER BY 4 DESC LIMIT 8);