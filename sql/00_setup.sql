-- Stage 0: raw-data views.
-- Views store NO data; they only point at the files, so the raw Parquet is never modified.
-- Paths are relative to the project root (the notebook helper does os.chdir(ROOT)).
--
-- Grain of trips_raw : one row = one HVFHV trip record (no rider_id / driver_id exists).
-- Grain of zones     : one row = one TLC taxi zone (LocationID).

-- name: create_trips_raw
CREATE OR REPLACE VIEW trips_raw AS
SELECT * FROM read_parquet('data/fhvhv_tripdata_2025-01.parquet');

-- name: create_zones
CREATE OR REPLACE VIEW zones AS
SELECT * FROM read_csv_auto('data/taxi_zone_lookup.csv');
