-- Stage 2B: geographic wait profile by pickup borough and pickup zone, on trips_features. READ-ONLY.
-- Rules reused, not re-decided:
--   D11  wait statistics use valid waits only (is_wait_valid).
--   D14/D15  geographic wait tables use in_geo_wait_tables = valid wait AND pickup in the five boroughs.
--            The 774 pickups in zones 1 (EWR) and 265 (Outside of NYC) are NOT ranked as a borough or zone here;
--            they stay in company-level totals (Stage 2A) and appear only in geo_reconcile.
--   D12  every table shows n_scoped, n_valid and the negative-wait exclusion count and share.
--   D5   "where" = pickup zone, rolled up to borough.
-- Sample-size tiers for a zone's n_valid (pre-set from order-statistic reasoning, checked by zone_size_distribution):
--   1_very_small: n_valid < 100      not ranked
--   2_small:      100 to 999         shown, flagged, not ranked
--   3_adequate:   1,000 or more      eligible for ranking
-- Descriptive associations only: a zone's wait is not "caused" by the zone (mix of companies, hours, trip types).

-- name: geo_reconcile
-- Reconciles the geographic population to Stage 1 and Stage 2A. Expected:
--   ALL  20,405,666 | outside 774 (valid 760) | five boroughs 20,404,892 | valid_geo 20,205,118 | excluded_geo 199,774
--   Uber 15,356,455 | outside 529 (valid 517) | 15,355,926 | 15,234,971 | 120,955
--   Lyft  5,049,211 | outside 245 (valid 243) |  5,048,966 |  4,970,147 |  78,819
SELECT
    COALESCE(hvfhs_license_num, 'ALL')                                          AS hvfhs_license_num,
    CASE hvfhs_license_num WHEN 'HV0003' THEN 'Uber' WHEN 'HV0005' THEN 'Lyft' ELSE 'All' END AS company,
    COUNT(*)                                                                    AS n_scoped,
    COUNT(*) FILTER (WHERE flag_pickup_outside_nyc)                             AS n_outside_nyc,
    COUNT(*) FILTER (WHERE flag_pickup_outside_nyc AND is_wait_valid)           AS n_outside_nyc_valid,
    COUNT(*) FILTER (WHERE NOT flag_pickup_outside_nyc)                         AS n_scoped_five_boroughs,
    COUNT(*) FILTER (WHERE in_geo_wait_tables)                                  AS n_valid_geo,
    COUNT(*) FILTER (WHERE NOT flag_pickup_outside_nyc AND NOT is_wait_valid)   AS n_excluded_negative_geo
FROM trips_features
GROUP BY ROLLUP(hvfhs_license_num)
ORDER BY CASE hvfhs_license_num WHEN 'HV0003' THEN 1 WHEN 'HV0005' THEN 2 ELSE 3 END;

-- name: zone_size_distribution
-- How big are the zones? Used to confirm the tier cut-offs. Expected: 260 zones, n_valid_total 20,205,118.
WITH z AS (
    SELECT PULocationID, COUNT(*) FILTER (WHERE in_geo_wait_tables) AS n_valid
    FROM trips_features
    WHERE NOT flag_pickup_outside_nyc
    GROUP BY 1
)
SELECT
    COUNT(*)                                                                   AS n_zones,
    SUM(n_valid)                                                               AS n_valid_total,
    MIN(n_valid)                                                               AS min_n,
    quantile_cont(n_valid, 0.10)                                               AS p10_n,
    quantile_cont(n_valid, 0.25)                                               AS p25_n,
    quantile_cont(n_valid, 0.50)                                               AS median_n,
    quantile_cont(n_valid, 0.75)                                               AS p75_n,
    MAX(n_valid)                                                               AS max_n,
    COUNT(*) FILTER (WHERE n_valid < 100)                                      AS zones_lt_100,
    COUNT(*) FILTER (WHERE n_valid >= 100 AND n_valid < 1000)                  AS zones_100_to_999,
    COUNT(*) FILTER (WHERE n_valid >= 1000)                                    AS zones_ge_1000,
    COALESCE(SUM(n_valid) FILTER (WHERE n_valid < 100), 0)                     AS valid_rows_lt_100,
    COALESCE(SUM(n_valid) FILTER (WHERE n_valid >= 100 AND n_valid < 1000), 0) AS valid_rows_100_to_999,
    COALESCE(SUM(n_valid) FILTER (WHERE n_valid >= 1000), 0)                   AS valid_rows_ge_1000
FROM z;

-- name: borough_wait_profile
-- Five boroughs, pooled ('All') and by company. Within each company the five rows add up to the geo_reconcile totals.
WITH q AS (
    SELECT
        company,
        pu_borough,
        COUNT(DISTINCT PULocationID)                                                                   AS n_zones,
        COUNT(*)                                                                                       AS n_scoped,
        COUNT(*) FILTER (WHERE in_geo_wait_tables)                                                     AS n_valid,
        AVG(wait_minutes) FILTER (WHERE in_geo_wait_tables)                                            AS mean_min,
        quantile_cont(wait_minutes, [0.50, 0.75, 0.90, 0.95, 0.99]) FILTER (WHERE in_geo_wait_tables)  AS qs
    FROM trips_features
    WHERE NOT flag_pickup_outside_nyc
    GROUP BY GROUPING SETS ((pu_borough), (company, pu_borough))
)
SELECT
    COALESCE(company, 'All')                           AS company,
    pu_borough,
    n_zones,
    n_scoped,
    n_valid,
    n_scoped - n_valid                                 AS n_excluded_negative_wait,
    ROUND(100.0 * (n_scoped - n_valid) / n_scoped, 3)  AS pct_excluded,
    ROUND(mean_min, 3)                                 AS mean_min,
    ROUND(qs[1], 3)                                    AS p50_min,
    ROUND(qs[2], 3)                                    AS p75_min,
    ROUND(qs[3], 3)                                    AS p90_min,
    ROUND(qs[4], 3)                                    AS p95_min,
    ROUND(qs[5], 3)                                    AS p99_min
FROM q
ORDER BY CASE COALESCE(company, 'All') WHEN 'All' THEN 1 WHEN 'Uber' THEN 2 ELSE 3 END, p50_min DESC;

-- name: zone_wait_profile
-- One row per pickup zone (pooled over companies). pct_uber_of_valid shows the company mix behind each zone's numbers.
-- Ranks (1 = longest median wait) exist only for 3_adequate zones; other zones are shown but never ranked.
-- p99 is omitted at zone level: it needs far more rows than most zones have.
WITH z AS (
    SELECT
        PULocationID,
        pu_borough,
        pu_zone,
        COUNT(*)                                                                           AS n_scoped,
        COUNT(*) FILTER (WHERE in_geo_wait_tables)                                         AS n_valid,
        COUNT(*) FILTER (WHERE in_geo_wait_tables AND company = 'Uber')                    AS n_valid_uber,
        quantile_cont(wait_minutes, [0.50, 0.75, 0.90, 0.95]) FILTER (WHERE in_geo_wait_tables) AS qs
    FROM trips_features
    WHERE NOT flag_pickup_outside_nyc
    GROUP BY 1, 2, 3
),
t AS (
    SELECT
        *,
        CASE WHEN n_valid < 100 THEN '1_very_small' WHEN n_valid < 1000 THEN '2_small' ELSE '3_adequate' END AS sample_tier,
        ROUND(qs[1], 3) AS p50_min,
        ROUND(qs[2], 3) AS p75_min,
        ROUND(qs[3], 3) AS p90_min,
        ROUND(qs[4], 3) AS p95_min
    FROM z
)
SELECT
    PULocationID,
    pu_borough,
    pu_zone,
    n_scoped,
    n_valid,
    n_scoped - n_valid                                          AS n_excluded_negative_wait,
    ROUND(100.0 * (n_scoped - n_valid) / n_scoped, 3)           AS pct_excluded,
    ROUND(100.0 * n_valid_uber / NULLIF(n_valid, 0), 1)         AS pct_uber_of_valid,
    p50_min,
    p75_min,
    p90_min,
    p95_min,
    sample_tier,
    CASE WHEN sample_tier = '3_adequate'
         THEN RANK() OVER (PARTITION BY pu_borough, sample_tier ORDER BY p50_min DESC) END  AS rank_in_borough_p50,
    CASE WHEN sample_tier = '3_adequate'
         THEN RANK() OVER (PARTITION BY sample_tier ORDER BY p50_min DESC) END              AS rank_overall_p50
FROM t
ORDER BY pu_borough, n_valid DESC;

-- name: zone_wait_profile_by_company
-- Zone detail split by company, for Tableau filters. Same metrics, same tiers (tier is based on that company's n_valid
-- in that zone). No ranks: company-level zone ranking belongs to the like-for-like comparison in Stage 2E.
SELECT
    company,
    PULocationID,
    pu_borough,
    pu_zone,
    COUNT(*)                                                                          AS n_scoped,
    COUNT(*) FILTER (WHERE in_geo_wait_tables)                                        AS n_valid,
    COUNT(*) - COUNT(*) FILTER (WHERE in_geo_wait_tables)                             AS n_excluded_negative_wait,
    ROUND(100.0 * (COUNT(*) - COUNT(*) FILTER (WHERE in_geo_wait_tables)) / COUNT(*), 3) AS pct_excluded,
    ROUND(quantile_cont(wait_minutes, 0.50) FILTER (WHERE in_geo_wait_tables), 3)     AS p50_min,
    ROUND(quantile_cont(wait_minutes, 0.75) FILTER (WHERE in_geo_wait_tables), 3)     AS p75_min,
    ROUND(quantile_cont(wait_minutes, 0.90) FILTER (WHERE in_geo_wait_tables), 3)     AS p90_min,
    ROUND(quantile_cont(wait_minutes, 0.95) FILTER (WHERE in_geo_wait_tables), 3)     AS p95_min,
    CASE WHEN COUNT(*) FILTER (WHERE in_geo_wait_tables) < 100  THEN '1_very_small'
         WHEN COUNT(*) FILTER (WHERE in_geo_wait_tables) < 1000 THEN '2_small'
         ELSE '3_adequate' END                                                        AS sample_tier
FROM trips_features
WHERE NOT flag_pickup_outside_nyc
GROUP BY 1, 2, 3, 4
ORDER BY company, pu_borough, n_valid DESC;