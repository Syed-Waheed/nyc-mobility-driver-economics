-- name: create_stage4_model_sample
CREATE OR REPLACE TABLE stage4_model_sample AS
SELECT
    CASE
        WHEN request_datetime < TIMESTAMP '2025-01-22 00:00:00'
            THEN 'train'
        WHEN request_datetime < TIMESTAMP '2025-01-25 00:00:00'
            THEN 'validation'
        ELSE 'test'
    END AS split,

    CAST(request_datetime AS DATE) AS request_date,

    EXTRACT(HOUR FROM request_datetime)::INTEGER AS request_hour,
    EXTRACT(ISODOW FROM request_datetime)::INTEGER AS request_dow,

    CAST(PULocationID AS VARCHAR) AS pickup_zone,

    CASE
        WHEN hvfhs_license_num = 'HV0003' THEN 'Uber'
        WHEN hvfhs_license_num = 'HV0005' THEN 'Lyft'
    END AS company,

    COALESCE(NULLIF(shared_request_flag, ''), 'Unknown')
        AS shared_requested,

    COALESCE(NULLIF(wav_request_flag, ''), 'Unknown')
        AS wav_requested,

    CASE
        WHEN wait_minutes >= 10 THEN 1
        ELSE 0
    END AS target_long_wait

FROM trips_clean
WHERE request_datetime >= TIMESTAMP '2025-01-01 00:00:00'
  AND request_datetime <  TIMESTAMP '2025-02-01 00:00:00'
  AND hvfhs_license_num IN ('HV0003', 'HV0005')
  AND PULocationID IS NOT NULL
  AND is_wait_valid = TRUE
  AND in_geo_wait_tables = TRUE

  -- Deterministic ~1% sample; sampling doesn't use the target.
  AND hash(
      CAST(request_datetime AS VARCHAR) || '|' ||
      CAST(PULocationID AS VARCHAR) || '|' ||
      CAST(DOLocationID AS VARCHAR) || '|' ||
      hvfhs_license_num || '|' ||
      COALESCE(dispatching_base_num, '')
  ) % 100 = 0;