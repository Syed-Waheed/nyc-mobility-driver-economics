-- Stage 2D: operational hotspots = pickup zone x request hour x ISO weekday. READ-ONLY on trips_features.
-- Rules reused, not re-decided:
--   D6   time = REQUEST time (request_hour, request_isodow).
--   D11  waits are valid waits only. D12 every table shows n_valid and the negative-wait exclusion count and share.
--   D14/D15  geographic table: in_geo_wait_tables = valid wait AND pickup in the five boroughs; the 774 outside-NYC pickups are not in any cell.
-- PRE-SET DEFINITIONS (written before any result was seen):
--   Metric   : share of valid waits that are 10 minutes or longer ("long waits"). The 10-minute mark is a communication threshold,
--              close to the pooled p95 (Stage 2A: about 5% of valid waits are >= 10 min: Uber 5.350%, Lyft 4.760%).
--              Median and p90 are shown beside it.
--   Baseline : the five-borough share of long waits for the SAME weekday-hour slot (slot_*), and the zone's own share over all hours (zone_*).
--   Eligible : sample_tier = 3_adequate, i.e. n_valid >= 1,000 in the cell (same cut-offs as Stage 2B: <100 very small, 100-999 small).
--   Hotspot  : eligible AND the lower end of the 95% Wilson interval for the cell's long-wait share is at least 2x the slot baseline.
--              Ranking uses that lower end, so a cell cannot rank high by luck of a small sample.
--   Robust   : hotspot AND the share is still at least 2x the slot baseline if every excluded negative-wait row were SHORT (< 10 min).
--   The 2x multiplier is a materiality choice; hotspot_summary shows how the count changes at 1.5x and 3x.
-- Descriptive only: a hotspot is an association between a place-time and observed waits. It says nothing about causes or supply.
-- Caveats: the Wilson interval treats a cell's trips as a sample from a process; thousands of cells are examined, so extreme cells
-- are partly selected for being extreme (the 2x materiality bar and the interval lower end limit, but do not remove, that).
-- Company mix is shown (pct_uber_of_valid), not controlled: company comparison is Stage 2E.

-- name: create_zhw_cells
-- MATERIALIZED TABLE (about 40k rows). One pass over the 20M rows, so later queries are fast and the Mac is not rescanning.
-- Request-date edge: 1,164 Dec 31 and 5 Feb 1 requests sit in Tue/Sat cells; they are not counted in n_days (negligible).
CREATE OR REPLACE TABLE zhw_cells AS
WITH days AS (
    SELECT request_isodow, COUNT(DISTINCT request_date) AS n_days
    FROM trips_features
    WHERE request_date BETWEEN DATE '2025-01-01' AND DATE '2025-01-31'
    GROUP BY 1
)
SELECT
    t.PULocationID,
    t.pu_borough,
    t.pu_zone,
    t.request_isodow,
    t.request_hour,
    d.n_days,
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
JOIN days d ON d.request_isodow = t.request_isodow
WHERE NOT t.flag_pickup_outside_nyc
GROUP BY t.PULocationID, t.pu_borough, t.pu_zone, t.request_isodow, t.request_hour, d.n_days;

-- name: create_zhw_hotspots
-- Adds baselines (window sums over the cell table), the Wilson interval, exclusion bounds and the flags.
-- Wilson 95% interval for a proportion p on n valid waits (z = 1.96, z^2 = 3.8416):
--   center = (p + z^2/(2n)) / (1 + z^2/n);  half = z * sqrt(p(1-p)/n + z^2/(4n^2)) / (1 + z^2/n);  interval = center +/- half.
CREATE OR REPLACE TABLE zhw_hotspots AS
WITH base AS (
    SELECT
        c.*,
        c.n_wait_ge10 * 1.0 / c.n_valid                                          AS p,
        SUM(c.n_valid)     OVER (PARTITION BY c.request_isodow, c.request_hour)  AS slot_n_valid,
        SUM(c.n_wait_ge10) OVER (PARTITION BY c.request_isodow, c.request_hour)  AS slot_n_ge10,
        SUM(c.n_valid)     OVER (PARTITION BY c.PULocationID)                    AS zone_n_valid,
        SUM(c.n_wait_ge10) OVER (PARTITION BY c.PULocationID)                    AS zone_n_ge10
    FROM zhw_cells c
    WHERE c.n_valid > 0
),
w AS (
    SELECT
        *,
        slot_n_ge10 * 1.0 / slot_n_valid                                         AS slot_frac,
        zone_n_ge10 * 1.0 / zone_n_valid                                         AS zone_frac,
        (p + 1.9208 / n_valid) / (1 + 3.8416 / n_valid)                          AS center,
        1.96 * sqrt(p * (1 - p) / n_valid + 0.9604 / (n_valid * 1.0 * n_valid)) / (1 + 3.8416 / n_valid) AS half
    FROM base
)
SELECT
    PULocationID,
    pu_borough,
    pu_zone,
    request_isodow,
    request_hour,
    n_days,
    n_scoped,
    n_valid,
    n_excluded_negative_wait,
    ROUND(100.0 * n_excluded_negative_wait / n_scoped, 3)                        AS pct_excluded,
    ROUND(1.0 * n_scoped / n_days, 1)                                            AS avg_trips_per_day,
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

-- name: cells_reconcile
-- Expected: 260 zones, 168 slots, n_scoped 20,404,892, n_valid 20,205,118, excluded 199,774. Empty cells = possible minus present.
SELECT
    COUNT(*)                                          AS n_cells,
    COUNT(DISTINCT PULocationID)                      AS n_zones,
    COUNT(DISTINCT request_isodow * 100 + request_hour) AS n_slots,
    260 * 168                                         AS max_possible_cells,
    260 * 168 - COUNT(*)                              AS empty_cells,
    COUNT(*) FILTER (WHERE n_valid = 0)               AS cells_with_no_valid_wait,
    SUM(n_scoped)                                     AS n_scoped,
    SUM(n_valid)                                      AS n_valid,
    SUM(n_excluded_negative_wait)                     AS n_excluded
FROM zhw_cells;

-- name: cell_size_distribution
-- How much of the data sits in cells big enough to rank?
SELECT
    sample_tier,
    COUNT(*)                                                         AS n_cells,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)               AS pct_of_cells,
    SUM(n_valid)                                                     AS valid_rows,
    ROUND(100.0 * SUM(n_valid) / SUM(SUM(n_valid)) OVER (), 2)       AS pct_of_valid_rows
FROM zhw_cells
GROUP BY 1
ORDER BY 1;

-- name: cell_size_quantiles
SELECT
    MIN(n_valid)                    AS min_n,
    quantile_cont(n_valid, 0.10)    AS p10_n,
    quantile_cont(n_valid, 0.25)    AS p25_n,
    quantile_cont(n_valid, 0.50)    AS median_n,
    quantile_cont(n_valid, 0.75)    AS p75_n,
    quantile_cont(n_valid, 0.90)    AS p90_n,
    MAX(n_valid)                    AS max_n
FROM zhw_cells;

-- name: slot_baseline
-- Five-borough share of valid waits >= 10 minutes for each of the 168 weekday-hour slots (the hotspot baseline).
SELECT
    request_isodow,
    request_hour,
    SUM(n_scoped)                                                      AS n_scoped,
    SUM(n_valid)                                                       AS n_valid,
    SUM(n_excluded_negative_wait)                                      AS n_excluded_negative_wait,
    ROUND(100.0 * SUM(n_excluded_negative_wait) / SUM(n_scoped), 3)    AS pct_excluded,
    SUM(n_wait_ge10)                                                   AS n_wait_ge10,
    ROUND(100.0 * SUM(n_wait_ge10) / SUM(n_valid), 3)                  AS pct_wait_ge10
FROM zhw_cells
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: hotspot_summary
-- Counts of eligible cells and hotspots, with the multiplier sensitivity (1.5x, 2x, 3x), and how much of the
-- five-borough long-wait volume sits inside hotspot cells.
SELECT
    COUNT(*)                                                                          AS n_cells_with_valid_wait,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                                AS n_adequate_cells,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate' AND wilson_low_frac >= 1.5 * slot_frac) AS n_hotspot_1_5x,
    COUNT(*) FILTER (WHERE hotspot_flag)                                              AS n_hotspot_2x,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate' AND wilson_low_frac >= 3 * slot_frac)   AS n_hotspot_3x,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)                                       AS n_hotspot_robust_2x,
    SUM(n_valid)     FILTER (WHERE hotspot_flag)                                      AS valid_rows_in_hotspots,
    SUM(n_wait_ge10) FILTER (WHERE hotspot_flag)                                      AS long_waits_in_hotspots,
    SUM(n_wait_ge10)                                                                  AS long_waits_all_cells,
    ROUND(100.0 * SUM(n_wait_ge10) FILTER (WHERE hotspot_flag) / SUM(n_wait_ge10), 2) AS pct_of_long_waits_in_hotspots,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE hotspot_flag) / SUM(n_valid), 2)         AS pct_of_valid_rows_in_hotspots
FROM zhw_hotspots;

-- name: hotspot_top_by_rate
-- Hotspot cells ranked by the LOWER end of the interval (conservative). Read with n_valid and pct_excluded beside each row.
SELECT
    pu_borough, pu_zone, request_isodow, request_hour,
    n_valid, pct_excluded, avg_trips_per_day,
    pct_wait_ge10, pct_wait_ge10_wilson_low, pct_ge10_if_excluded_all_short,
    slot_pct_wait_ge10, ratio_vs_slot, zone_pct_wait_ge10_all_hours,
    p50_min, p90_min, pct_uber_of_valid, hotspot_robust_flag
FROM zhw_hotspots
WHERE hotspot_flag
ORDER BY wilson_low_frac DESC
LIMIT 30;

-- name: hotspot_top_by_impact
-- Eligible cells ranked by the NUMBER of long waits (where the most riders waited 10+ minutes), hotspot or not.
SELECT
    pu_borough, pu_zone, request_isodow, request_hour,
    n_valid, n_wait_ge10, pct_excluded, avg_trips_per_day,
    pct_wait_ge10, slot_pct_wait_ge10, ratio_vs_slot, hotspot_flag
FROM zhw_hotspots
WHERE sample_tier = '3_adequate'
ORDER BY n_wait_ge10 DESC
LIMIT 30;

-- name: hotspot_zone_summary
-- Zones with at least one hotspot cell: how many, and how much of the zone's own volume they hold. Top 25.
SELECT
    PULocationID,
    pu_borough,
    pu_zone,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                                  AS n_adequate_cells,
    COUNT(*) FILTER (WHERE hotspot_flag)                                                AS n_hotspot_cells,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)                                         AS n_robust_cells,
    SUM(n_valid)                                                                        AS zone_n_valid,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE hotspot_flag) / SUM(n_valid), 2)           AS pct_valid_rows_in_hotspots,
    ROUND(MAX(zone_pct_wait_ge10_all_hours), 3)                                         AS zone_pct_wait_ge10_all_hours
FROM zhw_hotspots
GROUP BY 1, 2, 3
HAVING COUNT(*) FILTER (WHERE hotspot_flag) > 0
ORDER BY n_hotspot_cells DESC, zone_n_valid DESC
LIMIT 25;

-- name: hotspot_by_slot
-- Hotspot cells per weekday-hour slot (pivot in the notebook).
SELECT
    request_isodow,
    request_hour,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')  AS n_adequate_cells,
    COUNT(*) FILTER (WHERE hotspot_flag)                AS n_hotspot_cells,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)         AS n_robust_cells
FROM zhw_hotspots
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: hotspot_by_borough
SELECT
    pu_borough,
    COUNT(DISTINCT PULocationID)                                          AS n_zones,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                    AS n_adequate_cells,
    COUNT(*) FILTER (WHERE hotspot_flag)                                  AS n_hotspot_cells,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)                           AS n_robust_cells,
    ROUND(100.0 * COUNT(*) FILTER (WHERE hotspot_flag)
          / NULLIF(COUNT(*) FILTER (WHERE sample_tier = '3_adequate'), 0), 2) AS pct_adequate_cells_hotspot,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE hotspot_flag) / SUM(n_valid), 2) AS pct_valid_rows_in_hotspots
FROM zhw_hotspots
GROUP BY 1
ORDER BY n_hotspot_cells DESC;