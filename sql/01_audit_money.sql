-- Stage 1C: audit of fare, driver pay, miles and trip_time on trips_scoped. READ-ONLY.
-- Bins and quantiles below are for LOOKING at the data. They are not cleaning thresholds.

-- name: nonpositive_counts
-- How many rows have zero or negative miles / time / fare / pay, and how often does pay exceed base fare?
SELECT
    hvfhs_license_num,
    COUNT(*)                                              AS n_rows,
    COUNT(*) FILTER (WHERE trip_miles = 0)                AS miles_zero,
    COUNT(*) FILTER (WHERE trip_time = 0)                 AS time_zero,
    COUNT(*) FILTER (WHERE base_passenger_fare < 0)       AS fare_negative,
    COUNT(*) FILTER (WHERE base_passenger_fare = 0)       AS fare_zero,
    COUNT(*) FILTER (WHERE driver_pay < 0)                AS pay_negative,
    COUNT(*) FILTER (WHERE driver_pay = 0)                AS pay_zero,
    COUNT(*) FILTER (WHERE driver_pay > base_passenger_fare) AS pay_gt_fare
FROM trips_scoped
GROUP BY 1
ORDER BY 1;

-- name: negative_money_profile
-- Do negative fare / pay rows look like refunds or adjustments? (zero miles or time, other negative money fields)
SELECT
    CASE WHEN base_passenger_fare < 0 THEN 'fare_negative'
         WHEN base_passenger_fare = 0 THEN 'fare_zero'
         ELSE 'fare_positive' END                         AS fare_sign,
    CASE WHEN driver_pay < 0 THEN 'pay_negative'
         WHEN driver_pay = 0 THEN 'pay_zero'
         ELSE 'pay_positive' END                          AS pay_sign,
    COUNT(*)                                              AS n_rows,
    COUNT(*) FILTER (WHERE trip_miles = 0)                AS miles_zero,
    COUNT(*) FILTER (WHERE trip_time = 0)                 AS time_zero,
    COUNT(*) FILTER (WHERE tolls < 0 OR bcf < 0 OR sales_tax < 0 OR congestion_surcharge < 0
                       OR airport_fee < 0 OR tips < 0 OR cbd_congestion_fee < 0) AS other_money_negative,
    ROUND(quantile_cont(trip_miles, 0.5), 3)              AS median_miles,
    ROUND(quantile_cont(trip_time / 60.0, 0.5), 2)        AS median_trip_min,
    MIN(base_passenger_fare)                              AS min_fare,
    MIN(driver_pay)                                       AS min_pay
FROM trips_scoped
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: pay_to_fare_ratio
-- Descriptive only (D4): driver_pay / base_passenger_fare. NOT a take rate. Rows used: fare > 0 and pay >= 0.
SELECT
    hvfhs_license_num,
    COUNT(*)                                                                    AS n_rows_used,
    COUNT(*) FILTER (WHERE driver_pay > base_passenger_fare)                    AS n_pay_gt_fare,
    ROUND(100.0 * COUNT(*) FILTER (WHERE driver_pay > base_passenger_fare) / COUNT(*), 3) AS pct_pay_gt_fare,
    ROUND(quantile_cont(driver_pay / base_passenger_fare, 0.01), 3)             AS p01,
    ROUND(quantile_cont(driver_pay / base_passenger_fare, 0.25), 3)             AS p25,
    ROUND(quantile_cont(driver_pay / base_passenger_fare, 0.50), 3)             AS p50,
    ROUND(quantile_cont(driver_pay / base_passenger_fare, 0.75), 3)             AS p75,
    ROUND(quantile_cont(driver_pay / base_passenger_fare, 0.99), 3)             AS p99
FROM trips_scoped
WHERE base_passenger_fare > 0
  AND driver_pay >= 0
GROUP BY 1
ORDER BY 1;

-- name: pay_ratio_tails
-- Tails of pay per mile and pay per minute (D3: NULLIF guards zero denominators; the WHERE also keeps them out).
-- Each list is [p0.1, p1, p50, p99, p99.9] in that order.
SELECT
    hvfhs_license_num,
    COUNT(*)                                                                         AS n_rows_used,
    quantile_cont(driver_pay / NULLIF(trip_miles, 0), [0.001, 0.01, 0.5, 0.99, 0.999]) AS pay_per_mile_q,
    MAX(driver_pay / NULLIF(trip_miles, 0))                                          AS pay_per_mile_max,
    quantile_cont(driver_pay / NULLIF(trip_time / 60.0, 0), [0.001, 0.01, 0.5, 0.99, 0.999]) AS pay_per_min_q,
    MAX(driver_pay / NULLIF(trip_time / 60.0, 0))                                    AS pay_per_min_max
FROM trips_scoped
WHERE trip_miles > 0
  AND trip_time > 0
  AND driver_pay >= 0
GROUP BY 1
ORDER BY 1;

-- name: implied_speed_buckets
-- Implied speed = trip_miles / (trip_time in hours), for rows with trip_time > 0. Zero-time rows are counted in nonpositive_counts.
WITH s AS (
    SELECT
        hvfhs_license_num,
        trip_miles / (trip_time / 3600.0) AS mph
    FROM trips_scoped
    WHERE trip_time > 0
)
SELECT
    hvfhs_license_num,
    CASE WHEN mph = 0   THEN '0: zero mph (zero miles)'
         WHEN mph < 1   THEN '1: under 1 mph'
         WHEN mph < 5   THEN '2: 1 to 5 mph'
         WHEN mph < 15  THEN '3: 5 to 15 mph'
         WHEN mph < 30  THEN '4: 15 to 30 mph'
         WHEN mph < 60  THEN '5: 30 to 60 mph'
         WHEN mph < 100 THEN '6: 60 to 100 mph'
         ELSE                '7: 100 mph or more' END                                AS mph_bucket,
    COUNT(*)                                                                         AS n_rows,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY hvfhs_license_num), 3) AS pct_of_company
FROM s
GROUP BY 1, 2
ORDER BY 1, 2;