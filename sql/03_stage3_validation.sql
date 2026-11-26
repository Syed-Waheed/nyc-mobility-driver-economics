-- name: stage3_schema_probe
DESCRIBE trips_clean;


-- name: stage3_hourly_wait_validation
SELECT
    EXTRACT(HOUR FROM request_datetime)::INTEGER AS request_hour,

    COUNT(*) AS trip_rows,

    COUNT(*) FILTER (
        WHERE is_wait_valid
    ) AS valid_wait_rows,

    COUNT(*) FILTER (
        WHERE is_wait_valid AND wait_minutes >= 10
    ) AS long_wait_rows,

    ROUND(
        quantile_cont(wait_minutes, 0.50)
        FILTER (WHERE is_wait_valid),
        3
    ) AS median_wait_min,

    ROUND(
        quantile_cont(wait_minutes, 0.90)
        FILTER (WHERE is_wait_valid),
        3
    ) AS p90_wait_min,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE is_wait_valid AND wait_minutes >= 10
        ) / NULLIF(
            COUNT(*) FILTER (WHERE is_wait_valid),
            0
        ),
        3
    ) AS long_wait_pct

FROM trips_clean
WHERE request_datetime IS NOT NULL
  AND EXTRACT(HOUR FROM request_datetime) IN (7, 10)

GROUP BY 1
ORDER BY 1;



-- name: stage3_daily_hour_stability
WITH hourly AS (
    SELECT
        CAST(request_datetime AS DATE) AS request_date,
        EXTRACT(HOUR FROM request_datetime)::INTEGER AS request_hour,

        COUNT(*) FILTER (
            WHERE is_wait_valid
        ) AS valid_wait_rows,

        100.0 * COUNT(*) FILTER (
            WHERE is_wait_valid AND wait_minutes >= 10
        ) / NULLIF(
            COUNT(*) FILTER (WHERE is_wait_valid),
            0
        ) AS long_wait_pct,

        quantile_cont(wait_minutes, 0.50)
            FILTER (WHERE is_wait_valid) AS median_wait_min

    FROM trips_clean
    WHERE request_datetime >= TIMESTAMP '2025-01-01 00:00:00'
      AND request_datetime < TIMESTAMP '2025-02-01 00:00:00'
      AND EXTRACT(HOUR FROM request_datetime) IN (7, 10)
    GROUP BY 1, 2
),

paired AS (
    SELECT
        request_date,

        MAX(valid_wait_rows)
            FILTER (WHERE request_hour = 7) AS valid_rows_7am,

        MAX(valid_wait_rows)
            FILTER (WHERE request_hour = 10) AS valid_rows_10am,

        MAX(long_wait_pct)
            FILTER (WHERE request_hour = 7) AS long_wait_pct_7am,

        MAX(long_wait_pct)
            FILTER (WHERE request_hour = 10) AS long_wait_pct_10am,

        MAX(median_wait_min)
            FILTER (WHERE request_hour = 7) AS median_wait_7am,

        MAX(median_wait_min)
            FILTER (WHERE request_hour = 10) AS median_wait_10am

    FROM hourly
    GROUP BY request_date
)

SELECT
    *,
    ROUND(long_wait_pct_7am - long_wait_pct_10am, 3)
        AS long_wait_gap_pp,
    ROUND(median_wait_7am - median_wait_10am, 3)
        AS median_wait_gap_min
FROM paired
WHERE valid_rows_7am IS NOT NULL
  AND valid_rows_10am IS NOT NULL
ORDER BY request_date;


-- name: stage3_hotspot_second_half_persistence
WITH original_hotspots AS (
    SELECT DISTINCT
        PULocationID,
        daypart,
        day_type
    FROM zdd_hotspots
    WHERE hotspot_robust_flag = TRUE
),

second_half AS (
    SELECT
        PULocationID,

        CASE
            WHEN EXTRACT(HOUR FROM request_datetime) BETWEEN 0 AND 5
                THEN '1_overnight_0-5'
            WHEN EXTRACT(HOUR FROM request_datetime) BETWEEN 6 AND 9
                THEN '2_morning_6-9'
            WHEN EXTRACT(HOUR FROM request_datetime) BETWEEN 10 AND 15
                THEN '3_midday_10-15'
            WHEN EXTRACT(HOUR FROM request_datetime) BETWEEN 16 AND 19
                THEN '4_evening_peak_16-19'
            ELSE '5_late_evening_20-23'
        END AS daypart,

        CASE
            WHEN EXTRACT(ISODOW FROM request_datetime) BETWEEN 1 AND 5
                THEN 'Mon-Fri'
            ELSE 'Sat-Sun'
        END AS day_type,

        COUNT(*) AS n_scoped,

        COUNT(*) FILTER (
            WHERE is_wait_valid
        ) AS n_valid,

        COUNT(*) FILTER (
            WHERE is_wait_valid AND wait_minutes >= 10
        ) AS n_wait_ge10

    FROM trips_clean
    WHERE request_datetime >= TIMESTAMP '2025-01-16 00:00:00'
      AND request_datetime <  TIMESTAMP '2025-02-01 00:00:00'
      AND PULocationID IS NOT NULL
      AND in_geo_wait_tables = TRUE

    GROUP BY 1, 2, 3
),

slot_baseline AS (
    SELECT
        daypart,
        day_type,
        SUM(n_valid) AS slot_valid,
        SUM(n_wait_ge10) AS slot_long_waits
    FROM second_half
    GROUP BY 1, 2
),

cell_rates AS (
    SELECT
        c.*,
        s.slot_valid,
        s.slot_long_waits,

        c.n_wait_ge10 * 1.0
            / NULLIF(c.n_valid, 0) AS cell_long_wait_rate,

        s.slot_long_waits * 1.0
            / NULLIF(s.slot_valid, 0) AS slot_long_wait_rate

    FROM second_half c
    JOIN slot_baseline s
      USING (daypart, day_type)
),

selected AS (
    SELECT
        h.PULocationID,
        h.daypart,
        h.day_type,

        c.n_scoped,
        c.n_valid,
        c.n_wait_ge10,
        c.cell_long_wait_rate,
        c.slot_long_wait_rate

    FROM original_hotspots h
    LEFT JOIN cell_rates c
      USING (PULocationID, daypart, day_type)
),

hotspot_summary AS (
    SELECT
        COUNT(*) AS original_hotspot_cells,

        COUNT(*) FILTER (
            WHERE n_valid > 0
        ) AS cells_with_valid_waits,

        COUNT(*) FILTER (
            WHERE n_valid > 0
              AND cell_long_wait_rate >= 2 * slot_long_wait_rate
        ) AS cells_still_at_least_2x_slot_rate,

        COALESCE(SUM(n_scoped), 0) AS hotspot_scoped_rows,
        COALESCE(SUM(n_valid), 0) AS hotspot_valid_waits,
        COALESCE(SUM(n_wait_ge10), 0) AS hotspot_long_waits

    FROM selected
),

overall AS (
    SELECT
        SUM(n_scoped) AS total_scoped_rows,
        SUM(n_valid) AS total_valid_waits,
        SUM(n_wait_ge10) AS total_long_waits
    FROM second_half
)

SELECT
    h.original_hotspot_cells,
    h.cells_with_valid_waits,
    h.cells_still_at_least_2x_slot_rate,

    ROUND(
        100.0 * h.cells_still_at_least_2x_slot_rate
        / NULLIF(h.cells_with_valid_waits, 0),
        2
    ) AS pct_observed_cells_still_2x,

    h.hotspot_valid_waits,
    h.hotspot_long_waits,

    ROUND(
        100.0 * h.hotspot_valid_waits
        / NULLIF(o.total_valid_waits, 0),
        2
    ) AS pct_valid_trips_in_original_hotspots,

    ROUND(
        100.0 * h.hotspot_long_waits
        / NULLIF(o.total_long_waits, 0),
        2
    ) AS pct_long_waits_in_original_hotspots,

    ROUND(
        100.0 * h.hotspot_long_waits
        / NULLIF(h.hotspot_valid_waits, 0),
        2
    ) AS hotspot_long_wait_rate_pct,

    ROUND(
        100.0 * o.total_long_waits
        / NULLIF(o.total_valid_waits, 0),
        2
    ) AS overall_long_wait_rate_pct

FROM hotspot_summary h
CROSS JOIN overall o;