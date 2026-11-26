-- Stage 2C: time-based wait profile on trips_features. READ-ONLY. No new views are needed.
-- Rules reused, not re-decided:
--   D6   time buckets use REQUEST time: request_hour (0-23) and request_isodow (1 = Monday ... 7 = Sunday).
--   D11  wait statistics use valid waits only (is_wait_valid).
--   D12  every wait table shows n_scoped, n_valid, the negative-wait exclusion count and share.
--   D14  these are time tables, not geographic: the FULL scoped population is used, including the 774 outside-NYC pickups.
-- Population: 20,405,666 scoped rows (Uber 15,356,455; Lyft 5,049,211); 20,205,878 valid (Uber 15,235,488; Lyft 4,970,390);
-- 199,788 excluded (Uber 120,967; Lyft 78,821). Every table below must reconcile to these.
-- Request-date edge: 1,164 rows were requested on Tue Dec 31 and 5 on Sat Feb 1 (pickup is in January, D8). They stay in
-- the tables (negligible share) but are not counted in n_days.
-- Sample-size tier of a cell's n_valid, same cut-offs as Stage 2B: 1_very_small < 100 | 2_small 100-999 | 3_adequate >= 1,000.
-- Descriptive only: no confidence intervals (Stage 3), no company difference is claimed from these tables.

-- name: hour_profile
-- One row per request hour for All, Uber and Lyft.
WITH q AS (
    SELECT
        company,
        request_hour,
        COUNT(*)                                                                      AS n_scoped,
        COUNT(*) FILTER (WHERE is_wait_valid)                                         AS n_valid,
        quantile_cont(wait_minutes, [0.50, 0.75, 0.90, 0.95]) FILTER (WHERE is_wait_valid) AS qs
    FROM trips_features
    GROUP BY GROUPING SETS ((request_hour), (company, request_hour))
)
SELECT
    COALESCE(company, 'All')                                                          AS company,
    request_hour,
    n_scoped,
    ROUND(100.0 * n_scoped / SUM(n_scoped) OVER (PARTITION BY COALESCE(company, 'All')), 3) AS pct_of_company_volume,
    n_valid,
    n_scoped - n_valid                                                                AS n_excluded_negative_wait,
    ROUND(100.0 * (n_scoped - n_valid) / n_scoped, 3)                                 AS pct_excluded,
    ROUND(qs[1], 3)                                                                   AS p50_min,
    ROUND(qs[2], 3)                                                                   AS p75_min,
    ROUND(qs[3], 3)                                                                   AS p90_min,
    ROUND(qs[4], 3)                                                                   AS p95_min
FROM q
ORDER BY CASE COALESCE(company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, request_hour;

-- name: weekday_profile
-- One row per ISO weekday for All, Uber and Lyft. January 2025 has 5 Wednesdays, 5 Thursdays and 5 Fridays but only
-- 4 of every other weekday, so raw counts overstate those three days: compare avg_trips_per_day, not n_scoped.
WITH days AS (
    SELECT request_isodow, COUNT(DISTINCT request_date) AS n_days
    FROM trips_features
    WHERE request_date BETWEEN DATE '2025-01-01' AND DATE '2025-01-31'
    GROUP BY 1
),
q AS (
    SELECT
        company,
        request_isodow,
        MIN(request_dow_name)                                                         AS dow_name,
        COUNT(*)                                                                      AS n_scoped,
        COUNT(*) FILTER (WHERE is_wait_valid)                                         AS n_valid,
        quantile_cont(wait_minutes, [0.50, 0.75, 0.90, 0.95]) FILTER (WHERE is_wait_valid) AS qs
    FROM trips_features
    GROUP BY GROUPING SETS ((request_isodow), (company, request_isodow))
)
SELECT
    COALESCE(q.company, 'All')                                                        AS company,
    q.request_isodow,
    q.dow_name,
    d.n_days,
    q.n_scoped,
    ROUND(100.0 * q.n_scoped / SUM(q.n_scoped) OVER (PARTITION BY COALESCE(q.company, 'All')), 3) AS pct_of_company_volume,
    ROUND(1.0 * q.n_scoped / d.n_days, 0)                                             AS avg_trips_per_day,
    q.n_valid,
    q.n_scoped - q.n_valid                                                            AS n_excluded_negative_wait,
    ROUND(100.0 * (q.n_scoped - q.n_valid) / q.n_scoped, 3)                           AS pct_excluded,
    ROUND(q.qs[1], 3)                                                                 AS p50_min,
    ROUND(q.qs[2], 3)                                                                 AS p75_min,
    ROUND(q.qs[3], 3)                                                                 AS p90_min,
    ROUND(q.qs[4], 3)                                                                 AS p95_min
FROM q
JOIN days d ON d.request_isodow = q.request_isodow
ORDER BY CASE COALESCE(q.company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, q.request_isodow;

-- name: hour_weekday_profile
-- 168 cells (7 weekdays x 24 hours) for All, Uber and Lyft = 504 rows. avg_trips_per_day divides by that weekday's
-- January calendar days so cells on 5-day weekdays are comparable to cells on 4-day weekdays.
WITH days AS (
    SELECT request_isodow, COUNT(DISTINCT request_date) AS n_days
    FROM trips_features
    WHERE request_date BETWEEN DATE '2025-01-01' AND DATE '2025-01-31'
    GROUP BY 1
),
q AS (
    SELECT
        company,
        request_isodow,
        request_hour,
        COUNT(*)                                                                      AS n_scoped,
        COUNT(*) FILTER (WHERE is_wait_valid)                                         AS n_valid,
        quantile_cont(wait_minutes, [0.50, 0.75, 0.90, 0.95]) FILTER (WHERE is_wait_valid) AS qs
    FROM trips_features
    GROUP BY GROUPING SETS ((request_isodow, request_hour), (company, request_isodow, request_hour))
)
SELECT
    COALESCE(q.company, 'All')                                                        AS company,
    q.request_isodow,
    q.request_hour,
    q.n_scoped,
    ROUND(100.0 * q.n_scoped / SUM(q.n_scoped) OVER (PARTITION BY COALESCE(q.company, 'All')), 4) AS pct_of_company_volume,
    ROUND(1.0 * q.n_scoped / d.n_days, 0)                                             AS avg_trips_per_day,
    q.n_valid,
    q.n_scoped - q.n_valid                                                            AS n_excluded_negative_wait,
    ROUND(100.0 * (q.n_scoped - q.n_valid) / q.n_scoped, 3)                           AS pct_excluded,
    ROUND(q.qs[1], 3)                                                                 AS p50_min,
    ROUND(q.qs[2], 3)                                                                 AS p75_min,
    ROUND(q.qs[3], 3)                                                                 AS p90_min,
    ROUND(q.qs[4], 3)                                                                 AS p95_min,
    CASE WHEN q.n_valid < 100 THEN '1_very_small' WHEN q.n_valid < 1000 THEN '2_small' ELSE '3_adequate' END AS sample_tier
FROM q
JOIN days d ON d.request_isodow = q.request_isodow
ORDER BY CASE COALESCE(q.company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, q.request_isodow, q.request_hour;

-- name: hour_exclusion_sensitivity
-- WORST-CASE BOUNDS for the hourly median and p90 under D11.
-- Question: the m excluded rows (negative waits) have an unknown TRUE wait. How far could an hour's median or p90 move?
-- Method: recompute the quantile on ALL n_scoped rows (valid + excluded) in two extreme scenarios:
--   low  scenario: every excluded row is given the lowest possible wait, 0 minutes;
--   high scenario: every excluded row is given a wait larger than any valid wait (1,000,000 minutes stands in for +infinity).
-- Why this is a valid bound: a quantile (including DuckDB's linear-interpolated quantile_cont) never decreases when any single
-- input value is raised, and never increases when one is lowered. So for ANY true waits that are >= 0, the full-population
-- quantile lies between the low-scenario and high-scenario values.
-- Assumptions: (1) a true wait cannot be negative; (2) the valid rows' waits are measured correctly; (3) the excluded rows are
-- the only unknowns. The bounds are NOT measured waits and do not say excluded trips have any particular true wait; they
-- show the most that exclusion could matter. The *_level_* columns give the equivalent quantile levels of the VALID distribution:
-- with excluded share p, the median bound is [(0.5 - p) / (1 - p), 0.5 / (1 - p)] and the p90 bound is [(0.9 - p) / (1 - p), 0.9 / (1 - p)].
-- Heavier query (3 quantile lists over 20M rows, two grouping sets): run it on its own if the Mac gets warm.
WITH q AS (
    SELECT
        company,
        request_hour,
        COUNT(*)                                                                                   AS n_scoped,
        COUNT(*) FILTER (WHERE is_wait_valid)                                                      AS n_valid,
        quantile_cont(wait_minutes, [0.50, 0.90]) FILTER (WHERE is_wait_valid)                     AS q_valid,
        quantile_cont(CASE WHEN is_wait_valid THEN wait_minutes ELSE 0 END, [0.50, 0.90])          AS q_low,
        quantile_cont(CASE WHEN is_wait_valid THEN wait_minutes ELSE 1000000 END, [0.50, 0.90])    AS q_high
    FROM trips_features
    GROUP BY GROUPING SETS ((request_hour), (company, request_hour))
)
SELECT
    COALESCE(company, 'All')                                                      AS company,
    request_hour,
    n_scoped,
    n_valid,
    n_scoped - n_valid                                                            AS n_excluded_negative_wait,
    ROUND(100.0 * (n_scoped - n_valid) / n_scoped, 3)                             AS pct_excluded,
    ROUND(q_valid[1], 3)                                                          AS p50_valid_min,
    ROUND(q_low[1], 3)                                                            AS p50_low_min,
    ROUND(q_high[1], 3)                                                           AS p50_high_min,
    ROUND((q_high[1] - q_low[1]) * 60, 1)                                         AS p50_bound_width_sec,
    ROUND(100.0 * GREATEST(0.0, (0.5 - (n_scoped - n_valid) * 1.0 / n_scoped) / (n_valid * 1.0 / n_scoped)), 2) AS p50_level_low_pct,
    ROUND(100.0 * LEAST(1.0, 0.5 / (n_valid * 1.0 / n_scoped)), 2)                AS p50_level_high_pct,
    ROUND(q_valid[2], 3)                                                          AS p90_valid_min,
    ROUND(q_low[2], 3)                                                            AS p90_low_min,
    ROUND(q_high[2], 3)                                                           AS p90_high_min,
    ROUND((q_high[2] - q_low[2]) * 60, 1)                                         AS p90_bound_width_sec,
    ROUND(100.0 * GREATEST(0.0, (0.9 - (n_scoped - n_valid) * 1.0 / n_scoped) / (n_valid * 1.0 / n_scoped)), 2) AS p90_level_low_pct,
    ROUND(100.0 * LEAST(1.0, 0.9 / (n_valid * 1.0 / n_scoped)), 2)                AS p90_level_high_pct
FROM q
ORDER BY CASE COALESCE(company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, request_hour;

-- name: hourly_volume_curve
-- Local-time plausibility check: share of each day-type's requests that fall in each request hour.
-- Pre-set expectations if the timestamps are NYC local time in January (UTC-5):
--   (1) the volume trough sits in the small hours (about 04:00-05:00 local); under UTC the whole curve would shift by 5 hours,
--       putting the trough near 09:00-10:00;
--   (2) Mon-Fri shows a late-afternoon/evening peak;
--   (3) Sat-Sun has a larger share of volume in hours 0-3 than Mon-Fri (Friday and Saturday nights run past midnight).
-- Consistent patterns support the local-time reading; they do not prove the timezone (a shift of an hour or so would be hard to see).
WITH b AS (
    SELECT
        company,
        CASE WHEN request_isodow <= 5 THEN 'Mon-Fri' ELSE 'Sat-Sun' END AS day_type,
        request_hour
    FROM trips_features
),
g AS (
    SELECT company, day_type, request_hour, COUNT(*) AS n_scoped
    FROM b
    GROUP BY GROUPING SETS ((day_type, request_hour), (company, day_type, request_hour))
)
SELECT
    COALESCE(company, 'All')                                                                       AS company,
    day_type,
    request_hour,
    n_scoped,
    ROUND(100.0 * n_scoped / SUM(n_scoped) OVER (PARTITION BY COALESCE(company, 'All'), day_type), 3) AS pct_of_company_daytype_volume
FROM g
ORDER BY CASE COALESCE(company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, day_type, request_hour;