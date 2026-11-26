-- Stage 2G, STEP 1: define the groups and check they are big enough to compare. READ-ONLY on trips_features.
-- Rules reused (D13): shared-ride analysis is UBER-ONLY (no Lyft row has shared_request_flag = Y);
-- WAV analysis is keyed on wav_request_flag (demand for an accessible vehicle). A trip in a WAV vehicle that was NOT requested as WAV
-- is a separate group, never called a "WAV request".
-- D11/D12: wait statistics use valid waits; every table shows n_rows, n_valid and the excluded share. Population = all scoped rows
-- (these are not geographic tables, D14). No model, no inferential test, association language only.
-- Later steps (not in this file yet): like-for-like waits by zone x daypart, pay by distance band, exclusion bounds for WAV.

-- name: shared_groups_overview
-- Uber only. Expected rows 471,930 / 365,342 / 14,519,183 (sum 15,356,455); excluded share about 1.090% / 0.971% / 0.773%;
-- median valid wait about 7.017 / 5.700 / 3.700 min; median miles about 5.70 / 2.33 / 2.82 (Stage 1D profile).
-- The new columns here are p90 and the share of waits >= 10 minutes.
SELECT
    CASE WHEN shared_request_flag = 'Y' AND shared_match_flag = 'Y' THEN '1_shared requested, matched'
         WHEN shared_request_flag = 'Y'                             THEN '2_shared requested, not matched'
         ELSE                                                            '3_not shared' END      AS shared_group,
    COUNT(*)                                                                                   AS n_rows,
    COUNT(*) FILTER (WHERE is_wait_valid)                                                      AS n_valid,
    COUNT(*) - COUNT(*) FILTER (WHERE is_wait_valid)                                           AS n_excluded_negative_wait,
    ROUND(100.0 * (COUNT(*) - COUNT(*) FILTER (WHERE is_wait_valid)) / COUNT(*), 3)            AS pct_excluded,
    ROUND(quantile_cont(wait_minutes, 0.50) FILTER (WHERE is_wait_valid), 3)                   AS wait_p50_min,
    ROUND(quantile_cont(wait_minutes, 0.90) FILTER (WHERE is_wait_valid), 3)                   AS wait_p90_min,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_wait_valid AND wait_minutes >= 10)
          / COUNT(*) FILTER (WHERE is_wait_valid), 3)                                          AS pct_wait_ge10,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                                  AS median_miles
FROM trips_features
WHERE company = 'Uber'
GROUP BY 1
ORDER BY 1;

-- name: wav_groups_overview
-- By company. Expected rows: Uber 37,074 / 1,153,806 / 14,165,575; Lyft 14,076 / 649,557 / 4,385,578.
-- Expected excluded share (from the Stage 1A flag grid): Uber 1.831% / 0.584% / 0.802%; Lyft 37.326% / 1.679% / 1.429%.
-- Lyft WAV-requested trips keep only 8,822 valid waits: read that group with great care.
-- pct_access_a_ride = share of the group flagged Access-a-Ride (MTA-administered, likely pre-booked).
SELECT
    company,
    CASE WHEN wav_request_flag = 'Y' THEN '1_WAV requested'
         WHEN wav_match_flag   = 'Y' THEN '2_WAV vehicle, not requested'
         ELSE                             '3_no WAV' END                                       AS wav_group,
    COUNT(*)                                                                                   AS n_rows,
    COUNT(*) FILTER (WHERE is_wait_valid)                                                      AS n_valid,
    COUNT(*) - COUNT(*) FILTER (WHERE is_wait_valid)                                           AS n_excluded_negative_wait,
    ROUND(100.0 * (COUNT(*) - COUNT(*) FILTER (WHERE is_wait_valid)) / COUNT(*), 3)            AS pct_excluded,
    ROUND(quantile_cont(wait_minutes, 0.50) FILTER (WHERE is_wait_valid), 3)                   AS wait_p50_min,
    ROUND(quantile_cont(wait_minutes, 0.90) FILTER (WHERE is_wait_valid), 3)                   AS wait_p90_min,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_wait_valid AND wait_minutes >= 10)
          / COUNT(*) FILTER (WHERE is_wait_valid), 3)                                          AS pct_wait_ge10,
    ROUND(quantile_cont(trip_miles, 0.50), 2)                                                  AS median_miles,
    ROUND(100.0 * COUNT(*) FILTER (WHERE access_a_ride_flag = 'Y') / COUNT(*), 2)              AS pct_access_a_ride
FROM trips_features
GROUP BY company, 2
ORDER BY company DESC, 2;


-- name: shared_vs_not_shared_zone_daypart
WITH base AS (
    SELECT
        PULocationID AS pickup_zone,

        CASE
            WHEN EXTRACT(HOUR FROM request_datetime) BETWEEN 0 AND 5
                THEN '00-05 Overnight'
            WHEN EXTRACT(HOUR FROM request_datetime) BETWEEN 6 AND 9
                THEN '06-09 Morning'
            WHEN EXTRACT(HOUR FROM request_datetime) BETWEEN 10 AND 15
                THEN '10-15 Midday'
            WHEN EXTRACT(HOUR FROM request_datetime) BETWEEN 16 AND 19
                THEN '16-19 Evening'
            ELSE '20-23 Late evening'
        END AS daypart,

        CASE
            WHEN shared_request_flag = 'Y'
                THEN 'Shared requested'
            WHEN shared_request_flag = 'N'
                THEN 'Not shared'
        END AS share_group,

        wait_minutes

    FROM trips_clean
    WHERE hvfhs_license_num = 'HV0003'
      AND request_datetime IS NOT NULL
      AND PULocationID IS NOT NULL
      AND is_wait_valid
      AND shared_request_flag IN ('Y', 'N')
),

raw AS (
    SELECT
        share_group,
        COUNT(*) AS n_valid_waits,

        quantile_cont(wait_minutes, 0.50) AS median_wait_min,
        quantile_cont(wait_minutes, 0.90) AS p90_wait_min,

        100.0 * AVG(
            CASE WHEN wait_minutes >= 10 THEN 1.0 ELSE 0.0 END
        ) AS raw_long_wait_pct

    FROM base
    GROUP BY share_group
),

strata AS (
    SELECT
        pickup_zone,
        daypart,
        share_group,
        COUNT(*) AS n,
        AVG(
            CASE WHEN wait_minutes >= 10 THEN 1.0 ELSE 0.0 END
        ) AS long_wait_rate

    FROM base
    GROUP BY pickup_zone, daypart, share_group
),

common_cells AS (
    SELECT
        pickup_zone,
        daypart,

        MAX(n) FILTER (
            WHERE share_group = 'Shared requested'
        ) AS n_shared,

        MAX(n) FILTER (
            WHERE share_group = 'Not shared'
        ) AS n_not_shared,

        MAX(long_wait_rate) FILTER (
            WHERE share_group = 'Shared requested'
        ) AS rate_shared,

        MAX(long_wait_rate) FILTER (
            WHERE share_group = 'Not shared'
        ) AS rate_not_shared

    FROM strata
    GROUP BY pickup_zone, daypart

    HAVING COUNT(*) = 2
       AND MIN(n) >= 50
),

standardized AS (
    SELECT
        COUNT(*) AS common_cells,
        SUM(n_shared) AS shared_supported_rows,
        SUM(n_not_shared) AS not_shared_supported_rows,

        100.0 * SUM(
            (n_shared + n_not_shared) * rate_shared
        ) / NULLIF(SUM(n_shared + n_not_shared), 0)
            AS shared_standardized_pct,

        100.0 * SUM(
            (n_shared + n_not_shared) * rate_not_shared
        ) / NULLIF(SUM(n_shared + n_not_shared), 0)
            AS not_shared_standardized_pct

    FROM common_cells
)

SELECT
    r.share_group,
    r.n_valid_waits,
    ROUND(r.median_wait_min, 3) AS raw_median_wait_min,
    ROUND(r.p90_wait_min, 3) AS raw_p90_wait_min,
    ROUND(r.raw_long_wait_pct, 3) AS raw_long_wait_pct,

    ROUND(
        CASE
            WHEN r.share_group = 'Shared requested'
                THEN s.shared_standardized_pct
            ELSE s.not_shared_standardized_pct
        END,
        3
    ) AS standardized_long_wait_pct,

    ROUND(
        s.shared_standardized_pct - s.not_shared_standardized_pct,
        3
    ) AS standardized_gap_pp,

    s.common_cells,

    CASE
        WHEN r.share_group = 'Shared requested'
            THEN s.shared_supported_rows
        ELSE s.not_shared_supported_rows
    END AS rows_in_common_cells,

    ROUND(
        100.0 *
        CASE
            WHEN r.share_group = 'Shared requested'
                THEN s.shared_supported_rows
            ELSE s.not_shared_supported_rows
        END / NULLIF(r.n_valid_waits, 0),
        2
    ) AS pct_rows_in_common_cells

FROM raw r
CROSS JOIN standardized s
ORDER BY r.share_group;



files_to_inspect = [
    ("sql/02d_hotspots.sql", "create_zhw_hotspots"),
    ("sql/02d2_hotspots_zone_hour.sql", "create_zh_hotspots"),
    ("sql/02d3_hotspots_zone_daypart.sql", "create_zdd_hotspots"),
    ("sql/02e_company_like_for_like.sql", "ce_design_c_crosscheck"),
]

for file_path, query_name in files_to_inspect:
    queries = load_queries(file_path)

    print(f"\n{'=' * 65}")
    print(f"FILE: {file_path}")
    print(f"QUERY: {query_name}")
    print("=" * 65)

    if query_name in queries:
        print(queries[query_name])
    else:
        print("Query not found in this file.")