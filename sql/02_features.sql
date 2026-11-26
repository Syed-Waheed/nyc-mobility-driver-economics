-- Stage 2 features: trips_features = trips_clean v2 + time-of-request features + pickup zone labels.
-- NO ROWS ARE ADDED OR REMOVED. The zone lookup has unique LocationID values (verified in Stage 1D) and the
-- pickup join was lossless, so a LEFT JOIN keeps 20,405,666 rows. Scope stays pickup in January 2025 (D8).
-- "When" uses REQUEST time (D6): request_hour and request_isodow. "Where" uses the PICKUP zone (D5).
-- Eligibility columns from trips_clean (is_wait_valid, in_geo_wait_tables, in_pay_per_mile, in_pay_per_minute)
-- carry the decided rules (D11, D14, D15): Stage 2 queries filter on those, never on ad hoc conditions.
-- Convention: blocks named create_* are DDL and run once at notebook start.

-- name: create_trips_features
CREATE OR REPLACE VIEW trips_features AS
SELECT
    c.*,
    CASE c.hvfhs_license_num WHEN 'HV0003' THEN 'Uber' WHEN 'HV0005' THEN 'Lyft' END AS company,
    hour(c.request_datetime)                 AS request_hour,       -- 0 to 23
    isodow(c.request_datetime)               AS request_isodow,     -- 1 = Monday ... 7 = Sunday
    dayname(c.request_datetime)              AS request_dow_name,
    CAST(c.request_datetime AS DATE)         AS request_date,
    z.Zone                                   AS pu_zone,
    z.Borough                                AS pu_borough,
    z.service_zone                           AS pu_service_zone
FROM trips_clean c
LEFT JOIN zones z ON z.LocationID = c.PULocationID;

-- name: features_reconcile
-- Expected: n_rows 20,405,666; both null counts 0; hours 0 to 23; ISO weekdays 1 to 7; 262 distinct pickup zones;
-- request dates 2024-12-31 to 2025-02-01 (requests made just outside the pickup-date scope, see D8).
SELECT
    COUNT(*)                                  AS n_rows,
    COUNT(*) FILTER (WHERE pu_zone IS NULL)    AS pu_zone_null,
    COUNT(*) FILTER (WHERE pu_borough IS NULL) AS pu_borough_null,
    MIN(request_hour)                         AS min_hour,
    MAX(request_hour)                         AS max_hour,
    MIN(request_isodow)                       AS min_isodow,
    MAX(request_isodow)                       AS max_isodow,
    COUNT(DISTINCT PULocationID)              AS n_pickup_zones,
    MIN(request_date)                         AS min_request_date,
    MAX(request_date)                         AS max_request_date
FROM trips_features;