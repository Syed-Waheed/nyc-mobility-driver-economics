-- Stage 2F: driver-pay analysis. READ-ONLY. Descriptive and association language only: no model, no inferential test (later stage).
-- DEFINITIONS (reused, not re-decided):
--   Unit = one HVFHV trip record. driver_pay = the recorded field "total driver pay, excluding tolls/tips and net of commission,
--   surcharges or taxes". It is NOT total earnings, take-home income or an hourly wage: it ignores tips, tolls, waiting and empty driving
--   between trips, idle time, expenses and any incentive paid outside the field.
--   trip_miles = passenger-trip miles. trip_time is in SECONDS (dictionary; D3 divides by 60); trip_minutes = trip_time / 60.
--   pay_per_mile = driver_pay / NULLIF(trip_miles, 0); pay_per_minute = driver_pay / NULLIF(trip_time / 60.0, 0) (D3).
--   pay_per_minute is pay per PASSENGER-trip minute; it is not hourly income.
--   Ratio eligibility = existing flags in_pay_per_mile (trip_miles > 0) and in_pay_per_minute (trip_time > 0); other rows have no ratio.
--   Wait = pickup - request (D2); wait bands use VALID waits only (D11). Money anomalies are flag-only (D16): no trip is removed globally.
--   base_passenger_fare is a fare field, not a verified total passenger charge (D4): no take rate is computed.
-- POPULATIONS (D14): company totals, time tables and pay tables use all scoped rows (20,405,666); geography tables use five-borough
--   pickups (20,404,892, outside-NYC pickups are not ranked as a borough or zone, D15); wait-band tables use valid waits (20,205,878).
-- PRE-SET BANDS (written before any result): distance (miles) 0 | <1 | 1-<2 | 2-<3 | 3-<5 | 5-<10 | 10-<20 | 20+;
--   duration (minutes of trip_time) 0 | <5 | 5-<10 | 10-<15 | 15-<20 | 20-<30 | 30-<45 | 45+;
--   valid wait (minutes) <2 | 2-<4 | 4-<6 | 6-<8 | 8-<10 | 10-<15 | 15+.
--   Sample tiers for zone/band cells: 1_very_small < 100 | 2_small 100-999 | 3_adequate >= 1,000. Only adequate zones are ranked.
-- CONFOUNDING TO KEEP IN MIND: pay rises mechanically with distance and duration, so a pay-vs-wait pattern is only read WITHIN
--   distance bands (pay_by_wait_within_distance). Even then it is an association, not an effect of waiting.
-- Expensive queries each scan the 20M rows once; run them one notebook cell at a time.

-- name: create_trips_pay
-- VIEW (no data copied) adding bands and keeping only the columns this stage needs.
CREATE OR REPLACE VIEW trips_pay AS
SELECT
    f.company, f.PULocationID, f.pu_borough, f.pu_zone, f.request_hour, f.request_isodow,
    CASE WHEN f.request_hour < 6  THEN '1_overnight_0-5'
         WHEN f.request_hour < 10 THEN '2_morning_6-9'
         WHEN f.request_hour < 16 THEN '3_midday_10-15'
         WHEN f.request_hour < 20 THEN '4_evening_peak_16-19'
         ELSE                          '5_late_evening_20-23' END      AS daypart,
    CASE WHEN f.request_isodow <= 5 THEN 'Mon-Fri' ELSE 'Sat-Sun' END   AS day_type,
    f.driver_pay, f.base_passenger_fare, f.trip_miles,
    f.trip_time / 60.0                                                  AS trip_minutes,
    f.pay_per_mile, f.pay_per_minute,
    f.wait_minutes, f.is_wait_valid,
    f.in_pay_per_mile, f.in_pay_per_minute, f.flag_pickup_outside_nyc,
    f.flag_pay_negative, f.flag_pay_zero, f.flag_fare_negative, f.flag_fare_zero, f.flag_any_money, f.flag_pay_gt_fare,
    (f.pu_zone ILIKE '%airport%')                                       AS is_airport_zone,
    CASE WHEN f.trip_miles = 0 THEN '0_zero miles'
         WHEN f.trip_miles < 1  THEN '1_<1 mi'
         WHEN f.trip_miles < 2  THEN '2_1-<2 mi'
         WHEN f.trip_miles < 3  THEN '3_2-<3 mi'
         WHEN f.trip_miles < 5  THEN '4_3-<5 mi'
         WHEN f.trip_miles < 10 THEN '5_5-<10 mi'
         WHEN f.trip_miles < 20 THEN '6_10-<20 mi'
         ELSE                        '7_20+ mi' END                     AS distance_band,
    CASE WHEN f.trip_time = 0    THEN '0_zero time'
         WHEN f.trip_time < 300  THEN '1_<5 min'
         WHEN f.trip_time < 600  THEN '2_5-<10 min'
         WHEN f.trip_time < 900  THEN '3_10-<15 min'
         WHEN f.trip_time < 1200 THEN '4_15-<20 min'
         WHEN f.trip_time < 1800 THEN '5_20-<30 min'
         WHEN f.trip_time < 2700 THEN '6_30-<45 min'
         ELSE                         '7_45+ min' END                   AS duration_band,
    CASE WHEN NOT f.is_wait_valid   THEN NULL
         WHEN f.wait_minutes < 2    THEN '1_<2 min'
         WHEN f.wait_minutes < 4    THEN '2_2-<4 min'
         WHEN f.wait_minutes < 6    THEN '3_4-<6 min'
         WHEN f.wait_minutes < 8    THEN '4_6-<8 min'
         WHEN f.wait_minutes < 10   THEN '5_8-<10 min'
         WHEN f.wait_minutes < 15   THEN '6_10-<15 min'
         ELSE                            '7_15+ min' END                AS wait_band
FROM trips_features f;

-- name: pay_reconcile
-- Expected (Stage 1 / 1E / 2B): rows Uber 15,356,455, Lyft 5,049,211, All 20,405,666; five-borough 15,355,926 / 5,048,966 / 20,404,892;
-- pay null 0; negative pay Uber 313, Lyft 0; zero pay Uber 4,225, Lyft 0; zero miles 2,398 / 208; zero time 4 / 0;
-- in_pay_per_mile 15,354,057 / 5,049,003; in_pay_per_minute 15,356,451 / 5,049,211; valid wait 15,235,488 / 4,970,390 (All 20,205,878);
-- valid wait and pay_per_mile 15,233,331 / 4,970,199; valid wait and pay_per_minute 15,235,485 / 4,970,390;
-- negative base fare 2,393 / 34; driver pay above base fare 2,358,327 / 318,745.
SELECT
    CASE company WHEN 'Uber' THEN 'Uber' WHEN 'Lyft' THEN 'Lyft' ELSE 'All' END               AS company,
    COUNT(*)                                                                                  AS n_rows,
    COUNT(*) FILTER (WHERE NOT flag_pickup_outside_nyc)                                       AS n_five_borough,
    COUNT(*) FILTER (WHERE driver_pay IS NULL)                                                AS n_pay_null,
    COUNT(*) FILTER (WHERE flag_pay_negative)                                                 AS n_pay_negative,
    COUNT(*) FILTER (WHERE flag_pay_zero)                                                     AS n_pay_zero,
    COUNT(*) FILTER (WHERE driver_pay > 0)                                                    AS n_pay_positive,
    COUNT(*) FILTER (WHERE trip_miles = 0)                                                    AS n_zero_miles,
    COUNT(*) FILTER (WHERE trip_minutes = 0)                                                  AS n_zero_time,
    COUNT(*) FILTER (WHERE in_pay_per_mile)                                                   AS n_in_pay_per_mile,
    COUNT(*) FILTER (WHERE in_pay_per_minute)                                                 AS n_in_pay_per_minute,
    COUNT(*) FILTER (WHERE is_wait_valid)                                                     AS n_valid_wait,
    COUNT(*) FILTER (WHERE is_wait_valid AND in_pay_per_mile)                                 AS n_valid_wait_and_ppm,
    COUNT(*) FILTER (WHERE is_wait_valid AND in_pay_per_minute)                               AS n_valid_wait_and_ppmin,
    COUNT(*) FILTER (WHERE flag_fare_negative)                                                AS n_fare_negative,
    COUNT(*) FILTER (WHERE flag_pay_gt_fare)                                                  AS n_pay_gt_fare
FROM trips_pay
GROUP BY ROLLUP(company)
ORDER BY CASE company WHEN 'Uber' THEN 1 WHEN 'Lyft' THEN 2 ELSE 3 END;

-- name: pay_distribution_by_company
-- Driver pay per trip, all scoped rows. Cross-check with Stage 1E ("all rows"): pay p10 / p50 / p90 Uber 5.67 / 14.16 / 37.66, Lyft 5.47 / 13.32 / 34.56.
WITH q AS (
    SELECT
        company,
        COUNT(*)           AS n,
        AVG(driver_pay)    AS mean_pay,
        MIN(driver_pay)    AS min_pay,
        MAX(driver_pay)    AS max_pay,
        quantile_cont(driver_pay, [0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99]) AS qs
    FROM trips_pay
    GROUP BY company
)
SELECT
    company, n,
    ROUND(mean_pay, 3) AS mean_pay,
    ROUND(min_pay, 2)  AS min_pay,
    ROUND(qs[1], 2) AS p01, ROUND(qs[2], 2) AS p05, ROUND(qs[3], 2) AS p10, ROUND(qs[4], 2) AS p25,
    ROUND(qs[5], 2) AS p50, ROUND(qs[6], 2) AS p75, ROUND(qs[7], 2) AS p90, ROUND(qs[8], 2) AS p95,
    ROUND(qs[9], 2) AS p99,
    ROUND(max_pay, 2)  AS max_pay
FROM q
ORDER BY company DESC;

-- name: pay_mean_sensitivity
-- How much do extremes move the mean? Mean vs median vs 1%-99% trimmed mean vs mean of positive-pay trips, and how much of
-- total pay comes from the top 1% of trips (compare with 1% of trips).
WITH qq AS (
    SELECT company, quantile_cont(driver_pay, [0.01, 0.99]) AS qs FROM trips_pay GROUP BY company
),
b AS (SELECT company, qs[1] AS p01, qs[2] AS p99 FROM qq)
SELECT
    p.company,
    COUNT(*)                                                                                   AS n,
    ROUND(AVG(p.driver_pay), 3)                                                                AS mean_all,
    ROUND(quantile_cont(p.driver_pay, 0.5), 3)                                                 AS median,
    ROUND(AVG(p.driver_pay) FILTER (WHERE p.driver_pay >= b.p01 AND p.driver_pay <= b.p99), 3) AS mean_trimmed_1_99,
    ROUND(AVG(p.driver_pay) FILTER (WHERE p.driver_pay > 0), 3)                                AS mean_positive_pay_only,
    ROUND(MAX(p.driver_pay), 2)                                                                AS max_pay,
    ROUND(100.0 * SUM(p.driver_pay) FILTER (WHERE p.driver_pay > b.p99) / SUM(p.driver_pay), 2) AS pct_of_total_pay_from_top_1pct_trips,
    ROUND(100.0 * COUNT(*) FILTER (WHERE p.driver_pay > b.p99) / COUNT(*), 2)                  AS pct_of_trips_in_top_1pct
FROM trips_pay p
JOIN b ON b.company = p.company
GROUP BY p.company, b.p01, b.p99
ORDER BY p.company DESC;

-- name: ppm_distribution_by_company
-- Pay per mile on ELIGIBLE rows only (trip_miles > 0). Cross-check (1E, all eligible rows): p10 / p50 / p90 Uber 2.817 / 4.596 / 7.836, Lyft 2.984 / 4.731 / 7.717.
-- Expected eligible rows: Uber 15,354,057, Lyft 5,049,003. The maximum is shown only to illustrate denominator artifacts; do not read it.
WITH q AS (
    SELECT
        company,
        COUNT(*)                                       AS n_rows,
        COUNT(*) FILTER (WHERE in_pay_per_mile)        AS n_eligible,
        AVG(pay_per_mile) FILTER (WHERE in_pay_per_mile) AS mean_ppm,
        MAX(pay_per_mile) FILTER (WHERE in_pay_per_mile) AS max_ppm,
        quantile_cont(pay_per_mile, [0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99]) FILTER (WHERE in_pay_per_mile) AS qs
    FROM trips_pay
    GROUP BY company
)
SELECT
    company, n_rows, n_eligible, n_rows - n_eligible AS n_no_ratio_zero_miles,
    ROUND(mean_ppm, 3) AS mean_ppm,
    ROUND(qs[1], 3) AS p01, ROUND(qs[2], 3) AS p05, ROUND(qs[3], 3) AS p10, ROUND(qs[4], 3) AS p25,
    ROUND(qs[5], 3) AS p50, ROUND(qs[6], 3) AS p75, ROUND(qs[7], 3) AS p90, ROUND(qs[8], 3) AS p95,
    ROUND(qs[9], 3) AS p99,
    ROUND(max_ppm, 2) AS max_ppm
FROM q
ORDER BY company DESC;

-- name: ppmin_distribution_by_company
-- Pay per PASSENGER-trip minute on ELIGIBLE rows (trip_time > 0). Cross-check (1E): p10 / p50 / p90 Uber 0.758 / 0.929 / 1.385, Lyft 0.755 / 0.893 / 1.290.
-- Expected eligible rows: Uber 15,356,451, Lyft 5,049,211. Not an hourly wage.
WITH q AS (
    SELECT
        company,
        COUNT(*)                                          AS n_rows,
        COUNT(*) FILTER (WHERE in_pay_per_minute)         AS n_eligible,
        AVG(pay_per_minute) FILTER (WHERE in_pay_per_minute) AS mean_ppmin,
        MAX(pay_per_minute) FILTER (WHERE in_pay_per_minute) AS max_ppmin,
        quantile_cont(pay_per_minute, [0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99]) FILTER (WHERE in_pay_per_minute) AS qs
    FROM trips_pay
    GROUP BY company
)
SELECT
    company, n_rows, n_eligible, n_rows - n_eligible AS n_no_ratio_zero_time,
    ROUND(mean_ppmin, 3) AS mean_ppmin,
    ROUND(qs[1], 3) AS p01, ROUND(qs[2], 3) AS p05, ROUND(qs[3], 3) AS p10, ROUND(qs[4], 3) AS p25,
    ROUND(qs[5], 3) AS p50, ROUND(qs[6], 3) AS p75, ROUND(qs[7], 3) AS p90, ROUND(qs[8], 3) AS p95,
    ROUND(qs[9], 3) AS p99,
    ROUND(max_ppmin, 2) AS max_ppmin
FROM q
ORDER BY company DESC;

-- name: ratio_denominator_diagnostics
-- Why extreme ratios appear: tiny denominators. Ratio level and tail by denominator size, among ELIGIBLE rows.
SELECT
    'pay_per_mile' AS metric,
    company,
    CASE WHEN trip_miles < 0.1  THEN '1_<0.1 mi'
         WHEN trip_miles < 0.25 THEN '2_0.1-<0.25 mi'
         WHEN trip_miles < 0.5  THEN '3_0.25-<0.5 mi'
         WHEN trip_miles < 1    THEN '4_0.5-<1 mi'
         ELSE                        '5_1+ mi' END                   AS denominator_bucket,
    COUNT(*)                                                         AS n,
    ROUND(quantile_cont(pay_per_mile, 0.50), 3)                      AS ratio_p50,
    ROUND(quantile_cont(pay_per_mile, 0.99), 3)                      AS ratio_p99,
    ROUND(MAX(pay_per_mile), 2)                                      AS ratio_max
FROM trips_pay
WHERE in_pay_per_mile
GROUP BY company, 3
UNION ALL
SELECT
    'pay_per_minute',
    company,
    CASE WHEN trip_minutes < 0.5 THEN '1_<0.5 min'
         WHEN trip_minutes < 1   THEN '2_0.5-<1 min'
         WHEN trip_minutes < 2   THEN '3_1-<2 min'
         WHEN trip_minutes < 5   THEN '4_2-<5 min'
         ELSE                         '5_5+ min' END,
    COUNT(*),
    ROUND(quantile_cont(pay_per_minute, 0.50), 3),
    ROUND(quantile_cont(pay_per_minute, 0.99), 3),
    ROUND(MAX(pay_per_minute), 2)
FROM trips_pay
WHERE in_pay_per_minute
GROUP BY company, 3
ORDER BY metric, company DESC, denominator_bucket;

-- name: pay_by_distance_band
-- Pay and guarded ratios by trip-distance band and company, all scoped rows (ratios only where eligible).
-- Trade-off to look for: pay per TRIP rises with distance, pay per MILE and per MINUTE move differently.
SELECT
    company, distance_band,
    COUNT(*)                                                                         AS n,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY company), 2)           AS pct_of_company,
    ROUND(quantile_cont(driver_pay, 0.25), 2)                                        AS pay_p25,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(driver_pay, 0.75), 2)                                        AS pay_p75,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles,
    ROUND(quantile_cont(trip_minutes, 0.50), 2)                                      AS median_minutes
FROM trips_pay
GROUP BY company, distance_band
ORDER BY company DESC, distance_band;

-- name: pay_by_duration_band
SELECT
    company, duration_band,
    COUNT(*)                                                                         AS n,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY company), 2)           AS pct_of_company,
    ROUND(quantile_cont(driver_pay, 0.25), 2)                                        AS pay_p25,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(driver_pay, 0.75), 2)                                        AS pay_p75,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles,
    ROUND(quantile_cont(trip_minutes, 0.50), 2)                                      AS median_minutes
FROM trips_pay
GROUP BY company, duration_band
ORDER BY company DESC, duration_band;

-- name: pay_by_wait_band
-- Pay by rider-wait band (VALID waits only, D11). Median trip miles and minutes are shown because trip length confounds pay.
SELECT
    company, wait_band,
    COUNT(*)                                                                         AS n,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY company), 2)           AS pct_of_company_valid,
    ROUND(quantile_cont(driver_pay, 0.25), 2)                                        AS pay_p25,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(driver_pay, 0.75), 2)                                        AS pay_p75,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles,
    ROUND(quantile_cont(trip_minutes, 0.50), 2)                                      AS median_minutes
FROM trips_pay
WHERE is_wait_valid
GROUP BY company, wait_band
ORDER BY company DESC, wait_band;

-- name: pay_by_wait_within_distance
-- The responsible read of pay vs wait: compare wait bands INSIDE the same distance band. Zero-mile trips are left out here.
-- Cells with n < 1,000 are flagged and should not be interpreted.
SELECT
    company, distance_band, wait_band,
    COUNT(*)                                                                         AS n,
    CASE WHEN COUNT(*) < 100 THEN '1_very_small' WHEN COUNT(*) < 1000 THEN '2_small' ELSE '3_adequate' END AS sample_tier,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50
FROM trips_pay
WHERE is_wait_valid AND distance_band <> '0_zero miles'
GROUP BY company, distance_band, wait_band
ORDER BY company DESC, distance_band, wait_band;

-- name: pay_by_borough_company
-- Five-borough pickups only (D15). 'All' = both companies pooled.
SELECT
    COALESCE(company, 'All')                                                         AS company,
    pu_borough,
    COUNT(*)                                                                         AS n,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles,
    ROUND(quantile_cont(trip_minutes, 0.50), 2)                                      AS median_minutes
FROM trips_pay
WHERE NOT flag_pickup_outside_nyc
GROUP BY GROUPING SETS ((pu_borough), (company, pu_borough))
ORDER BY CASE COALESCE(company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, pu_borough;

-- name: pay_by_zone
-- Pooled zone table (five-borough pickups). pct_uber shows company mix. ppm_p50_2_5mi = median pay per mile among 2-<5 mile trips only
-- (a rough control for trip length), reported only where that subset has >= 1,000 trips. Ranks (1 = highest median pay per mile) exist
-- only for 3_adequate zones.
WITH z AS (
    SELECT
        PULocationID, pu_borough, pu_zone,
        COUNT(*)                                                                         AS n,
        ROUND(100.0 * COUNT(*) FILTER (WHERE company = 'Uber') / COUNT(*), 1)            AS pct_uber,
        ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
        ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
        ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
        ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles,
        ROUND(quantile_cont(trip_minutes, 0.50), 2)                                      AS median_minutes,
        COUNT(*) FILTER (WHERE trip_miles >= 2 AND trip_miles < 5)                       AS n_2_5mi,
        quantile_cont(pay_per_mile, 0.50) FILTER (WHERE trip_miles >= 2 AND trip_miles < 5 AND in_pay_per_mile) AS ppm_p50_2_5mi_raw,
        BOOL_OR(is_airport_zone)                                                         AS is_airport_zone
    FROM trips_pay
    WHERE NOT flag_pickup_outside_nyc
    GROUP BY PULocationID, pu_borough, pu_zone
),
t AS (
    SELECT *, CASE WHEN n < 100 THEN '1_very_small' WHEN n < 1000 THEN '2_small' ELSE '3_adequate' END AS sample_tier FROM z
)
SELECT
    PULocationID, pu_borough, pu_zone, is_airport_zone, n, sample_tier, pct_uber,
    pay_p50, ppm_p50, ppmin_p50, median_miles, median_minutes,
    n_2_5mi,
    CASE WHEN n_2_5mi >= 1000 THEN ROUND(ppm_p50_2_5mi_raw, 3) END                       AS ppm_p50_2_5mi,
    CASE WHEN sample_tier = '3_adequate'
         THEN RANK() OVER (PARTITION BY sample_tier ORDER BY ppm_p50 DESC) END           AS rank_ppm_p50
FROM t
ORDER BY pu_borough, n DESC;

-- name: pay_by_zone_company
-- Zone x company, for Tableau filters. Same tiers; no ranks.
SELECT
    company, PULocationID, pu_borough, pu_zone,
    COUNT(*)                                                                         AS n,
    CASE WHEN COUNT(*) < 100 THEN '1_very_small' WHEN COUNT(*) < 1000 THEN '2_small' ELSE '3_adequate' END AS sample_tier,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles
FROM trips_pay
WHERE NOT flag_pickup_outside_nyc
GROUP BY company, PULocationID, pu_borough, pu_zone
ORDER BY company DESC, pu_borough, n DESC;

-- name: pay_airport_split
-- Airport vs other pickup zones (the Stage 2E waits reversed at airports, so pay is split the same way).
SELECT
    company,
    CASE WHEN is_airport_zone THEN 'airport zones' ELSE 'other zones' END           AS zone_group,
    COUNT(*)                                                                         AS n,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles,
    ROUND(quantile_cont(trip_minutes, 0.50), 2)                                      AS median_minutes
FROM trips_pay
WHERE NOT flag_pickup_outside_nyc
GROUP BY company, 2
ORDER BY company DESC, zone_group;

-- name: pay_by_daypart_company
-- Time tables use the FULL scoped population (D14). Request time (D6).
SELECT
    COALESCE(company, 'All')                                                         AS company,
    daypart, day_type,
    COUNT(*)                                                                         AS n,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles,
    ROUND(quantile_cont(trip_minutes, 0.50), 2)                                      AS median_minutes
FROM trips_pay
GROUP BY GROUPING SETS ((daypart, day_type), (company, daypart, day_type))
ORDER BY CASE COALESCE(company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, daypart, day_type;

-- name: pay_by_hour_company
SELECT
    COALESCE(company, 'All')                                                         AS company,
    request_hour,
    COUNT(*)                                                                         AS n,
    ROUND(quantile_cont(driver_pay, 0.50), 2)                                        AS pay_p50,
    ROUND(quantile_cont(pay_per_mile, 0.50) FILTER (WHERE in_pay_per_mile), 3)       AS ppm_p50,
    ROUND(quantile_cont(pay_per_minute, 0.50) FILTER (WHERE in_pay_per_minute), 3)   AS ppmin_p50,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                        AS median_miles
FROM trips_pay
GROUP BY GROUPING SETS ((request_hour), (company, request_hour))
ORDER BY CASE COALESCE(company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, request_hour;

-- name: fare_component_audit
-- What the available fare fields look like, by company. Proportional fees should show a near-constant ratio to the base fare;
-- flat fees should appear on a share of rows. This describes the fields; it does NOT establish a total passenger charge.
WITH a AS (
    SELECT
        company,
        COUNT(*)                                                                    AS n_rows,
        COUNT(*) FILTER (WHERE base_passenger_fare > 0)                             AS n_base_fare_positive,
        100.0 * COUNT(*) FILTER (WHERE tolls > 0)                / COUNT(*)         AS pct_rows_tolls,
        100.0 * COUNT(*) FILTER (WHERE bcf > 0)                  / COUNT(*)         AS pct_rows_bcf,
        100.0 * COUNT(*) FILTER (WHERE sales_tax > 0)            / COUNT(*)         AS pct_rows_sales_tax,
        100.0 * COUNT(*) FILTER (WHERE congestion_surcharge > 0) / COUNT(*)         AS pct_rows_congestion_surcharge,
        100.0 * COUNT(*) FILTER (WHERE airport_fee > 0)          / COUNT(*)         AS pct_rows_airport_fee,
        100.0 * COUNT(*) FILTER (WHERE cbd_congestion_fee > 0)   / COUNT(*)         AS pct_rows_cbd_fee,
        100.0 * COUNT(*) FILTER (WHERE tips > 0)                 / COUNT(*)         AS pct_rows_tips,
        quantile_cont(sales_tax / NULLIF(base_passenger_fare, 0), [0.25, 0.50, 0.75]) FILTER (WHERE base_passenger_fare > 0) AS tax_q,
        quantile_cont(bcf / NULLIF(base_passenger_fare, 0), [0.25, 0.50, 0.75])       FILTER (WHERE base_passenger_fare > 0) AS bcf_q
    FROM trips_features
    GROUP BY company
)
SELECT
    company, n_rows, n_base_fare_positive,
    ROUND(pct_rows_tolls, 2) AS pct_rows_tolls, ROUND(pct_rows_bcf, 2) AS pct_rows_bcf, ROUND(pct_rows_sales_tax, 2) AS pct_rows_sales_tax,
    ROUND(pct_rows_congestion_surcharge, 2) AS pct_rows_congestion_surcharge, ROUND(pct_rows_airport_fee, 2) AS pct_rows_airport_fee,
    ROUND(pct_rows_cbd_fee, 2) AS pct_rows_cbd_fee, ROUND(pct_rows_tips, 2) AS pct_rows_tips,
    ROUND(tax_q[1], 4) AS sales_tax_to_base_p25, ROUND(tax_q[2], 4) AS sales_tax_to_base_p50, ROUND(tax_q[3], 4) AS sales_tax_to_base_p75,
    ROUND(bcf_q[1], 4) AS bcf_to_base_p25,       ROUND(bcf_q[2], 4) AS bcf_to_base_p50,       ROUND(bcf_q[3], 4) AS bcf_to_base_p75
FROM a
ORDER BY company DESC;

-- name: pay_to_fare_by_company
-- DESCRIPTIVE ONLY (D4): driver_pay / base_passenger_fare. NOT a take rate. Rows: base fare > 0 and pay >= 0 (expected 20,388,149).
-- Cross-check: median about 0.733 (Uber) and 0.749 (Lyft) from Stage 1C.
WITH q AS (
    SELECT
        company,
        COUNT(*)                                                        AS n,
        COUNT(*) FILTER (WHERE driver_pay > base_passenger_fare)        AS n_pay_gt_fare,
        AVG(driver_pay / base_passenger_fare)                           AS mean_ratio,
        quantile_cont(driver_pay / base_passenger_fare, [0.01, 0.05, 0.25, 0.50, 0.75, 0.95, 0.99]) AS qs
    FROM trips_features
    WHERE base_passenger_fare > 0 AND driver_pay >= 0
    GROUP BY company
)
SELECT
    company, n, n_pay_gt_fare, ROUND(100.0 * n_pay_gt_fare / n, 3) AS pct_pay_gt_fare,
    ROUND(mean_ratio, 4) AS mean_ratio,
    ROUND(qs[1], 4) AS p01, ROUND(qs[2], 4) AS p05, ROUND(qs[3], 4) AS p25, ROUND(qs[4], 4) AS p50,
    ROUND(qs[5], 4) AS p75, ROUND(qs[6], 4) AS p95, ROUND(qs[7], 4) AS p99
FROM q
ORDER BY company DESC;

-- name: pay_gt_fare_by_distance_band
-- Where does pay above base fare occur? (descriptive; a possible explanation such as a per-trip pay floor on short trips is a HYPOTHESIS, not tested)
SELECT
    company, distance_band,
    COUNT(*)                                                                         AS n,
    ROUND(100.0 * COUNT(*) FILTER (WHERE driver_pay > base_passenger_fare) / COUNT(*), 2) AS pct_pay_gt_fare,
    ROUND(quantile_cont(driver_pay / base_passenger_fare, 0.50), 4)                  AS pay_to_base_fare_p50
FROM trips_pay
WHERE base_passenger_fare > 0 AND driver_pay >= 0
GROUP BY company, distance_band
ORDER BY company DESC, distance_band;

-- name: robust_pay_level
-- Money-quality robustness for pay per trip. Scenarios (each is a defensible stricter filter; none is applied to the project data):
--   S0 all rows | S1 pay > 0 (drop zero/negative pay) | S2 base fare > 0 (drop zero/negative fare) | S3 no money flag (Stage 1E strict set).
-- The notebook computes % change vs S0 for n, mean, p10, p50, p90, p99 and total pay. Run on its own: four scans of 20M rows.
WITH u AS (
    SELECT 'pay' AS metric, 'S0 all rows' AS scenario, company, COUNT(*) AS n, AVG(driver_pay) AS mean_value, SUM(driver_pay) AS total_value,
           quantile_cont(driver_pay, [0.10, 0.50, 0.90, 0.99]) AS qs
    FROM trips_pay GROUP BY company
    UNION ALL
    SELECT 'pay', 'S1 pay > 0', company, COUNT(*), AVG(driver_pay), SUM(driver_pay), quantile_cont(driver_pay, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE driver_pay > 0 GROUP BY company
    UNION ALL
    SELECT 'pay', 'S2 base fare > 0', company, COUNT(*), AVG(driver_pay), SUM(driver_pay), quantile_cont(driver_pay, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE base_passenger_fare > 0 GROUP BY company
    UNION ALL
    SELECT 'pay', 'S3 no money flag', company, COUNT(*), AVG(driver_pay), SUM(driver_pay), quantile_cont(driver_pay, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE NOT flag_any_money GROUP BY company
)
SELECT metric, scenario, company, n,
       ROUND(mean_value, 4) AS mean_value, ROUND(total_value, 2) AS total_value,
       ROUND(qs[1], 4) AS p10, ROUND(qs[2], 4) AS p50, ROUND(qs[3], 4) AS p90, ROUND(qs[4], 4) AS p99
FROM u
ORDER BY company DESC, scenario;

-- name: robust_ppm
-- Same scenarios for pay per mile (eligible rows only, trip_miles > 0). total_value is not meaningful for a ratio and is left empty.
WITH u AS (
    SELECT 'pay_per_mile' AS metric, 'S0 all eligible' AS scenario, company, COUNT(*) AS n, AVG(pay_per_mile) AS mean_value,
           quantile_cont(pay_per_mile, [0.10, 0.50, 0.90, 0.99]) AS qs
    FROM trips_pay WHERE in_pay_per_mile GROUP BY company
    UNION ALL
    SELECT 'pay_per_mile', 'S1 pay > 0', company, COUNT(*), AVG(pay_per_mile), quantile_cont(pay_per_mile, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE in_pay_per_mile AND driver_pay > 0 GROUP BY company
    UNION ALL
    SELECT 'pay_per_mile', 'S2 base fare > 0', company, COUNT(*), AVG(pay_per_mile), quantile_cont(pay_per_mile, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE in_pay_per_mile AND base_passenger_fare > 0 GROUP BY company
    UNION ALL
    SELECT 'pay_per_mile', 'S3 no money flag', company, COUNT(*), AVG(pay_per_mile), quantile_cont(pay_per_mile, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE in_pay_per_mile AND NOT flag_any_money GROUP BY company
)
SELECT metric, scenario, company, n,
       ROUND(mean_value, 4) AS mean_value, CAST(NULL AS DOUBLE) AS total_value,
       ROUND(qs[1], 4) AS p10, ROUND(qs[2], 4) AS p50, ROUND(qs[3], 4) AS p90, ROUND(qs[4], 4) AS p99
FROM u
ORDER BY company DESC, scenario;

-- name: robust_ppmin
-- Same scenarios for pay per passenger-trip minute (eligible rows only, trip_time > 0).
WITH u AS (
    SELECT 'pay_per_minute' AS metric, 'S0 all eligible' AS scenario, company, COUNT(*) AS n, AVG(pay_per_minute) AS mean_value,
           quantile_cont(pay_per_minute, [0.10, 0.50, 0.90, 0.99]) AS qs
    FROM trips_pay WHERE in_pay_per_minute GROUP BY company
    UNION ALL
    SELECT 'pay_per_minute', 'S1 pay > 0', company, COUNT(*), AVG(pay_per_minute), quantile_cont(pay_per_minute, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE in_pay_per_minute AND driver_pay > 0 GROUP BY company
    UNION ALL
    SELECT 'pay_per_minute', 'S2 base fare > 0', company, COUNT(*), AVG(pay_per_minute), quantile_cont(pay_per_minute, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE in_pay_per_minute AND base_passenger_fare > 0 GROUP BY company
    UNION ALL
    SELECT 'pay_per_minute', 'S3 no money flag', company, COUNT(*), AVG(pay_per_minute), quantile_cont(pay_per_minute, [0.10, 0.50, 0.90, 0.99])
    FROM trips_pay WHERE in_pay_per_minute AND NOT flag_any_money GROUP BY company
)
SELECT metric, scenario, company, n,
       ROUND(mean_value, 4) AS mean_value, CAST(NULL AS DOUBLE) AS total_value,
       ROUND(qs[1], 4) AS p10, ROUND(qs[2], 4) AS p50, ROUND(qs[3], 4) AS p90, ROUND(qs[4], 4) AS p99
FROM u
ORDER BY company DESC, scenario;