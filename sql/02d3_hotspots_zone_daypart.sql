-- Stage 2D3: Design C hotspots = pickup zone x daypart x day type (5 dayparts x Mon-Fri/Sat-Sun = 10 slots).
-- The fine design (02d) and the zone x hour design (02d2) are untouched; their tables (zhw_*, zh_*) are only READ here.
-- UNCHANGED from 02d / 02d2 (all pre-set there): D6 request time; D11 valid waits; D12 n_valid and exclusion shown; D14/D15 five-borough
-- population; long wait = valid wait >= 10 minutes; eligible = n_valid >= 1,000 (threshold NOT lowered); hotspot = Wilson 95% lower end
-- of the long-wait share >= 2x the share for the same slot; robust = still >= 2x if every excluded negative-wait row were short.
-- Dayparts: 1_overnight_0-5 | 2_morning_6-9 | 3_midday_10-15 | 4_evening_peak_16-19 | 5_late_evening_20-23.
-- ADDED here (pre-set before results; none replaces the rule above):
--   1. coverage tables with distinct columns: total_valid_rows (denominator), valid_rows_in_adequate_cells (numerator), pct (ratio).
--      The earlier coverage_tradeoff block's "valid_rows" was the TOTAL for every design; the percentages were right, the name was misleading.
--   2. hotspot_type, separating zone-level severity from time-specific excess:
--        'time-specific' = hotspot AND the cell's Wilson lower end is >= 1.5x the zone's OWN long-wait share over all slots;
--        'persistent'    = hotspot but not time-specific (the zone is slow nearly all the time).
--   3. zone severity: a zone is 'severe' if n_valid >= 1,000 and the Wilson lower end of its all-slot long-wait share is >= 2x the
--      five-borough share. This describes a zone whether or not its individual cells are large enough to rank.
--   4. excess_long_waits_vs_slot / _vs_zone = observed long waits minus the number expected at the baseline rate (combines rate and volume).
--   5. baseline sensitivity: slot baseline recomputed WITHOUT airport zones (names containing "Airport"). The main rule keeps airports in
--      the baseline; the sensitivity shows how much that choice changes the hotspot count.
-- Descriptive only. Caveats: many cells are tested (multiple comparisons); the same month is used to find and to describe hotspots;
-- the Wilson interval assumes independent trips, but trips in one place and time are correlated (weather, events), so intervals are
-- optimistic; company mix is shown (pct_uber_of_valid) not controlled (Stage 2E).
-- Requires: trips_features, and for coverage_cells / zh_hotspots the tables built by 02d2 (notebook rebuilds them if missing).

-- name: create_zdd_cells
-- MATERIALIZED TABLE (at most 260 x 10 = 2,600 rows). One heavy pass over the 20M rows (about a minute).
-- n_days = January calendar days of that day type (Mon-Fri 23, Sat-Sun 8); the 1,164 Dec 31 and 5 Feb 1 request rows are not counted in n_days.
CREATE OR REPLACE TABLE zdd_cells AS
WITH t AS (
    SELECT
        PULocationID, pu_borough, pu_zone, company, in_geo_wait_tables, wait_minutes,
        CASE WHEN request_hour < 6  THEN '1_overnight_0-5'
             WHEN request_hour < 10 THEN '2_morning_6-9'
             WHEN request_hour < 16 THEN '3_midday_10-15'
             WHEN request_hour < 20 THEN '4_evening_peak_16-19'
             ELSE                        '5_late_evening_20-23' END AS daypart,
        CASE WHEN request_isodow <= 5 THEN 'Mon-Fri' ELSE 'Sat-Sun' END AS day_type
    FROM trips_features
    WHERE NOT flag_pickup_outside_nyc
),
days AS (
    SELECT CASE WHEN request_isodow <= 5 THEN 'Mon-Fri' ELSE 'Sat-Sun' END AS day_type,
           COUNT(DISTINCT request_date) AS n_days
    FROM trips_features
    WHERE request_date BETWEEN DATE '2025-01-01' AND DATE '2025-01-31'
    GROUP BY 1
)
SELECT
    t.PULocationID,
    t.pu_borough,
    t.pu_zone,
    t.daypart,
    t.day_type,
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
FROM t
JOIN days d ON d.day_type = t.day_type
GROUP BY t.PULocationID, t.pu_borough, t.pu_zone, t.daypart, t.day_type, d.n_days;

-- name: create_zdd_hotspots
-- Same construction as zhw_hotspots / zh_hotspots with the daypart x day-type slot as the baseline unit, plus the additions above.
-- Wilson 95% interval (z = 1.96, z^2 = 3.8416): center = (p + z^2/(2n)) / (1 + z^2/n); half = z*sqrt(p(1-p)/n + z^2/(4n^2)) / (1 + z^2/n).
CREATE OR REPLACE TABLE zdd_hotspots AS
WITH base AS (
    SELECT
        c.*,
        c.n_wait_ge10 * 1.0 / c.n_valid                                                           AS p,
        SUM(c.n_valid)     OVER (PARTITION BY c.daypart, c.day_type)                              AS slot_n_valid,
        SUM(c.n_wait_ge10) OVER (PARTITION BY c.daypart, c.day_type)                              AS slot_n_ge10,
        SUM(CASE WHEN c.pu_zone NOT ILIKE '%airport%' THEN c.n_valid END)     OVER (PARTITION BY c.daypart, c.day_type) AS slot_n_valid_xa,
        SUM(CASE WHEN c.pu_zone NOT ILIKE '%airport%' THEN c.n_wait_ge10 END) OVER (PARTITION BY c.daypart, c.day_type) AS slot_n_ge10_xa,
        SUM(c.n_valid)     OVER (PARTITION BY c.PULocationID)                                     AS zone_n_valid,
        SUM(c.n_wait_ge10) OVER (PARTITION BY c.PULocationID)                                     AS zone_n_ge10
    FROM zdd_cells c
    WHERE c.n_valid > 0
),
w AS (
    SELECT
        *,
        slot_n_ge10 * 1.0 / slot_n_valid                                          AS slot_frac,
        slot_n_ge10_xa * 1.0 / slot_n_valid_xa                                    AS slot_frac_xa,
        zone_n_ge10 * 1.0 / zone_n_valid                                          AS zone_frac,
        (p + 1.9208 / n_valid) / (1 + 3.8416 / n_valid)                           AS center,
        1.96 * sqrt(p * (1 - p) / n_valid + 0.9604 / (n_valid * 1.0 * n_valid)) / (1 + 3.8416 / n_valid) AS half
    FROM base
)
SELECT
    PULocationID,
    pu_borough,
    pu_zone,
    daypart,
    day_type,
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
    ROUND(100 * slot_frac_xa, 3)                                                 AS slot_pct_wait_ge10_ex_airports,
    ROUND(100 * zone_frac, 3)                                                    AS zone_pct_wait_ge10_all_slots,
    ROUND(p / NULLIF(slot_frac, 0), 2)                                           AS ratio_vs_slot,
    ROUND(100 * (p - slot_frac), 3)                                              AS excess_vs_slot_pts,
    ROUND(100 * (p - zone_frac), 3)                                              AS excess_vs_zone_pts,
    ROUND(n_wait_ge10 - n_valid * slot_frac, 1)                                  AS excess_long_waits_vs_slot,
    ROUND(n_wait_ge10 - n_valid * zone_frac, 1)                                  AS excess_long_waits_vs_zone,
    (center - half)                                                              AS wilson_low_frac,
    slot_frac,
    (sample_tier = '3_adequate' AND (center - half) >= 2 * slot_frac)            AS hotspot_flag,
    (sample_tier = '3_adequate' AND (center - half) >= 2 * slot_frac
        AND n_wait_ge10 * 1.0 / n_scoped >= 2 * slot_frac)                       AS hotspot_robust_flag,
    CASE WHEN NOT (sample_tier = '3_adequate' AND (center - half) >= 2 * slot_frac) THEN NULL
         WHEN (center - half) >= 1.5 * zone_frac THEN 'time-specific'
         ELSE 'persistent' END                                                   AS hotspot_type,
    (sample_tier = '3_adequate' AND (center - half) >= 2 * slot_frac_xa)         AS hotspot_flag_ex_airport_baseline,
    (pu_zone ILIKE '%airport%')                                                  AS is_airport_zone
FROM w;

-- name: create_zdd_zone_severity
-- Zone-level picture over all slots (always computable), against the five-borough share of long waits.
CREATE OR REPLACE TABLE zdd_zone_severity AS
WITH z AS (
    SELECT
        PULocationID, pu_borough, pu_zone,
        SUM(n_scoped)                                         AS n_scoped,
        SUM(n_valid)                                          AS n_valid,
        SUM(n_excluded_negative_wait)                         AS n_excluded,
        SUM(n_wait_ge10)                                      AS n_ge10,
        COUNT(*) FILTER (WHERE sample_tier = '3_adequate')    AS n_adequate_cells
    FROM zdd_cells
    GROUP BY 1, 2, 3
),
c AS (SELECT SUM(n_ge10) * 1.0 / SUM(n_valid) AS city_frac FROM z),
zp AS (
    SELECT z.*, c.city_frac, z.n_ge10 * 1.0 / z.n_valid AS p
    FROM z CROSS JOIN c
    WHERE z.n_valid > 0
),
w AS (
    SELECT
        *,
        (p + 1.9208 / n_valid) / (1 + 3.8416 / n_valid)                           AS center,
        1.96 * sqrt(p * (1 - p) / n_valid + 0.9604 / (n_valid * 1.0 * n_valid)) / (1 + 3.8416 / n_valid) AS half
    FROM zp
)
SELECT
    PULocationID,
    pu_borough,
    pu_zone,
    n_scoped,
    n_valid,
    n_excluded,
    ROUND(100.0 * n_excluded / n_scoped, 3)                  AS pct_excluded,
    n_ge10                                                   AS n_wait_ge10,
    ROUND(100 * p, 3)                                        AS zone_pct_wait_ge10,
    ROUND(100 * (center - half), 3)                          AS zone_pct_wait_ge10_wilson_low,
    ROUND(100 * city_frac, 3)                                AS city_pct_wait_ge10,
    ROUND(p / city_frac, 2)                                  AS ratio_vs_city,
    n_adequate_cells,
    (n_valid >= 1000 AND (center - half) >= 2 * city_frac)   AS zone_severity_flag
FROM w;

-- name: zdd_cells_reconcile
-- Expected: 260 zones, 10 slots, n_scoped 20,404,892, n_valid 20,205,118, excluded 199,774; n_days Mon-Fri 23 and Sat-Sun 8.
SELECT
    COUNT(*)                                  AS n_cells,
    COUNT(DISTINCT PULocationID)              AS n_zones,
    COUNT(DISTINCT daypart || '|' || day_type) AS n_slots,
    260 * 10 - COUNT(*)                       AS empty_cells,
    COUNT(*) FILTER (WHERE n_valid = 0)       AS cells_with_no_valid_wait,
    SUM(n_scoped)                             AS n_scoped,
    SUM(n_valid)                              AS n_valid,
    SUM(n_excluded_negative_wait)             AS n_excluded,
    MAX(n_days) FILTER (WHERE day_type = 'Mon-Fri') AS n_days_mon_fri,
    MAX(n_days) FILTER (WHERE day_type = 'Sat-Sun') AS n_days_sat_sun
FROM zdd_cells;

-- name: coverage_tradeoff_v2
-- Corrected coverage table. total_valid_rows is the SAME denominator for every design (20,205,118);
-- valid_rows_in_adequate_cells is the numerator; pct is their ratio.
-- Expected: A 7,914,749 (39.17%); B 19,496,072 (96.49%); C 99.18%; D 99.81%; E 99.98%.
SELECT
    design,
    COUNT(DISTINCT slot)                                                                 AS n_slots,
    COUNT(*)                                                                             AS n_cells,
    COUNT(*) FILTER (WHERE n_valid >= 1000)                                              AS n_adequate_cells,
    COUNT(DISTINCT PULocationID) FILTER (WHERE n_valid >= 1000)                          AS zones_with_adequate_cell,
    SUM(n_valid)                                                                         AS total_valid_rows,
    COALESCE(SUM(n_valid) FILTER (WHERE n_valid >= 1000), 0)                             AS valid_rows_in_adequate_cells,
    ROUND(100.0 * COALESCE(SUM(n_valid) FILTER (WHERE n_valid >= 1000), 0) / SUM(n_valid), 2) AS pct_valid_rows_in_adequate_cells
FROM coverage_cells
GROUP BY design
ORDER BY design;

-- name: coverage_tradeoff_by_borough_v2
SELECT
    design,
    pu_borough,
    COUNT(DISTINCT PULocationID)                                                         AS n_zones,
    COUNT(*)                                                                             AS n_cells,
    COUNT(*) FILTER (WHERE n_valid >= 1000)                                              AS n_adequate_cells,
    COUNT(DISTINCT PULocationID) FILTER (WHERE n_valid >= 1000)                          AS zones_with_adequate_cell,
    SUM(n_valid)                                                                         AS total_valid_rows,
    COALESCE(SUM(n_valid) FILTER (WHERE n_valid >= 1000), 0)                             AS valid_rows_in_adequate_cells,
    ROUND(100.0 * COALESCE(SUM(n_valid) FILTER (WHERE n_valid >= 1000), 0) / SUM(n_valid), 2) AS pct_valid_rows_in_adequate_cells
FROM coverage_cells
GROUP BY design, pu_borough
ORDER BY design, pu_borough;

-- name: zdd_borough_summary
-- Design C coverage AND hotspots, overall and by borough (ALL = five boroughs). Long-wait coverage = share of all long waits.
WITH cov AS (
    SELECT
        pu_borough,
        COUNT(*)                                                                    AS n_cells,
        COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                          AS n_adequate_cells,
        SUM(n_valid)                                                                AS total_valid_rows,
        COALESCE(SUM(n_valid) FILTER (WHERE sample_tier = '3_adequate'), 0)         AS valid_rows_in_adequate_cells,
        SUM(n_wait_ge10)                                                            AS total_long_waits,
        COALESCE(SUM(n_wait_ge10) FILTER (WHERE sample_tier = '3_adequate'), 0)     AS long_waits_in_adequate_cells
    FROM zdd_cells
    GROUP BY GROUPING SETS ((), (pu_borough))
),
hs AS (
    SELECT
        pu_borough,
        COUNT(*) FILTER (WHERE hotspot_flag)                                        AS n_hotspot_cells,
        COUNT(*) FILTER (WHERE hotspot_robust_flag)                                 AS n_robust_cells,
        COUNT(*) FILTER (WHERE hotspot_type = 'time-specific')                      AS n_time_specific,
        COUNT(*) FILTER (WHERE hotspot_type = 'persistent')                         AS n_persistent,
        COALESCE(SUM(n_valid)     FILTER (WHERE hotspot_flag), 0)                   AS valid_rows_in_hotspots,
        COALESCE(SUM(n_wait_ge10) FILTER (WHERE hotspot_flag), 0)                   AS long_waits_in_hotspots
    FROM zdd_hotspots
    GROUP BY GROUPING SETS ((), (pu_borough))
)
SELECT
    COALESCE(cov.pu_borough, 'ALL')                                                                        AS pu_borough,
    cov.n_cells,
    cov.n_adequate_cells,
    cov.total_valid_rows,
    cov.valid_rows_in_adequate_cells,
    ROUND(100.0 * cov.valid_rows_in_adequate_cells / cov.total_valid_rows, 2)                              AS pct_valid_rows_in_adequate_cells,
    cov.total_long_waits,
    cov.long_waits_in_adequate_cells,
    ROUND(100.0 * cov.long_waits_in_adequate_cells / cov.total_long_waits, 2)                              AS pct_long_waits_in_adequate_cells,
    hs.n_hotspot_cells,
    hs.n_robust_cells,
    hs.n_time_specific,
    hs.n_persistent,
    hs.valid_rows_in_hotspots,
    ROUND(100.0 * hs.valid_rows_in_hotspots / cov.total_valid_rows, 2)                                     AS pct_valid_rows_in_hotspots,
    hs.long_waits_in_hotspots,
    ROUND(100.0 * hs.long_waits_in_hotspots / cov.total_long_waits, 2)                                     AS pct_long_waits_in_hotspots
FROM cov
JOIN hs ON cov.pu_borough IS NOT DISTINCT FROM hs.pu_borough
ORDER BY CASE WHEN cov.pu_borough IS NULL THEN 0 ELSE 1 END, hs.n_hotspot_cells DESC;

-- name: zdd_hotspot_summary
-- Counts with the multiplier sensitivity (1.5x, 2x, 3x), hotspot type, and the airport-baseline sensitivity.
SELECT
    COUNT(*)                                                                                  AS n_cells_with_valid_wait,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                                        AS n_adequate_cells,
    COUNT(DISTINCT PULocationID) FILTER (WHERE sample_tier = '3_adequate')                    AS n_zones_with_adequate_cell,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate' AND wilson_low_frac >= 1.5 * slot_frac) AS n_hotspot_1_5x,
    COUNT(*) FILTER (WHERE hotspot_flag)                                                      AS n_hotspot_2x,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate' AND wilson_low_frac >= 3 * slot_frac)   AS n_hotspot_3x,
    COUNT(*) FILTER (WHERE hotspot_robust_flag)                                               AS n_hotspot_robust_2x,
    COUNT(*) FILTER (WHERE hotspot_type = 'time-specific')                                    AS n_time_specific,
    COUNT(*) FILTER (WHERE hotspot_type = 'persistent')                                       AS n_persistent,
    COUNT(*) FILTER (WHERE hotspot_flag AND is_airport_zone)                                  AS n_hotspot_in_airport_zones,
    COUNT(*) FILTER (WHERE hotspot_flag_ex_airport_baseline)                                  AS n_hotspot_ex_airport_baseline,
    COUNT(*) FILTER (WHERE hotspot_flag_ex_airport_baseline AND NOT hotspot_flag)             AS n_added_by_ex_airport_baseline,
    COUNT(*) FILTER (WHERE hotspot_flag AND NOT hotspot_flag_ex_airport_baseline)             AS n_lost_by_ex_airport_baseline,
    COUNT(DISTINCT PULocationID) FILTER (WHERE hotspot_flag)                                  AS n_zones_with_hotspot
FROM zdd_hotspots;

-- name: zdd_hotspot_by_slot
-- Hotspots per daypart x day type, with the slot baseline and exclusion share (D12).
SELECT
    daypart,
    day_type,
    COUNT(*) FILTER (WHERE sample_tier = '3_adequate')                  AS n_adequate_cells,
    COUNT(*) FILTER (WHERE hotspot_flag)                                AS n_hotspot_cells,
    COUNT(*) FILTER (WHERE hotspot_type = 'time-specific')              AS n_time_specific,
    ROUND(MAX(slot_pct_wait_ge10), 3)                                   AS slot_pct_wait_ge10,
    ROUND(MAX(slot_pct_wait_ge10_ex_airports), 3)                       AS slot_pct_wait_ge10_ex_airports,
    ROUND(100.0 * SUM(n_excluded_negative_wait) / SUM(n_scoped), 3)     AS pct_excluded
FROM zdd_hotspots
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: zdd_staten_island
-- Every Staten Island zone: size, zone-level severity, how many of its 10 slots are eligible, and its hotspots.
SELECT
    s.PULocationID,
    s.pu_zone,
    s.n_valid,
    s.pct_excluded,
    s.n_adequate_cells,
    s.zone_pct_wait_ge10,
    s.ratio_vs_city,
    s.zone_severity_flag,
    COALESCE(h.n_hotspot_cells, 0)  AS n_hotspot_cells,
    COALESCE(h.n_time_specific, 0)  AS n_time_specific_cells
FROM zdd_zone_severity s
LEFT JOIN (
    SELECT PULocationID,
           COUNT(*) FILTER (WHERE hotspot_flag)                     AS n_hotspot_cells,
           COUNT(*) FILTER (WHERE hotspot_type = 'time-specific')   AS n_time_specific
    FROM zdd_hotspots
    GROUP BY 1
) h ON h.PULocationID = s.PULocationID
WHERE s.pu_borough = 'Staten Island'
ORDER BY s.n_valid DESC;

-- name: zone_severity_summary
-- How many zones are persistently severe (zone-level share of long waits >= 2x the five-borough share), by borough?
SELECT
    pu_borough,
    COUNT(*)                                                                         AS n_zones,
    COUNT(*) FILTER (WHERE n_valid >= 1000)                                          AS n_zones_eligible,
    COUNT(*) FILTER (WHERE zone_severity_flag)                                       AS n_zones_severe,
    ROUND(100.0 * SUM(n_valid) FILTER (WHERE zone_severity_flag) / SUM(n_valid), 2)  AS pct_valid_rows_in_severe_zones,
    ROUND(100.0 * SUM(n_wait_ge10) FILTER (WHERE zone_severity_flag) / SUM(n_wait_ge10), 2) AS pct_long_waits_in_severe_zones,
    ROUND(MAX(city_pct_wait_ge10), 3)                                                AS city_pct_wait_ge10
FROM zdd_zone_severity
GROUP BY 1
ORDER BY n_zones_severe DESC;

-- name: zone_severity_top
-- The 25 eligible zones with the highest all-slot share of long waits, with their hotspot cells (of 10 slots).
SELECT
    s.pu_borough, s.pu_zone, s.n_valid, s.pct_excluded,
    s.zone_pct_wait_ge10, s.zone_pct_wait_ge10_wilson_low, s.ratio_vs_city, s.zone_severity_flag,
    s.n_adequate_cells,
    COALESCE(h.n_hotspot_cells, 0) AS n_hotspot_cells,
    COALESCE(h.n_time_specific, 0) AS n_time_specific_cells
FROM zdd_zone_severity s
LEFT JOIN (
    SELECT PULocationID,
           COUNT(*) FILTER (WHERE hotspot_flag)                     AS n_hotspot_cells,
           COUNT(*) FILTER (WHERE hotspot_type = 'time-specific')   AS n_time_specific
    FROM zdd_hotspots
    GROUP BY 1
) h ON h.PULocationID = s.PULocationID
WHERE s.n_valid >= 1000
ORDER BY s.zone_pct_wait_ge10 DESC
LIMIT 25;

-- name: zdd_top_by_rate
-- Hotspot cells ranked by the LOWER end of the interval (conservative). Read hotspot_type and excess_vs_zone_pts with it.
SELECT
    pu_borough, pu_zone, daypart, day_type,
    n_valid, pct_excluded, avg_trips_per_day,
    pct_wait_ge10, pct_wait_ge10_wilson_low, pct_ge10_if_excluded_all_short,
    slot_pct_wait_ge10, ratio_vs_slot, zone_pct_wait_ge10_all_slots, excess_vs_zone_pts,
    hotspot_type, p50_min, p90_min, pct_uber_of_valid, hotspot_robust_flag
FROM zdd_hotspots
WHERE hotspot_flag
ORDER BY wilson_low_frac DESC
LIMIT 30;

-- name: zdd_top_non_airport_by_rate
-- DISPLAY AID ONLY (not a rule): same ranking with airport zones hidden.
SELECT
    pu_borough, pu_zone, daypart, day_type,
    n_valid, pct_excluded, avg_trips_per_day,
    pct_wait_ge10, pct_wait_ge10_wilson_low, pct_ge10_if_excluded_all_short,
    slot_pct_wait_ge10, ratio_vs_slot, zone_pct_wait_ge10_all_slots, excess_vs_zone_pts,
    hotspot_type, p50_min, p90_min, pct_uber_of_valid, hotspot_robust_flag
FROM zdd_hotspots
WHERE hotspot_flag AND NOT is_airport_zone
ORDER BY wilson_low_frac DESC
LIMIT 30;

-- name: zdd_top_by_impact
-- Eligible cells ranked by the NUMBER of long waits, hotspot or not: where the most riders waited 10+ minutes.
SELECT
    pu_borough, pu_zone, daypart, day_type,
    n_valid, n_wait_ge10, pct_excluded, avg_trips_per_day,
    pct_wait_ge10, slot_pct_wait_ge10, ratio_vs_slot, hotspot_flag, hotspot_type
FROM zdd_hotspots
WHERE sample_tier = '3_adequate'
ORDER BY n_wait_ge10 DESC
LIMIT 30;

-- name: zdd_top_by_excess
-- Hotspot cells ranked by EXCESS long waits above the slot baseline expectation (combines rate and volume).
SELECT
    pu_borough, pu_zone, daypart, day_type,
    n_valid, n_wait_ge10, excess_long_waits_vs_slot, excess_long_waits_vs_zone,
    pct_excluded, pct_wait_ge10, slot_pct_wait_ge10, ratio_vs_slot, hotspot_type
FROM zdd_hotspots
WHERE hotspot_flag
ORDER BY excess_long_waits_vs_slot DESC
LIMIT 30;

-- name: zdd_vs_zone_hour
-- Do the same zones flag in Design B (zone x hour) and Design C? Requires zh_hotspots (built by 02d2).
WITH b AS (SELECT DISTINCT PULocationID FROM zh_hotspots  WHERE hotspot_flag),
     c AS (SELECT DISTINCT PULocationID FROM zdd_hotspots WHERE hotspot_flag)
SELECT
    COUNT(*) FILTER (WHERE b.PULocationID IS NOT NULL AND c.PULocationID IS NOT NULL) AS zones_flagged_in_both,
    COUNT(*) FILTER (WHERE b.PULocationID IS NOT NULL AND c.PULocationID IS NULL)     AS zones_only_in_zone_hour,
    COUNT(*) FILTER (WHERE b.PULocationID IS NULL AND c.PULocationID IS NOT NULL)     AS zones_only_in_daypart
FROM b
FULL OUTER JOIN c ON c.PULocationID = b.PULocationID;