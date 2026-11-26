-- Stage 1E: trips_clean = trips_scoped + analysis flags + guarded metrics. NO ROWS ARE REMOVED HERE.
-- Four categories are kept distinct:
--   (1) excluded from WAIT statistics only: is_wait_valid = FALSE (D11)
--   (2) FLAGGED for analysis: flag_* columns (rows stay in every analysis unless a later rule says otherwise)
--   (3) METRIC guards: a ratio is NULL when its denominator is zero (D3), so that row simply has no ratio
--   (4) REMOVED globally: none. A global removal needs its own evidence in the sensitivity step.
-- v2 adds three in_* eligibility columns. They only NAME the rules decided in D14: they add no rule and remove no rows.

-- name: create_trips_clean
CREATE OR REPLACE VIEW trips_clean AS
SELECT
    t.*,
    (t.wait_seconds >= 0)                                                                   AS is_wait_valid,
    t.wait_seconds / 60.0                                                                   AS wait_minutes,
    t.driver_pay / NULLIF(t.trip_miles, 0)                                                  AS pay_per_mile,
    t.driver_pay / NULLIF(t.trip_time / 60.0, 0)                                            AS pay_per_minute,
    (t.trip_miles = 0)                                                                      AS flag_zero_miles,
    (t.trip_time = 0)                                                                       AS flag_zero_time,
    (t.base_passenger_fare < 0)                                                             AS flag_fare_negative,
    (t.base_passenger_fare = 0)                                                             AS flag_fare_zero,
    (t.driver_pay < 0)                                                                      AS flag_pay_negative,
    (t.driver_pay = 0)                                                                      AS flag_pay_zero,
    (t.trip_miles = 0 OR t.trip_time = 0 OR t.base_passenger_fare <= 0 OR t.driver_pay <= 0) AS flag_any_money,
    (t.driver_pay > t.base_passenger_fare)                                                  AS flag_pay_gt_fare,
    COALESCE(t.trip_miles / NULLIF(t.trip_time / 3600.0, 0) >= 100, FALSE)                  AS flag_speed_ge_100mph,
    (t.PULocationID IN (1, 265))                                                            AS flag_pickup_outside_nyc,
    COALESCE(t.hvfhs_license_num = 'HV0003' AND t.on_scene_datetime < t.request_datetime, FALSE)
                                                                                            AS flag_uber_on_scene_before_request,
    (t.hvfhs_license_num = 'HV0005' AND t.shared_match_flag = 'Y' AND t.shared_request_flag = 'N')
                                                                                            AS flag_lyft_shared_match_no_request,
    (t.PULocationID NOT IN (1, 265) AND t.wait_seconds >= 0)                                AS in_geo_wait_tables,
    (t.trip_miles > 0)                                                                      AS in_pay_per_mile,
    (t.trip_time > 0)                                                                       AS in_pay_per_minute
FROM trips_scoped t;

-- name: rules_counts
-- Candidate-rules inventory by company (wide). The notebook turns it into counts and percentages.
-- pay_gt_fare is information only: base fare is one fare component, so pay above it is not a defect (D4).
SELECT
    hvfhs_license_num,
    COUNT(*)                                                       AS n_rows,
    COUNT(*) FILTER (WHERE NOT is_wait_valid)                      AS wait_negative,
    COUNT(*) FILTER (WHERE flag_pickup_outside_nyc)                AS pickup_outside_nyc,
    COUNT(*) FILTER (WHERE flag_zero_miles)                        AS zero_miles,
    COUNT(*) FILTER (WHERE flag_zero_time)                         AS zero_time,
    COUNT(*) FILTER (WHERE flag_fare_negative)                     AS fare_negative,
    COUNT(*) FILTER (WHERE flag_fare_zero)                         AS fare_zero,
    COUNT(*) FILTER (WHERE flag_pay_negative)                      AS pay_negative,
    COUNT(*) FILTER (WHERE flag_pay_zero)                          AS pay_zero,
    COUNT(*) FILTER (WHERE flag_any_money)                         AS any_money_flag,
    COUNT(*) FILTER (WHERE flag_speed_ge_100mph)                   AS speed_ge_100mph,
    COUNT(*) FILTER (WHERE flag_pay_gt_fare)                       AS pay_gt_fare_info_only,
    COUNT(*) FILTER (WHERE flag_uber_on_scene_before_request)      AS uber_on_scene_before_request,
    COUNT(*) FILTER (WHERE flag_lyft_shared_match_no_request)      AS lyft_shared_match_no_request
FROM trips_clean
GROUP BY 1
ORDER BY 1;

-- name: rules_waterfall
-- Each row is counted ONCE, under the first rule it hits in this order, so the counts add up to 20,405,666.
-- This is an accounting view of overlaps, not a statement that these rows are removed.
-- '0_no_candidate_rule_matched' means none of these five candidate rules matched. Informational flags
-- (pay above fare, Uber on_scene before request, Lyft shared exception, speed) can still be set on those rows.
WITH a AS (
    SELECT
        hvfhs_license_num,
        CASE WHEN NOT is_wait_valid                          THEN '1_wait_negative (D11)'
             WHEN flag_pickup_outside_nyc                    THEN '2_pickup_outside_nyc'
             WHEN flag_zero_miles OR flag_zero_time          THEN '3_zero_miles_or_time'
             WHEN flag_fare_negative OR flag_fare_zero       THEN '4_fare_zero_or_negative'
             WHEN flag_pay_negative OR flag_pay_zero         THEN '5_pay_zero_or_negative'
             ELSE                                                 '0_no_candidate_rule_matched'
        END AS first_rule
    FROM trips_clean
)
SELECT
    first_rule,
    COUNT(*)                                                  AS n_rows,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4)        AS pct_of_all,
    COUNT(*) FILTER (WHERE hvfhs_license_num = 'HV0003')      AS n_uber,
    COUNT(*) FILTER (WHERE hvfhs_license_num = 'HV0005')      AS n_lyft
FROM a
GROUP BY 1
ORDER BY 1;

-- name: rules_overlap
-- Which flags co-occur? Flag signatures for rows with at least one flag (top 25).
SELECT
    NOT is_wait_valid          AS wait_negative,
    flag_pickup_outside_nyc    AS outside_nyc,
    flag_zero_miles,
    flag_zero_time,
    flag_fare_negative,
    flag_fare_zero,
    flag_pay_negative,
    flag_pay_zero,
    COUNT(*)                   AS n_rows
FROM trips_clean
WHERE NOT is_wait_valid OR flag_pickup_outside_nyc OR flag_any_money
GROUP BY ALL
ORDER BY n_rows DESC
LIMIT 25;

-- name: analysis_family_rows
-- Rows available to each analysis family under a MINIMUM rule (only what the metric needs to exist)
-- and a STRICT rule (also drop every money-flagged row). The sensitivity file shows whether the gap matters.
SELECT 'F1 volume: all rows' AS family, COUNT(*) AS n_rows FROM trips_clean
UNION ALL SELECT 'F2 wait statistics: is_wait_valid (D11)',                 COUNT(*) FILTER (WHERE is_wait_valid) FROM trips_clean
UNION ALL SELECT 'F3 zone/borough wait tables: valid wait, pickup in five boroughs',
                                                                           COUNT(*) FILTER (WHERE is_wait_valid AND NOT flag_pickup_outside_nyc) FROM trips_clean
UNION ALL SELECT 'F4 pay level: all rows (minimum)',                        COUNT(*) FROM trips_clean
UNION ALL SELECT 'F4 pay level: no money flag (strict)',                    COUNT(*) FILTER (WHERE NOT flag_any_money) FROM trips_clean
UNION ALL SELECT 'F5 pay per mile: miles > 0 (minimum)',                    COUNT(*) FILTER (WHERE NOT flag_zero_miles) FROM trips_clean
UNION ALL SELECT 'F5 pay per mile: no money flag (strict)',                 COUNT(*) FILTER (WHERE NOT flag_any_money) FROM trips_clean
UNION ALL SELECT 'F6 pay per minute: time > 0 (minimum)',                   COUNT(*) FILTER (WHERE NOT flag_zero_time) FROM trips_clean
UNION ALL SELECT 'F6 pay per minute: no money flag (strict)',               COUNT(*) FILTER (WHERE NOT flag_any_money) FROM trips_clean
UNION ALL SELECT 'F7 wait x pay joint: valid wait (minimum)',               COUNT(*) FILTER (WHERE is_wait_valid) FROM trips_clean
UNION ALL SELECT 'F7 wait x pay joint: valid wait and no money flag (strict)',
                                                                           COUNT(*) FILTER (WHERE is_wait_valid AND NOT flag_any_money) FROM trips_clean
ORDER BY family;

-- name: final_reconciliation
-- Assertions for the final rules (D14). Expected values are in the comments; "derived" = from the Stage 1E overlap table.
SELECT
    COUNT(*)                                                            AS total_rows,                -- 20,405,666
    COUNT(*) FILTER (WHERE is_wait_valid)                               AS wait_stats_rows,           -- 20,205,878
    COUNT(*) FILTER (WHERE in_geo_wait_tables)                          AS geo_wait_rows,             -- 20,205,118
    COUNT(*) FILTER (WHERE in_pay_per_mile)                             AS pay_per_mile_rows,         -- 20,403,060
    COUNT(*) FILTER (WHERE in_pay_per_minute)                           AS pay_per_minute_rows,       -- 20,405,662
    COUNT(pay_per_mile)                                                 AS pay_per_mile_non_null,     -- equals pay_per_mile_rows
    COUNT(pay_per_minute)                                               AS pay_per_minute_non_null,   -- equals pay_per_minute_rows
    COUNT(*) FILTER (WHERE (pay_per_mile IS NULL)   = in_pay_per_mile)   AS ppm_guard_mismatch,        -- 0
    COUNT(*) FILTER (WHERE (pay_per_minute IS NULL) = in_pay_per_minute) AS ppmin_guard_mismatch,      -- 0
    COUNT(*) FILTER (WHERE is_wait_valid AND in_pay_per_mile)           AS joint_wait_ppm_rows,       -- 20,203,530 (derived)
    COUNT(*) FILTER (WHERE is_wait_valid AND in_pay_per_minute)         AS joint_wait_ppmin_rows,     -- 20,205,875 (derived)
    COUNT(*) FILTER (WHERE base_passenger_fare > 0 AND driver_pay >= 0) AS pay_to_fare_rows,          -- 20,388,149 (derived)
    COUNT(*) FILTER (WHERE flag_speed_ge_100mph)                        AS speed_flag_rows            -- 2
FROM trips_clean;

-- name: final_counts_by_company
-- Rows per analysis family by company (needed for n_valid and % excluded in every wait table, D12).
SELECT
    hvfhs_license_num,
    COUNT(*)                                                            AS volume_rows,
    COUNT(*) FILTER (WHERE is_wait_valid)                               AS wait_stats_rows,           -- Uber 15,235,488; Lyft 4,970,390
    COUNT(*) FILTER (WHERE in_geo_wait_tables)                          AS geo_wait_rows,             -- Uber 15,234,971; Lyft 4,970,147 (derived)
    COUNT(*) FILTER (WHERE in_pay_per_mile)                             AS pay_per_mile_rows,         -- Uber 15,354,057; Lyft 5,049,003 (derived)
    COUNT(*) FILTER (WHERE in_pay_per_minute)                           AS pay_per_minute_rows,       -- Uber 15,356,451; Lyft 5,049,211 (derived)
    COUNT(*) FILTER (WHERE is_wait_valid AND in_pay_per_mile)           AS joint_wait_ppm_rows,
    COUNT(*) FILTER (WHERE is_wait_valid AND in_pay_per_minute)         AS joint_wait_ppmin_rows
FROM trips_clean
GROUP BY 1
ORDER BY 1;