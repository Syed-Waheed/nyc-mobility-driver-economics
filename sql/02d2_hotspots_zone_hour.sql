-- Stage 2D2: coarser hotspot design = pickup zone x request hour (24 slots, weekdays pooled). READ-ONLY on trips_features / zhw_cells.
-- The fine design (sql/02d_hotspots.sql, 168 weekday-hour slots) is kept unchanged as exploratory results.
-- The eligibility threshold is NOT changed: a cell needs n_valid >= 1,000 (3_adequate). Coverage is improved by pooling time, never by lowering the bar.
-- Same methodology as 02d (all pre-set there): metric = share of valid waits >= 10 minutes; baseline = five-borough share for the same
-- hour slot (slot_*) and the zone's own share over all hours (zone_*); Wilson 95% lower end >= 2x slot baseline = hotspot;
-- robust = still >= 2x if every excluded negative-wait row were short (< 10 min). D6, D11, D12, D14, D15 apply unchanged.
-- Descriptive only: hotspots are associations between a place-time and observed request-to-pickup waits, not causes.
-- Pre-set bar for choosing a design (stated before results): a design is adequate if its eligible cells cover >= 80% of valid waits
-- overall AND >= 50% of valid waits in every borough.
-- Pre-set dayparts (from the Stage 2C hourly pattern: wait peak at 7 AM, volume peak at 6 PM):
--   1_overnight_0-5 | 2_morning_6-9 | 3_midday_10-15 | 4_evening_peak_16-19 | 5_late_evening_20-23.
-- Requires the Stage 2D tables zhw_cells and zhw_hotspots (built by sql/02d_hotspots.sql).

-- name: create_zh_cells
-- MATERIALIZED TABLE (at most 260 x 24 = 6,240 rows). One heavy pass over the 20M rows (about a minute).
CREATE OR REPLACE TABLE zh_cells AS
SELECT
    t.PULocationID,
    t.pu_borough,
    t.pu_zone,
    t.request_hour,
    COUNT(*)                                                                   AS n_scoped,
    COUNT(*) FILTER (WHERE t.in_geo_wait_tables)                               AS n_valid,
    COUNT(*) - COUNT(*) FILTER (WHERE t.in_geo_wait_tables)                    AS n_excluded_negative_wait,
    COUNT(*) FILTER (WHERE t.in_geo_wait_tables AND t.company = 'Uber')        AS n_valid_uber,
    COUNT(*) FILTER (WHERE t.in_geo_wait_tables AND t.wait_minutes >= 10)      AS n_wait_ge10,
    ROUND(quantile_cont(t.wait_minutes, 0.50) FILTER (WHERE t.in_geo_wait_tables), 3) AS p50_min,
    ROUND(quantile_cont(t.wait_minutes, 0.90) FILTER (WHERE t.in_geo_wait_tables), 3) AS p90_min,
    CASE WHEN COUNT(*) FILTER (WHERE t.in_geo_wait_tables) < 100  THEN '1_very_small'
         WHEN COUNT(*) FILTER (WHERE t.in_geo_wait_tables) < 1000 THEN '2_small'
         ELSE '3_adequate' END                                                 AS sample_tier
FROM trips_features t
WHERE NOT t.flag_pickup_outside_nyc
GROUP BY t.PULocationID, t.pu_borough, t.pu_zone, t.request_hour;

-- name: create_zh_hotspots
-- Same construction as zhw_hotspots, with the hour slot as the baseline unit. avg_trips_per_day divides by the 31 January calendar days.
CREATE OR REPLACE TABLE zh_hotspots AS
WITH base AS (
    SELECT
        c.*,
        c.n_wait_ge10 * 1.0 / c.n_valid                              AS p,
        SUM(c.n_valid)     OVER (PARTITION BY c.request_hour)        AS slot_n_valid,
        SUM(c.n_wait_ge10) OVER (PARTITION BY c.request_hour)        AS slot_n_ge10,
        SUM(c.n_valid)     OVER (PARTITION BY c.PULocationID)        AS zone_n_valid,
        SUM(c.n_wait_ge10) OVER (PARTITION BY c.PULocationID)        AS zone_n_ge10
    FROM zh_cells c
    WHERE c.n_valid > 0
),
w AS (
    SELECT
        *,
        slot_n_ge10 * 1.0 / slot_n_valid                             AS slot_frac,
        zone_n_ge10 * 1.0 / zone_n_valid                             AS zone_frac,
        (p + 1.9208 / n_valid) / (1 + 3.8416 / n_valid)              AS center,
        1.96 * sqrt(p * (1 - p) / n_valid + 0.9604 / (n_valid * 1.0 * n_valid)) / (1 + 3.8416 / n_valid) AS half
    FROM base
)
SELECT
    PULocationID,
    pu_borough,
    pu_zone,
    request_hour,
    n_scoped,
    n_valid,
    n_excluded_negative_wait,
    ROUND(100.0 * n_excluded_negative_wait / n_scoped, 3)                        AS pct_excluded,
    ROUND(n_scoped / 31.0, 1)                                                    AS avg_trips_per_day,
    ROUND(100.0 * n_valid_uber / n_valid, 1)                                     AS pct_uber_of_valid,
    p50_min,
    p90_min,
    sample_tier,
    n_wait_ge10,
    ROUND(100 * p, 3)                                                            AS pct_wait_ge10,
    ROUND(100 * (center - half), 3)                                              AS pct_wait_ge10_wilson_low,
    ROUND(100 * (center + half), 3)                                              AS pct_wait_ge10_wilson_high,
    ROUND(100.0 * n_wait_ge10 / n_scoped, 3)                                     AS pct_ge10_if_excluded_all_short,
    ROUND(100.0 * (n_wait_ge10 + n_excluded_negative_wait) / n_scoped, 3)        AS pct_ge10_if_excluded_all_long,
    ROUND(100 * slot_frac, 3)                                                    AS slot_pct_wait_ge10,
    ROUND(100 * zone_frac, 3)                                                    AS zone_pct_wait_ge10_all_hours,
    ROUND(p / NULLIF(slot_frac, 0), 2)                                           AS ratio_vs_slot,
    ROUND(100 * (p - slot_frac), 3)                                              AS excess_vs_slot_pts,
    ROUND(100 * (p - zone_frac), 3)                                              AS excess_vs_zone_pts,
    (center - half)                                                              AS wilson_low_frac,
    slot_frac,
    (sample_tier = '3_adequate' AND (center - half) >= 2 * slot_frac)            AS hotspot_flag,
    (sample_tier = '3_adequate' AND (center - half) >= 2 * slot_frac
        AND n_wait_ge10 * 1.0 / n_scoped >= 2 * slot_frac)                       AS hotspot_robust_flag
FROM w;

-- name: create_coverage_cells
-- Small table: n_valid per cell under five candidate designs, built by pooling the fine cells (counts add up exactly).
CREATE OR REPLACE TABLE coverage_cells AS
WITH z AS (
    SELECT
        *,
        CASE WHEN request_hour < 6  THEN '1_overnight_0-5'
             WHEN request_hour < 10 THEN '2_morning_6-9'
             WHEN request_hour < 16 THEN '3_midday_10-15'
             WHEN request_hour < 20 THEN '4_evening_peak_16-19'
             ELSE                        '5_late_evening_20-23' END AS daypart,
        CASE WHEN request_isodow <= 5 THEN 'Mon-Fri' ELSE 'Sat-Sun' END AS day_type
    FROM zhw_cells
),
d AS (
    SELECT 'A zone x weekday x hour' AS design, PULocationID, pu_borough,
           CAST(request_isodow AS VARCHAR) || '-' || CAST(request_hour AS VARCHAR) AS slot, n_valid FROM z
    UNION ALL
    SELECT 'B zone x hour',               PULocationID, pu_borough, CAST(request_hour AS VARCHAR), n_valid FROM z
    UNION ALL
    SELECT 'C zone x daypart x day type', PULocationID, pu_borough, daypart || '|' || day_type,    n_valid FROM z
    UNION ALL
    SELECT 'D zone x daypart',            PULocationID, pu_borough, daypart,                       n_valid FROM z
    UNION ALL
    SELECT 'E zone (all hours)',          PULocationID, pu_borough, 'all',                         n_valid FROM z
)
SELECT design, PULocationID, pu_borough, slot, SUM(n_valid) AS n_valid
FROM d
GROUP BY design, PULocationID, pu_borough, slot;

-- name: zh_cells_reconcile
-- Expected: 260 zones, 24 hours, n_scoped 20,404,892, n_valid 20,205,118, excluded 199,774 (same population as the fine design).
SELECT
    COUNT(*)                                  AS n_cells,
    COUNT(DISTINCT PULocationID)              AS n_zones,
    COUNT(DISTINCT request_hour)              AS n_hours,
    260 * 24 - COUNT(*)                       AS empty_cells,
    COUNT(*) FILTER (WHERE n_valid = 0)       AS cells_with_no_valid_wait,
    SUM(n_scoped)                             AS n_scoped,
    SUM(n_valid)                              AS n_valid,
    SUM(n_excluded_negative_wait)             AS n_excluded
FROM zh_cells;

-- name: coverage_tradeoff
-- How much of the valid-wait population sits in eligible (n_valid >= 1,000) cells under each design?
-- Cross-checks: design A = 5,221 adequate cells and 39.17% (Stage 2D); design E = 99.98% (Stage 2B zone tiers).
SELECT
    design,
    COUNT(DISTINCT slot)                                                                AS n_slots,
    COUNT(*)                                                                            AS n_cells,
    COUNT(*) FILTER (WHERE n_valid >= 1000)                                             AS n_adequate_cells,
    SUM(n_valid)                                                                        AS valid_rows,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE n_valid >= 1000) / SUM(n_valid), 2)        AS pct_valid_rows_in_adequate_cells,
    COUNT(DISTINCT PULocationID) FILTER (WHERE n_valid >= 1000)                         AS zones_with_adequate_cell
FROM coverage_cells
GROUP BY design
ORDER BY design;

-- name: coverage_tradeoff_by_borough
SELECT
    design,
    pu_borough,
    COUNT(DISTINCT PULocationID)                                                        AS n_zones,
    COUNT(*)                                                                            AS n_cells,
    COUNT(*) FILTER (WHERE n_valid >= 1000)                                             AS n_adequate_cells,
    COUNT(DISTINCT PULocationID) FILTER (WHERE n_valid >= 1000)                         AS zones_with_adequate_cell,
    SUM(n_valid)                                                                        AS valid_rows,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE n_valid >= 1000) / SUM(n_valid), 2)        AS pct_valid_rows_in_adequate_cells
FROM coverage_cells
GROUP BY design, pu_borough
ORDER BY design, pu_borough;

-- name: zh_cell_size_distribution
SELECT
    sample_tier,
    COUNT(*)                                                         AS n_cells,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)               AS pct_of_cells,
    SUM(n_valid)                                                     AS valid_rows,
    ROUND(100.0 * SUM(n_valid) / SUM(SUM(n_valid)) OVER (), 2)       AS pct_of_valid_rows
FROM zh_cells
GROUP BY 1
ORDER BY 1;

-- name: zh_slot_baseline
-- Five-borough share of valid waits >= 10 minutes by request hour (the hotspot baseline), with exclusion shown (D12).
SELECT
    request_hour,
    SUM(n_scoped)                                                      AS n_scoped,
    SUM(n_valid)                                                       AS n_valid,
    SUM(n_excluded_negative_wait)                                      AS n_excluded_negative_wait,
    ROUND(100.0 * SUM(n_excluded_negative_wait) / SUM(n_scoped), 3)    AS pct_excluded,
    SUM(n_wait_ge10)                                                   AS n_wait_ge10,
    ROUND(100.0 * SUM(n_wait_ge10) / SUM(n_valid), 3)                  AS pct_wait_ge10
FROM zh_cells
GROUP BY 1
ORDER BY 1;

-- name: zh_hotspot_summary
SELECT
    COUNT(*)                                                                                   AS n_cells_with_valid_wait,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                                         AS n_adequate_cells,
    COUNT(DISTINCT PULocationID) FILTER (WHERE sample_tier = '3_adequate')                     AS n_zones_with_adequate_cell,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate' AND wilson_low_frac >= 1.5 * slot_frac)  AS n_hotspot_1_5x,
    COUNT(*) FILTER (WHERE hotspot_flag)                                                       AS n_hotspot_2x,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate' AND wilson_low_frac >= 3 * slot_frac)    AS n_hotspot_3x,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)                                                AS n_hotspot_robust_2x,
    COUNT(DISTINCT PULocationID) FILTER (WHERE hotspot_flag)                                   AS n_zones_with_hotspot,
    SUM(n_valid)     FILTER (WHERE hotspot_flag)                                               AS valid_rows_in_hotspots,
    SUM(n_wait_ge10) FILTER (WHERE hotspot_flag)                                               AS long_waits_in_hotspots,
    SUM(n_wait_ge10)                                                                           AS long_waits_all_cells,
    ROUND(100.0 * SUM(n_wait_ge10) FILTER (WHERE hotspot_flag) / SUM(n_wait_ge10), 2)          AS pct_of_long_waits_in_hotspots,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE hotspot_flag) / SUM(n_valid), 2)                  AS pct_of_valid_rows_in_hotspots
FROM zh_hotspots;

-- name: zh_hotspot_by_borough
SELECT
    pu_borough,
    COUNT(DISTINCT PULocationID)                                          AS n_zones,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                    AS n_adequate_cells,
    COUNT(DISTINCT PULocationID) FILTER (WHERE sample_tier = '3_adequate') AS zones_with_adequate_cell,
    COUNT(*) FILTER (WHERE hotspot_flag)                                  AS n_hotspot_cells,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)                           AS n_robust_cells,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE sample_tier = '3_adequate') / SUM(n_valid), 2) AS pct_valid_rows_in_adequate_cells,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE hotspot_flag) / SUM(n_valid), 2)               AS pct_valid_rows_in_hotspots
FROM zh_hotspots
GROUP BY 1
ORDER BY n_hotspot_cells DESC;

-- name: zh_staten_island_zones
-- All Staten Island zones, whatever their eligibility. zone_pct_wait_ge10 is the zone-level share of long waits over all hours
-- (always computable), so Staten Island can be described even where hour cells are too small to rank.
SELECT
    PULocationID,
    pu_zone,
    SUM(n_valid)                                                    AS zone_n_valid,
    ROUND(100.0 * SUM(n_excluded_negative_wait) / SUM(n_scoped), 3) AS pct_excluded,
    MAX(n_valid)                                                    AS max_hourly_n_valid,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')              AS n_adequate_hours,
    COUNT(*) FILTER (WHERE hotspot_flag)                            AS n_hotspot_hours,
    ROUND(100.0 * SUM(n_wait_ge10) / SUM(n_valid), 3)               AS zone_pct_wait_ge10
FROM zh_hotspots
WHERE pu_borough = 'Staten Island'
GROUP BY 1, 2
ORDER BY zone_n_valid DESC;

-- name: zh_hotspot_top_by_rate
-- Hotspot cells ranked by the LOWER end of the interval. excess_vs_zone_pts separates "this zone is slow at all hours"
-- from "this hour is unusually slow for this zone".
SELECT
    pu_borough, pu_zone, request_hour,
    n_valid, pct_excluded, avg_trips_per_day,
    pct_wait_ge10, pct_wait_ge10_wilson_low, pct_ge10_if_excluded_all_short,
    slot_pct_wait_ge10, ratio_vs_slot, zone_pct_wait_ge10_all_hours, excess_vs_zone_pts,
    p50_min, p90_min, pct_uber_of_valid, hotspot_robust_flag
FROM zh_hotspots
WHERE hotspot_flag
ORDER BY wilson_low_frac DESC
LIMIT 30;

-- name: zh_hotspot_top_non_airport
-- DISPLAY AID ONLY (not a rule): the same ranking without zones whose name contains "Airport", so the airports do not hide the rest.
SELECT
    pu_borough, pu_zone, request_hour,
    n_valid, pct_excluded, avg_trips_per_day,
    pct_wait_ge10, pct_wait_ge10_wilson_low, pct_ge10_if_excluded_all_short,
    slot_pct_wait_ge10, ratio_vs_slot, zone_pct_wait_ge10_all_hours, excess_vs_zone_pts,
    p50_min, p90_min, pct_uber_of_valid, hotspot_robust_flag
FROM zh_hotspots
WHERE hotspot_flag AND pu_zone NOT ILIKE '%airport%'
ORDER BY wilson_low_frac DESC
LIMIT 30;

-- name: zh_hotspot_top_by_impact
-- Eligible cells ranked by the NUMBER of long waits, hotspot or not.
SELECT
    pu_borough, pu_zone, request_hour,
    n_valid, n_wait_ge10, pct_excluded, avg_trips_per_day,
    pct_wait_ge10, slot_pct_wait_ge10, ratio_vs_slot, hotspot_flag
FROM zh_hotspots
WHERE sample_tier = '3_adequate'
ORDER BY n_wait_ge10 DESC
LIMIT 30;

-- name: zh_hotspot_zone_summary
-- Zones with at least one hotspot hour: how many hours, and how much of the zone's volume they hold. Top 25.
SELECT
    PULocationID,
    pu_borough,
    pu_zone,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                                  AS n_adequate_hours,
    COUNT(*) FILTER (WHERE hotspot_flag)                                                AS n_hotspot_hours,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)                                         AS n_robust_hours,
    SUM(n_valid)                                                                        AS zone_n_valid,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE hotspot_flag) / SUM(n_valid), 2)           AS pct_valid_rows_in_hotspots,
    ROUND(MAX(zone_pct_wait_ge10_all_hours), 3)                                         AS zone_pct_wait_ge10_all_hours
FROM zh_hotspots
GROUP BY 1, 2, 3
HAVING COUNT(*) FILTER (WHERE hotspot_flag) > 0
ORDER BY n_hotspot_hours DESC, zone_n_valid DESC
LIMIT 25;

-- name: zh_hotspot_by_hour
SELECT
    request_hour,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                  AS n_adequate_cells,
    COUNT(*) FILTER (WHERE hotspot_flag)                                AS n_hotspot_cells,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)                         AS n_robust_cells,
    ROUND(MAX(slot_pct_wait_ge10), 3)                                   AS slot_pct_wait_ge10,
    ROUND(100.0 * SUM(n_excluded_negative_wait) / SUM(n_scoped), 3)     AS pct_excluded
FROM zh_hotspots
GROUP BY 1
ORDER BY 1;

-- name: zh_vs_fine
-- Does the coarse design agree with the fine one? fine_cells_total must equal the 325 fine hotspot cells (Stage 2D).
-- coarse_not_hotspot_but_fine_hotspot counts zone-hours where pooling over weekdays HIDES a weekday-specific hotspot.
WITH f AS (
    SELECT PULocationID, request_hour, COUNT(*) FILTER (WHERE hotspot_flag) AS n_fine_hotspot_cells
    FROM zhw_hotspots
    GROUP BY 1, 2
)
SELECT
    COUNT(*) FILTER (WHERE z.hotspot_flag)                                                        AS n_coarse_hotspots,
    COUNT(*) FILTER (WHERE z.hotspot_flag AND COALESCE(f.n_fine_hotspot_cells, 0) > 0)            AS coarse_hotspots_with_a_fine_hotspot,
    COUNT(*) FILTER (WHERE z.hotspot_flag AND COALESCE(f.n_fine_hotspot_cells, 0) = 0)            AS coarse_hotspots_without_fine_hotspot,
    COUNT(*) FILTER (WHERE NOT z.hotspot_flag AND COALESCE(f.n_fine_hotspot_cells, 0) > 0)        AS coarse_not_hotspot_but_fine_hotspot,
    SUM(f.n_fine_hotspot_cells)                                                                   AS fine_cells_total,
    SUM(f.n_fine_hotspot_cells) FILTER (WHERE z.hotspot_flag)                                     AS fine_cells_inside_coarse_hotspots
FROM zh_hotspots z
LEFT JOIN f ON f.PULocationID = z.PULocationID AND f.request_hour = z.request_hour;