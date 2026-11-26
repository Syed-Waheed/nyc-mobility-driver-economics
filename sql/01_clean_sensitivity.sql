-- Stage 1E sensitivity checks on trips_clean. READ-ONLY.
-- Question for each flag group: if we drop the flagged rows from a metric, does the metric move?
-- Pre-registered reading (before seeing results): a flag stays "flag only" unless
--   (a) the metric cannot be defined for the row (zero denominator), or
--   (b) dropping the flagged rows moves p10, p50 or p90 by 1% or more.
-- Quantile lists are [p10, p50, p90]. Heavier query first; run it alone if the Mac gets warm.

-- name: money_sensitivity
-- "all" = every row where the metric exists (ratios are NULL when the denominator is zero, per D3).
-- "strict" = also drop every row with any money flag (zero or negative fare or pay, zero miles, zero time).
SELECT
    hvfhs_license_num,
    COUNT(*)                                                                                      AS n_rows,
    COUNT(*) FILTER (WHERE flag_any_money)                                                        AS n_flagged,
    CAST(quantile_cont(driver_pay,       [0.1, 0.5, 0.9]) AS DECIMAL(12,3)[])                                         AS pay_q_all,
    CAST(quantile_cont(driver_pay,       [0.1, 0.5, 0.9]) FILTER (WHERE NOT flag_any_money) AS DECIMAL(12,3)[])       AS pay_q_strict,
    CAST(quantile_cont(pay_per_mile,     [0.1, 0.5, 0.9]) AS DECIMAL(12,3)[])                                         AS ppm_q_all,
    CAST(quantile_cont(pay_per_mile,     [0.1, 0.5, 0.9]) FILTER (WHERE NOT flag_any_money) AS DECIMAL(12,3)[])       AS ppm_q_strict,
    CAST(quantile_cont(pay_per_minute,   [0.1, 0.5, 0.9]) AS DECIMAL(12,3)[])                                         AS ppmin_q_all,
    CAST(quantile_cont(pay_per_minute,   [0.1, 0.5, 0.9]) FILTER (WHERE NOT flag_any_money) AS DECIMAL(12,3)[])       AS ppmin_q_strict
FROM trips_clean
GROUP BY 1
ORDER BY 1;

-- name: outside_nyc_pickup_effect
-- The 774 pickups in zones 1 (EWR) and 265 (Outside of NYC): do they move company-level wait statistics?
SELECT
    hvfhs_license_num,
    COUNT(*) FILTER (WHERE flag_pickup_outside_nyc)                                                       AS n_outside,
    COUNT(*) FILTER (WHERE flag_pickup_outside_nyc AND is_wait_valid)                                     AS n_outside_valid_wait,
    ROUND(quantile_cont(wait_minutes, 0.5) FILTER (WHERE is_wait_valid), 3)                               AS median_all_valid,
    ROUND(quantile_cont(wait_minutes, 0.5) FILTER (WHERE is_wait_valid AND NOT flag_pickup_outside_nyc), 3) AS median_nyc_only,
    ROUND(quantile_cont(wait_minutes, 0.9) FILTER (WHERE is_wait_valid), 3)                               AS p90_all_valid,
    ROUND(quantile_cont(wait_minutes, 0.9) FILTER (WHERE is_wait_valid AND NOT flag_pickup_outside_nyc), 3) AS p90_nyc_only,
    ROUND(quantile_cont(wait_minutes, 0.5) FILTER (WHERE is_wait_valid AND flag_pickup_outside_nyc), 3)   AS median_outside_only
FROM trips_clean
GROUP BY 1
ORDER BY 1;