-- Stage 2A: overall wait profile by company on trips_features. READ-ONLY.
-- D11: statistics use valid waits only (is_wait_valid). D12: every table shows n_scoped, n_valid and the excluded share.
-- Wait is request-to-pickup time in minutes, an observed outcome and not a promised ETA (D2).
-- Descriptive only: no confidence intervals yet (Stage 3), so no company difference is claimed from these tables.

-- name: wait_profile_by_company
-- One row per company plus an ALL row. Percentile order inside the list: p50, p75, p90, p95, p99.
WITH q AS (
    SELECT
        COALESCE(hvfhs_license_num, 'ALL')                                                     AS hvfhs_license_num,
        COUNT(*)                                                                               AS n_scoped,
        COUNT(*) FILTER (WHERE is_wait_valid)                                                  AS n_valid,
        AVG(wait_minutes) FILTER (WHERE is_wait_valid)                                         AS mean_min,
        quantile_cont(wait_minutes, [0.50, 0.75, 0.90, 0.95, 0.99]) FILTER (WHERE is_wait_valid) AS qs
    FROM trips_features
    GROUP BY ROLLUP(hvfhs_license_num)
)
SELECT
    hvfhs_license_num,
    CASE hvfhs_license_num WHEN 'HV0003' THEN 'Uber' WHEN 'HV0005' THEN 'Lyft' ELSE 'All' END   AS company,
    n_scoped,
    n_valid,
    n_scoped - n_valid                                                                          AS n_excluded_negative_wait,
    ROUND(100.0 * (n_scoped - n_valid) / n_scoped, 3)                                           AS pct_excluded,
    ROUND(mean_min, 3)                                                                          AS mean_min,
    ROUND(qs[1], 3)                                                                             AS p50_min,
    ROUND(qs[1] * 60)                                                                           AS p50_sec,
    ROUND(qs[2], 3)                                                                             AS p75_min,
    ROUND(qs[3], 3)                                                                             AS p90_min,
    ROUND(qs[4], 3)                                                                             AS p95_min,
    ROUND(qs[5], 3)                                                                             AS p99_min
FROM q
ORDER BY CASE hvfhs_license_num WHEN 'HV0003' THEN 1 WHEN 'HV0005' THEN 2 ELSE 3 END;

-- name: wait_bins_by_company
-- Histogram-ready. Bin -1 holds the excluded negative-wait rows so each company's bins add up to n_scoped.
-- Valid bins: 1-minute steps to 10 min, then 10-12, 12-15, 15-20, 20-30, 30-60, 60+. The first bin (0 to <1 min)
-- includes exact zero waits (about 0.001% of rows).
WITH x AS (
    SELECT
        hvfhs_license_num,
        CASE WHEN NOT is_wait_valid   THEN -1
             WHEN wait_minutes < 10   THEN CAST(FLOOR(wait_minutes) AS INTEGER)
             WHEN wait_minutes < 12   THEN 10
             WHEN wait_minutes < 15   THEN 12
             WHEN wait_minutes < 20   THEN 15
             WHEN wait_minutes < 30   THEN 20
             WHEN wait_minutes < 60   THEN 30
             ELSE                          60 END                    AS bin_start_min
    FROM trips_features
),
g AS (
    SELECT hvfhs_license_num, bin_start_min, COUNT(*) AS n_rows
    FROM x
    GROUP BY 1, 2
)
SELECT
    hvfhs_license_num,
    CASE hvfhs_license_num WHEN 'HV0003' THEN 'Uber' WHEN 'HV0005' THEN 'Lyft' END                AS company,
    bin_start_min,
    CASE WHEN bin_start_min = -1 THEN 'excluded: negative wait'
         WHEN bin_start_min < 10 THEN CAST(bin_start_min AS VARCHAR) || '-<' || CAST(bin_start_min + 1 AS VARCHAR) || ' min'
         WHEN bin_start_min = 10 THEN '10-<12 min'
         WHEN bin_start_min = 12 THEN '12-<15 min'
         WHEN bin_start_min = 15 THEN '15-<20 min'
         WHEN bin_start_min = 20 THEN '20-<30 min'
         WHEN bin_start_min = 30 THEN '30-<60 min'
         ELSE                         '60+ min' END                                                AS bin_label,
    n_rows,
    ROUND(100.0 * n_rows / SUM(n_rows) OVER (PARTITION BY hvfhs_license_num), 3)                  AS pct_of_scoped,
    CASE WHEN bin_start_min >= 0 THEN
         ROUND(100.0 * n_rows / SUM(CASE WHEN bin_start_min >= 0 THEN n_rows END)
                                OVER (PARTITION BY hvfhs_license_num), 3) END                      AS pct_of_valid,
    CASE WHEN bin_start_min >= 0 THEN
         ROUND(100.0 * SUM(CASE WHEN bin_start_min >= 0 THEN n_rows END)
                       OVER (PARTITION BY hvfhs_license_num ORDER BY bin_start_min)
               / SUM(CASE WHEN bin_start_min >= 0 THEN n_rows END)
                       OVER (PARTITION BY hvfhs_license_num), 3) END                               AS cum_pct_of_valid
FROM g
ORDER BY hvfhs_license_num, bin_start_min;