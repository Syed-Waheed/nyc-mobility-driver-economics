-- Stage 0 probes. Purpose: decide SCOPE (D8) and confirm what on_scene_datetime can be used for (D2).
-- These queries only READ. Nothing is cleaned or removed here.

-- name: ts_ranges
-- Min/max of every timestamp, plus how many rows have pickup BEFORE request.
SELECT
    MIN(request_datetime)   AS min_request,
    MAX(request_datetime)   AS max_request,
    MIN(on_scene_datetime)  AS min_on_scene,
    MAX(on_scene_datetime)  AS max_on_scene,
    MIN(pickup_datetime)    AS min_pickup,
    MAX(pickup_datetime)    AS max_pickup,
    MIN(dropoff_datetime)   AS min_dropoff,
    MAX(dropoff_datetime)   AS max_dropoff,
    COUNT(*) FILTER (WHERE pickup_datetime < request_datetime) AS n_pickup_before_request
FROM trips_raw;

-- name: month_crosstab
-- Which calendar month does each timestamp fall in? Reveals what rule the "January" file uses.
SELECT
    date_trunc('month', request_datetime) AS request_month,
    date_trunc('month', pickup_datetime)  AS pickup_month,
    date_trunc('month', dropoff_datetime) AS dropoff_month,
    COUNT(*)                              AS n_rows
FROM trips_raw
GROUP BY ALL
ORDER BY n_rows DESC;

-- name: onscene_by_company
-- Is on_scene_datetime populated evenly, or mostly for one company?
SELECT
    hvfhs_license_num,
    COUNT(*)                                                    AS n_rows,
    COUNT(on_scene_datetime)                                    AS n_with_on_scene,
    ROUND(100.0 * COUNT(on_scene_datetime) / COUNT(*), 2)       AS pct_with_on_scene
FROM trips_raw
GROUP BY hvfhs_license_num
ORDER BY n_rows DESC;

-- name: onscene_by_wav
-- Is on_scene_datetime populated only for wheelchair-accessible trips (as the dictionary wording suggests)?
SELECT
    wav_match_flag,
    COUNT(*)                                                    AS n_rows,
    COUNT(on_scene_datetime)                                    AS n_with_on_scene,
    ROUND(100.0 * COUNT(on_scene_datetime) / COUNT(*), 2)       AS pct_with_on_scene
FROM trips_raw
GROUP BY wav_match_flag
ORDER BY wav_match_flag;
