-- Stage 2E: like-for-like Uber vs Lyft wait comparison. Reads trips_features once (create_ce_bins); everything else is small tables.
-- Population: five-borough pickups, valid waits (D11, D14, D15) = F3. Strata = Design C: pickup zone x daypart x day type
-- (dayparts: 1_overnight_0-5 | 2_morning_6-9 | 3_midday_10-15 | 4_evening_peak_16-19 | 5_late_evening_20-23; day type Mon-Fri | Sat-Sun).
-- Wait metric (D2): request-to-pickup minutes. Long wait = valid wait >= 10 minutes.
--
-- ESTIMAND. "What would each company's wait distribution be if it served the same mix of pickup zones, dayparts and day types?"
-- METHOD = direct standardization. Inside each stratum s each company has its own wait distribution F_{c,s}. For a chosen set of
-- strata and weights w_s (summing to 1) the standardized distribution of company c is F_c = sum_s w_s * F_{c,s}. Quantiles and the
-- share of waits >= 10 minutes are read from F_c. Both companies get the SAME w_s, so differences in where and when each company
-- operates cannot create the difference. (Comparing pooled medians instead mixes "how fast" with "where and when": a company with more
-- peak-hour or outer-borough pickups looks slower even if it is equally fast inside every zone-daypart.)
-- Implementation: waits are binned in 10-second bins (bin = floor(wait_seconds / 10), capped at 360 = 60+ min; bin -1 = excluded negative
-- wait). Within a bin the quantile is linearly interpolated. ce_binned_method_check compares the binned pooled quantiles with Stage 2A.
--
-- PRE-SET RULES (written before any result was seen):
--   Common support: a stratum is usable at level T if BOTH companies have at least T valid waits in it (min_n per company per stratum).
--   Ladder T = 1000, 500, 300, 200, 100. The 1,000 bar of Stage 2D was chosen to RANK individual cells; here the quantity of interest is a
--   standardized summary averaged over many strata, where a smaller stratum adds noise but not bias, so a lower T is defensible if the
--   coverage cost of 1,000 is high. PRIMARY T = the largest ladder value at which (i) each company keeps >= 90% of its valid waits overall
--   and (ii) each company keeps >= 50% of its valid waits in every borough. The threshold used is reported, never silent.
--   Primary weights: 'pooled' (w_s proportional to Uber + Lyft valid waits in the stratum = the combined market mix).
--   Alternative weights (robustness): 'uber_mix', 'lyft_mix', 'equal'.
--   Groups: ALL strata with support; EX_AIRPORTS (zones whose name contains "Airport" removed); AIRPORTS (only those zones);
--   BOROUGH:<name> (standardized within one borough). Non-ALL groups use pooled weights only.
-- LIMITS: standardizing removes differences in zone-daypart-day-type mix only. It does NOT adjust for hour within daypart, trip length,
-- destination, product type, shared rides (Uber only), WAV, or company-specific meaning of request_datetime (D10; Lyft has no on_scene).
-- Sampling error is small with millions of trips but is NOT the main uncertainty: trips in one place and time are correlated, one month
-- is observed, only completed trips exist, and 1.56% of Lyft vs 0.79% of Uber waits are excluded. Stage 3 handles intervals (block bootstrap).

-- name: create_ce_bins
-- One pass over the 20M rows. Rows: (stratum, company, bin) with counts; about 0.6M rows.
CREATE OR REPLACE TABLE ce_bins AS
WITH t AS (
    SELECT
        PULocationID, pu_borough, pu_zone, company,
        CASE WHEN request_hour < 6  THEN '1_overnight_0-5'
             WHEN request_hour < 10 THEN '2_morning_6-9'
             WHEN request_hour < 16 THEN '3_midday_10-15'
             WHEN request_hour < 20 THEN '4_evening_peak_16-19'
             ELSE                        '5_late_evening_20-23' END AS daypart,
        CASE WHEN request_isodow <= 5 THEN 'Mon-Fri' ELSE 'Sat-Sun' END AS day_type,
        CASE WHEN NOT in_geo_wait_tables THEN -1
             ELSE LEAST(CAST(FLOOR(wait_seconds / 10.0) AS INTEGER), 360) END AS bin
    FROM trips_features
    WHERE NOT flag_pickup_outside_nyc
)
SELECT PULocationID, pu_borough, pu_zone, daypart, day_type, company, bin, COUNT(*) AS cnt
FROM t
GROUP BY PULocationID, pu_borough, pu_zone, daypart, day_type, company, bin;

-- name: create_ce_strata
-- One row per stratum with both companies side by side. _u = Uber, _l = Lyft. n_ge10 counts valid waits >= 600 s (bin >= 60).
CREATE OR REPLACE TABLE ce_strata AS
SELECT
    PULocationID, pu_borough, pu_zone, daypart, day_type,
    COALESCE(SUM(cnt) FILTER (WHERE company = 'Uber'), 0)                    AS n_scoped_u,
    COALESCE(SUM(cnt) FILTER (WHERE company = 'Uber' AND bin >= 0), 0)       AS n_valid_u,
    COALESCE(SUM(cnt) FILTER (WHERE company = 'Uber' AND bin = -1), 0)       AS n_excl_u,
    COALESCE(SUM(cnt) FILTER (WHERE company = 'Uber' AND bin >= 60), 0)      AS n_ge10_u,
    COALESCE(SUM(cnt) FILTER (WHERE company = 'Lyft'), 0)                    AS n_scoped_l,
    COALESCE(SUM(cnt) FILTER (WHERE company = 'Lyft' AND bin >= 0), 0)       AS n_valid_l,
    COALESCE(SUM(cnt) FILTER (WHERE company = 'Lyft' AND bin = -1), 0)       AS n_excl_l,
    COALESCE(SUM(cnt) FILTER (WHERE company = 'Lyft' AND bin >= 60), 0)      AS n_ge10_l
FROM ce_bins
GROUP BY 1, 2, 3, 4, 5;

-- name: create_ce_weights
-- Weights per (min_n, group, scheme), normalised to sum to 1 inside each combination. Only strata with common support at min_n appear.
CREATE OR REPLACE TABLE ce_weights AS
WITH th AS (
    SELECT * FROM (VALUES (1000), (500), (300), (200), (100)) AS t(min_n)
),
e AS (
    SELECT th.min_n, s.PULocationID, s.pu_borough, s.pu_zone, s.daypart, s.day_type, s.n_valid_u, s.n_valid_l,
           (s.pu_zone ILIKE '%airport%') AS is_airport
    FROM th
    JOIN ce_strata s ON LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n
),
g AS (
    SELECT 'ALL' AS grp, * FROM e
    UNION ALL SELECT 'EX_AIRPORTS', * FROM e WHERE NOT is_airport
    UNION ALL SELECT 'AIRPORTS',    * FROM e WHERE is_airport
    UNION ALL SELECT 'BOROUGH:' || pu_borough, * FROM e
),
w AS (
    SELECT min_n, grp, 'pooled' AS scheme, PULocationID, daypart, day_type, (n_valid_u + n_valid_l) * 1.0 AS raw FROM g
    UNION ALL
    SELECT min_n, grp, 'uber_mix', PULocationID, daypart, day_type, n_valid_u * 1.0 FROM g WHERE grp = 'ALL'
    UNION ALL
    SELECT min_n, grp, 'lyft_mix', PULocationID, daypart, day_type, n_valid_l * 1.0 FROM g WHERE grp = 'ALL'
    UNION ALL
    SELECT min_n, grp, 'equal', PULocationID, daypart, day_type, 1.0 FROM g WHERE grp = 'ALL'
)
SELECT min_n, grp, scheme, PULocationID, daypart, day_type,
       raw / SUM(raw) OVER (PARTITION BY min_n, grp, scheme) AS w
FROM w;

-- name: create_ce_std_pdf
-- Standardized distribution per (min_n, group, scheme, company): pdf of each bin = sum over strata of w_s * (stratum bin share).
-- Heavier step (about 30-40 million joined rows, grouped to a small table).
CREATE OR REPLACE TABLE ce_std_pdf AS
SELECT
    w.min_n, w.grp, w.scheme, b.company, b.bin,
    SUM(w.w * b.cnt / CASE b.company WHEN 'Uber' THEN s.n_valid_u ELSE s.n_valid_l END) AS pdf
FROM ce_bins b
JOIN ce_strata  s ON s.PULocationID = b.PULocationID AND s.daypart = b.daypart AND s.day_type = b.day_type
JOIN ce_weights w ON w.PULocationID = b.PULocationID AND w.daypart = b.daypart AND w.day_type = b.day_type
WHERE b.bin >= 0
GROUP BY w.min_n, w.grp, w.scheme, b.company, b.bin;

-- name: create_ce_stratum_stats
-- Within-stratum quantiles per company (from the same bins, interpolated). Used for the stratum-level comparison.
CREATE OR REPLACE TABLE ce_stratum_stats AS
WITH v AS (SELECT * FROM ce_bins WHERE bin >= 0),
c AS (
    SELECT PULocationID, daypart, day_type, company, bin, cnt,
           SUM(cnt) OVER (PARTITION BY PULocationID, daypart, day_type, company ORDER BY bin) AS cum,
           SUM(cnt) OVER (PARTITION BY PULocationID, daypart, day_type, company)              AS tot
    FROM v
),
q AS (
    SELECT * FROM (VALUES ('p50', CAST(0.50 AS DOUBLE)), ('p75', CAST(0.75 AS DOUBLE)),
                          ('p90', CAST(0.90 AS DOUBLE)), ('p95', CAST(0.95 AS DOUBLE))) AS t(lbl, q)
),
r AS (
    SELECT c.PULocationID, c.daypart, c.day_type, c.company, q.lbl,
           (c.bin + (q.q * c.tot - (c.cum - c.cnt)) / c.cnt) * 10.0 / 60.0 AS minutes
    FROM c CROSS JOIN q
    WHERE (c.cum - c.cnt) < q.q * c.tot AND c.cum >= q.q * c.tot
)
SELECT
    PULocationID, daypart, day_type,
    MAX(minutes) FILTER (WHERE company = 'Uber' AND lbl = 'p50') AS uber_p50,
    MAX(minutes) FILTER (WHERE company = 'Lyft' AND lbl = 'p50') AS lyft_p50,
    MAX(minutes) FILTER (WHERE company = 'Uber' AND lbl = 'p75') AS uber_p75,
    MAX(minutes) FILTER (WHERE company = 'Lyft' AND lbl = 'p75') AS lyft_p75,
    MAX(minutes) FILTER (WHERE company = 'Uber' AND lbl = 'p90') AS uber_p90,
    MAX(minutes) FILTER (WHERE company = 'Lyft' AND lbl = 'p90') AS lyft_p90,
    MAX(minutes) FILTER (WHERE company = 'Uber' AND lbl = 'p95') AS uber_p95,
    MAX(minutes) FILTER (WHERE company = 'Lyft' AND lbl = 'p95') AS lyft_p95
FROM r
GROUP BY PULocationID, daypart, day_type;

-- name: ce_reconcile
-- Expected: Uber 15,355,926 scoped / 15,234,971 valid / 120,955 excluded; Lyft 5,048,966 / 4,970,147 / 78,819;
-- All 20,404,892 / 20,205,118 / 199,774 (five-borough population; the 774 outside-NYC pickups are in no stratum).
SELECT 'Uber' AS company, SUM(n_scoped_u) AS n_scoped, SUM(n_valid_u) AS n_valid, SUM(n_excl_u) AS n_excluded, SUM(n_ge10_u) AS n_wait_ge10 FROM ce_strata
UNION ALL
SELECT 'Lyft', SUM(n_scoped_l), SUM(n_valid_l), SUM(n_excl_l), SUM(n_ge10_l) FROM ce_strata
UNION ALL
SELECT 'All', SUM(n_scoped_u + n_scoped_l), SUM(n_valid_u + n_valid_l), SUM(n_excl_u + n_excl_l), SUM(n_ge10_u + n_ge10_l) FROM ce_strata;

-- name: ce_design_c_crosscheck
-- Must agree with Stage 2D Design C: 2,579 observed strata, 2,177 adequate (pooled n_valid >= 1,000) covering 99.18% of valid waits.
SELECT
    COUNT(*)                                                                             AS n_strata_observed,
    COUNT(*) FILTER (WHERE n_valid_u + n_valid_l > 0)                                    AS n_strata_with_valid,
    COUNT(*) FILTER (WHERE n_valid_u + n_valid_l >= 1000)                                AS n_pooled_adequate,
    ROUND(100.0 * SUM(n_valid_u + n_valid_l) FILTER (WHERE n_valid_u + n_valid_l >= 1000)
          / SUM(n_valid_u + n_valid_l), 2)                                               AS pct_valid_in_pooled_adequate,
    COUNT(*) FILTER (WHERE n_valid_u = 0 OR n_valid_l = 0)                               AS n_strata_missing_a_company
FROM ce_strata;

-- name: ce_binned_method_check
-- Pooled (own-mix) quantiles per company from the 10-second bins, to compare with Stage 2A (Uber 3.800 / 5.517 / 8.033 / 10.217 / 15.783;
-- Lyft 4.083 / 5.767 / 8.033 / 9.867 / 14.533; share >= 10 min about 5.35% and 4.76%). Expect agreement within about 0.05 minute
-- (10-second bins, five-borough population only).
WITH p AS (
    SELECT company, bin, SUM(cnt) AS cnt FROM ce_bins WHERE bin >= 0 GROUP BY 1, 2
),
c AS (
    SELECT company, bin, cnt,
           SUM(cnt) OVER (PARTITION BY company ORDER BY bin) AS cum,
           SUM(cnt) OVER (PARTITION BY company)              AS tot
    FROM p
),
q AS (
    SELECT * FROM (VALUES ('p50', CAST(0.50 AS DOUBLE)), ('p75', CAST(0.75 AS DOUBLE)), ('p90', CAST(0.90 AS DOUBLE)),
                          ('p95', CAST(0.95 AS DOUBLE)), ('p99', CAST(0.99 AS DOUBLE))) AS t(lbl, q)
),
r AS (
    SELECT c.company, q.lbl, (c.bin + (q.q * c.tot - (c.cum - c.cnt)) / c.cnt) * 10.0 / 60.0 AS minutes
    FROM c CROSS JOIN q
    WHERE (c.cum - c.cnt) < q.q * c.tot AND c.cum >= q.q * c.tot
),
s AS (
    SELECT company, 100.0 * SUM(cnt) FILTER (WHERE bin >= 60) / SUM(cnt) AS share_ge10_pct, SUM(cnt) AS n_valid
    FROM p GROUP BY company
)
SELECT
    s.company,
    s.n_valid,
    ROUND(MAX(r.minutes) FILTER (WHERE r.lbl = 'p50'), 3) AS p50,
    ROUND(MAX(r.minutes) FILTER (WHERE r.lbl = 'p75'), 3) AS p75,
    ROUND(MAX(r.minutes) FILTER (WHERE r.lbl = 'p90'), 3) AS p90,
    ROUND(MAX(r.minutes) FILTER (WHERE r.lbl = 'p95'), 3) AS p95,
    ROUND(MAX(r.minutes) FILTER (WHERE r.lbl = 'p99'), 3) AS p99,
    ROUND(s.share_ge10_pct, 3)                            AS share_ge10_pct
FROM s JOIN r ON r.company = s.company
GROUP BY s.company, s.n_valid, s.share_ge10_pct
ORDER BY s.company DESC;

-- name: ce_weights_check
-- Every (min_n, group, scheme) combination must have weights summing to 1.
WITH s AS (
    SELECT min_n, grp, scheme, COUNT(*) AS n_strata, SUM(w) AS weight_sum FROM ce_weights GROUP BY min_n, grp, scheme
)
SELECT COUNT(*) AS n_combos, MIN(weight_sum) AS min_weight_sum, MAX(weight_sum) AS max_weight_sum, MIN(n_strata) AS min_strata_in_a_combo
FROM s;

-- name: ce_pdf_check
-- Every standardized distribution must sum to 1.
WITH s AS (
    SELECT min_n, grp, scheme, company, SUM(pdf) AS pdf_sum FROM ce_std_pdf GROUP BY min_n, grp, scheme, company
)
SELECT COUNT(*) AS n_combo_company, MIN(pdf_sum) AS min_pdf_sum, MAX(pdf_sum) AS max_pdf_sum FROM s;

-- name: ce_identity_check
-- Identity test of the weighting code: with Uber's own mix, Uber's standardized share of long waits must equal Uber's plain share
-- inside the same strata (same for Lyft with Lyft's mix). abs_diff should be about 0 (floating-point noise only).
WITH e AS (
    SELECT DISTINCT min_n, PULocationID, daypart, day_type FROM ce_weights WHERE grp = 'ALL' AND scheme = 'pooled'
),
d AS (
    SELECT e.min_n, b.company,
           SUM(b.cnt) FILTER (WHERE b.bin >= 60) * 1.0 / SUM(b.cnt) FILTER (WHERE b.bin >= 0) AS direct_share
    FROM e
    JOIN ce_bins b ON b.PULocationID = e.PULocationID AND b.daypart = e.daypart AND b.day_type = e.day_type
    GROUP BY e.min_n, b.company
),
s AS (
    SELECT min_n, company, scheme, SUM(pdf) FILTER (WHERE bin >= 60) AS std_share
    FROM ce_std_pdf WHERE grp = 'ALL'
    GROUP BY min_n, company, scheme
)
SELECT d.min_n, d.company, d.direct_share, s.std_share, ABS(d.direct_share - s.std_share) AS abs_diff
FROM d
JOIN s ON s.min_n = d.min_n AND s.company = d.company
WHERE (d.company = 'Uber' AND s.scheme = 'uber_mix') OR (d.company = 'Lyft' AND s.scheme = 'lyft_mix')
ORDER BY d.min_n DESC, d.company;

-- name: ce_support_curve
-- COMMON SUPPORT: for each min_n, how many strata qualify and what share of EACH company's valid waits they represent.
-- total = all valid waits in the five-borough population; in_support = valid waits in strata where both companies have >= min_n.
WITH th AS (
    SELECT * FROM (VALUES (1000), (500), (300), (200), (100)) AS t(min_n)
)
SELECT
    th.min_n,
    COUNT(*) FILTER (WHERE s.n_valid_u + s.n_valid_l > 0)                                        AS n_strata_with_valid,
    COUNT(*) FILTER (WHERE LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n)                          AS n_strata_common_support,
    SUM(s.n_valid_u)                                                                              AS uber_valid_total,
    COALESCE(SUM(s.n_valid_u) FILTER (WHERE LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n), 0)     AS uber_valid_in_support,
    ROUND(100.0 * COALESCE(SUM(s.n_valid_u) FILTER (WHERE LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n), 0)
          / SUM(s.n_valid_u), 2)                                                                  AS uber_pct_in_support,
    SUM(s.n_valid_l)                                                                              AS lyft_valid_total,
    COALESCE(SUM(s.n_valid_l) FILTER (WHERE LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n), 0)     AS lyft_valid_in_support,
    ROUND(100.0 * COALESCE(SUM(s.n_valid_l) FILTER (WHERE LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n), 0)
          / SUM(s.n_valid_l), 2)                                                                  AS lyft_pct_in_support
FROM ce_strata s
CROSS JOIN th
GROUP BY th.min_n
ORDER BY th.min_n DESC;

-- name: ce_support_by_borough
-- Same coverage by borough (long format): share of each company's valid waits IN that borough that sit in supported strata.
WITH th AS (
    SELECT * FROM (VALUES (1000), (500), (300), (200), (100)) AS t(min_n)
)
SELECT
    th.min_n,
    s.pu_borough,
    COUNT(*)                                                                                      AS n_strata,
    COUNT(*) FILTER (WHERE LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n)                          AS n_strata_common_support,
    SUM(s.n_valid_u)                                                                              AS uber_valid_total,
    SUM(s.n_valid_l)                                                                              AS lyft_valid_total,
    ROUND(100.0 * COALESCE(SUM(s.n_valid_u) FILTER (WHERE LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n), 0)
          / SUM(s.n_valid_u), 2)                                                                  AS uber_pct_in_support,
    ROUND(100.0 * COALESCE(SUM(s.n_valid_l) FILTER (WHERE LEAST(s.n_valid_u, s.n_valid_l) >= th.min_n), 0)
          / SUM(s.n_valid_l), 2)                                                                  AS lyft_pct_in_support
FROM ce_strata s
CROSS JOIN th
GROUP BY th.min_n, s.pu_borough
ORDER BY th.min_n DESC, s.pu_borough;

-- name: ce_standardized_support
-- Coverage and influence for each (min_n, group) with pooled weights: strata, share of each company's valid waits in the group,
-- the largest single stratum weight, and the total weight carried by airport zones (influence check).
WITH tot AS (
    SELECT 'ALL' AS grp, SUM(n_valid_u) AS u_tot, SUM(n_valid_l) AS l_tot FROM ce_strata
    UNION ALL SELECT 'EX_AIRPORTS', SUM(n_valid_u), SUM(n_valid_l) FROM ce_strata WHERE pu_zone NOT ILIKE '%airport%'
    UNION ALL SELECT 'AIRPORTS',    SUM(n_valid_u), SUM(n_valid_l) FROM ce_strata WHERE pu_zone ILIKE '%airport%'
    UNION ALL SELECT 'BOROUGH:' || pu_borough, SUM(n_valid_u), SUM(n_valid_l) FROM ce_strata GROUP BY pu_borough
),
sup AS (
    SELECT
        w.min_n, w.grp,
        COUNT(*)                                                         AS n_strata,
        SUM(s.n_valid_u)                                                 AS u_in,
        SUM(s.n_valid_l)                                                 AS l_in,
        MAX(w.w)                                                         AS max_w,
        COALESCE(SUM(w.w) FILTER (WHERE s.pu_zone ILIKE '%airport%'), 0) AS airport_w
    FROM ce_weights w
    JOIN ce_strata s ON s.PULocationID = w.PULocationID AND s.daypart = w.daypart AND s.day_type = w.day_type
    WHERE w.scheme = 'pooled'
    GROUP BY w.min_n, w.grp
)
SELECT
    sup.min_n, sup.grp, sup.n_strata,
    sup.u_in                                         AS uber_valid_in_support,
    ROUND(100.0 * sup.u_in / tot.u_tot, 2)           AS uber_pct_of_group,
    sup.l_in                                         AS lyft_valid_in_support,
    ROUND(100.0 * sup.l_in / tot.l_tot, 2)           AS lyft_pct_of_group,
    ROUND(100.0 * sup.max_w, 2)                      AS max_stratum_weight_pct,
    ROUND(100.0 * sup.airport_w, 2)                  AS airport_weight_pct
FROM sup
JOIN tot ON tot.grp = sup.grp
ORDER BY sup.grp, sup.min_n DESC;

-- name: ce_standardized_summary
-- THE MAIN RESULT TABLE. One row per (min_n, group, scheme): standardized p50, p75, p90, p95, p99 (minutes) and share of waits >= 10 min (%)
-- for each company, and Lyft minus Uber (seconds for quantiles, percentage points for the share). Descriptive; no intervals here (Stage 3).
WITH c AS (
    SELECT min_n, grp, scheme, company, bin, pdf,
           SUM(pdf) OVER (PARTITION BY min_n, grp, scheme, company ORDER BY bin) AS cum
    FROM ce_std_pdf
),
q AS (
    SELECT * FROM (VALUES ('p50', CAST(0.50 AS DOUBLE)), ('p75', CAST(0.75 AS DOUBLE)), ('p90', CAST(0.90 AS DOUBLE)),
                          ('p95', CAST(0.95 AS DOUBLE)), ('p99', CAST(0.99 AS DOUBLE))) AS t(lbl, q)
),
qs AS (
    SELECT c.min_n, c.grp, c.scheme, c.company, q.lbl,
           (c.bin + (q.q - (c.cum - c.pdf)) / c.pdf) * 10.0 / 60.0 AS v
    FROM c CROSS JOIN q
    WHERE (c.cum - c.pdf) < q.q AND c.cum >= q.q
),
sh AS (
    SELECT min_n, grp, scheme, company, 'share_ge10' AS lbl, 100.0 * SUM(pdf) FILTER (WHERE bin >= 60) AS v
    FROM ce_std_pdf
    GROUP BY min_n, grp, scheme, company
),
l AS (
    SELECT * FROM qs
    UNION ALL
    SELECT * FROM sh
)
SELECT
    min_n, grp, scheme,
    ROUND(MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p50'), 3) AS uber_p50,
    ROUND(MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p50'), 3) AS lyft_p50,
    ROUND((MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p50') - MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p50')) * 60, 1) AS diff_p50_sec,
    ROUND(MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p75'), 3) AS uber_p75,
    ROUND(MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p75'), 3) AS lyft_p75,
    ROUND((MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p75') - MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p75')) * 60, 1) AS diff_p75_sec,
    ROUND(MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p90'), 3) AS uber_p90,
    ROUND(MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p90'), 3) AS lyft_p90,
    ROUND((MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p90') - MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p90')) * 60, 1) AS diff_p90_sec,
    ROUND(MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p95'), 3) AS uber_p95,
    ROUND(MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p95'), 3) AS lyft_p95,
    ROUND((MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p95') - MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p95')) * 60, 1) AS diff_p95_sec,
    ROUND(MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p99'), 3) AS uber_p99,
    ROUND(MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p99'), 3) AS lyft_p99,
    ROUND((MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'p99') - MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'p99')) * 60, 1) AS diff_p99_sec,
    ROUND(MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'share_ge10'), 3) AS uber_share_ge10_pct,
    ROUND(MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'share_ge10'), 3) AS lyft_share_ge10_pct,
    ROUND(MAX(v) FILTER (WHERE company = 'Lyft' AND lbl = 'share_ge10') - MAX(v) FILTER (WHERE company = 'Uber' AND lbl = 'share_ge10'), 3) AS diff_share_pts
FROM l
GROUP BY min_n, grp, scheme
ORDER BY grp, scheme, min_n DESC;

-- name: ce_share_exclusion_bounds
-- Exclusion sensitivity for the share of waits >= 10 min under the primary design (group ALL, pooled weights), per min_n.
-- Exact bounds: if every excluded negative-wait row of a company were SHORT (< 10 min) vs LONG (>= 10 min), the standardized share is
--   low = sum_s w_s * n_ge10 / n_scoped,   high = sum_s w_s * (n_ge10 + n_excluded) / n_scoped.
-- Lyft-minus-Uber difference bounds = (Lyft low - Uber high, Lyft high - Uber low). If the bounds straddle 0 the SIGN of the
-- share difference is not settled by the data alone. These are bounds, not measured waits.
WITH j AS (
    SELECT w.min_n, w.w, s.n_scoped_u, s.n_valid_u, s.n_excl_u, s.n_ge10_u, s.n_scoped_l, s.n_valid_l, s.n_excl_l, s.n_ge10_l
    FROM ce_weights w
    JOIN ce_strata s ON s.PULocationID = w.PULocationID AND s.daypart = w.daypart AND s.day_type = w.day_type
    WHERE w.grp = 'ALL' AND w.scheme = 'pooled'
)
SELECT
    min_n,
    ROUND(100 * SUM(w * n_ge10_u * 1.0 / n_valid_u), 3)                        AS uber_share_valid_pct,
    ROUND(100 * SUM(w * n_ge10_l * 1.0 / n_valid_l), 3)                        AS lyft_share_valid_pct,
    ROUND(100 * (SUM(w * n_ge10_l * 1.0 / n_valid_l) - SUM(w * n_ge10_u * 1.0 / n_valid_u)), 3) AS diff_share_valid_pts,
    ROUND(100 * SUM(w * n_ge10_u * 1.0 / n_scoped_u), 3)                       AS uber_share_if_excluded_short_pct,
    ROUND(100 * SUM(w * (n_ge10_u + n_excl_u) * 1.0 / n_scoped_u), 3)          AS uber_share_if_excluded_long_pct,
    ROUND(100 * SUM(w * n_ge10_l * 1.0 / n_scoped_l), 3)                       AS lyft_share_if_excluded_short_pct,
    ROUND(100 * SUM(w * (n_ge10_l + n_excl_l) * 1.0 / n_scoped_l), 3)          AS lyft_share_if_excluded_long_pct,
    ROUND(100 * (SUM(w * n_ge10_l * 1.0 / n_scoped_l)
               - SUM(w * (n_ge10_u + n_excl_u) * 1.0 / n_scoped_u)), 3)        AS diff_lower_bound_pts,
    ROUND(100 * (SUM(w * (n_ge10_l + n_excl_l) * 1.0 / n_scoped_l)
               - SUM(w * n_ge10_u * 1.0 / n_scoped_u)), 3)                     AS diff_upper_bound_pts
FROM j
GROUP BY min_n
ORDER BY min_n DESC;

-- name: ce_stratum_diff_summary
-- Within-stratum picture: across strata that have common support at each min_n, how often is Lyft's median / p90 / long-wait share
-- higher, and how large are the typical differences? (differences are Lyft minus Uber; seconds, or percentage points for the share)
WITH th AS (
    SELECT * FROM (VALUES (1000), (500), (300), (200), (100)) AS t(min_n)
),
d AS (
    SELECT
        s.PULocationID, s.daypart, s.day_type, s.n_valid_u, s.n_valid_l,
        (s.n_valid_u + s.n_valid_l)                                              AS n_pooled,
        (st.lyft_p50 - st.uber_p50) * 60                                         AS d50_sec,
        (st.lyft_p90 - st.uber_p90) * 60                                         AS d90_sec,
        100.0 * (s.n_ge10_l * 1.0 / s.n_valid_l - s.n_ge10_u * 1.0 / s.n_valid_u) AS dshare_pts
    FROM ce_strata s
    JOIN ce_stratum_stats st ON st.PULocationID = s.PULocationID AND st.daypart = s.daypart AND st.day_type = s.day_type
    WHERE LEAST(s.n_valid_u, s.n_valid_l) > 0
)
SELECT
    th.min_n,
    COUNT(*)                                                                         AS n_strata,
    COUNT(*) FILTER (WHERE d.d50_sec > 0)                                            AS n_lyft_median_higher,
    ROUND(100.0 * SUM(d.n_pooled) FILTER (WHERE d.d50_sec > 0) / SUM(d.n_pooled), 1) AS pct_pooled_weight_lyft_median_higher,
    ROUND(quantile_cont(d.d50_sec, 0.25), 1)                                         AS d50_p25_sec,
    ROUND(quantile_cont(d.d50_sec, 0.50), 1)                                         AS d50_median_sec,
    ROUND(quantile_cont(d.d50_sec, 0.75), 1)                                         AS d50_p75_sec,
    COUNT(*) FILTER (WHERE d.d90_sec > 0)                                            AS n_lyft_p90_higher,
    ROUND(quantile_cont(d.d90_sec, 0.50), 1)                                         AS d90_median_sec,
    COUNT(*) FILTER (WHERE d.dshare_pts > 0)                                         AS n_lyft_share_higher,
    ROUND(quantile_cont(d.dshare_pts, 0.50), 2)                                      AS dshare_median_pts
FROM d
JOIN th ON LEAST(d.n_valid_u, d.n_valid_l) >= th.min_n
GROUP BY th.min_n
ORDER BY th.min_n DESC;

-- name: ce_stratum_extremes
-- The 10 supported strata (both companies >= 1,000) where Lyft's median is longest relative to Uber, and the 10 where it is shortest.
WITH d AS (
    SELECT
        s.pu_borough, s.pu_zone, s.daypart, s.day_type, s.n_valid_u, s.n_valid_l,
        ROUND(st.uber_p50, 3) AS uber_p50, ROUND(st.lyft_p50, 3) AS lyft_p50,
        ROUND((st.lyft_p50 - st.uber_p50) * 60, 1) AS d50_sec,
        ROUND((st.lyft_p90 - st.uber_p90) * 60, 1) AS d90_sec,
        ROUND(100.0 * (s.n_ge10_l * 1.0 / s.n_valid_l - s.n_ge10_u * 1.0 / s.n_valid_u), 2) AS dshare_pts
    FROM ce_strata s
    JOIN ce_stratum_stats st ON st.PULocationID = s.PULocationID AND st.daypart = s.daypart AND st.day_type = s.day_type
    WHERE LEAST(s.n_valid_u, s.n_valid_l) >= 1000
)
(SELECT 'Lyft median longer than Uber' AS direction, * FROM d ORDER BY d50_sec DESC LIMIT 10)
UNION ALL
(SELECT 'Lyft median shorter than Uber', * FROM d ORDER BY d50_sec ASC LIMIT 10);

-- name: ce_stratum_compare
-- Export table: every stratum with at least 100 valid waits per company. support_level = the largest ladder value met.
SELECT
    s.pu_borough, s.pu_zone, s.daypart, s.day_type,
    s.n_valid_u, s.n_valid_l,
    ROUND(100.0 * s.n_excl_u / s.n_scoped_u, 3)   AS pct_excluded_uber,
    ROUND(100.0 * s.n_excl_l / s.n_scoped_l, 3)   AS pct_excluded_lyft,
    ROUND(st.uber_p50, 3) AS uber_p50, ROUND(st.lyft_p50, 3) AS lyft_p50, ROUND((st.lyft_p50 - st.uber_p50) * 60, 1) AS d50_sec,
    ROUND(st.uber_p75, 3) AS uber_p75, ROUND(st.lyft_p75, 3) AS lyft_p75,
    ROUND(st.uber_p90, 3) AS uber_p90, ROUND(st.lyft_p90, 3) AS lyft_p90, ROUND((st.lyft_p90 - st.uber_p90) * 60, 1) AS d90_sec,
    ROUND(st.uber_p95, 3) AS uber_p95, ROUND(st.lyft_p95, 3) AS lyft_p95,
    ROUND(100.0 * s.n_ge10_u / s.n_valid_u, 3)    AS uber_share_ge10_pct,
    ROUND(100.0 * s.n_ge10_l / s.n_valid_l, 3)    AS lyft_share_ge10_pct,
    ROUND(100.0 * (s.n_ge10_l * 1.0 / s.n_valid_l - s.n_ge10_u * 1.0 / s.n_valid_u), 3) AS dshare_pts,
    CASE WHEN LEAST(s.n_valid_u, s.n_valid_l) >= 1000 THEN 1000
         WHEN LEAST(s.n_valid_u, s.n_valid_l) >= 500  THEN 500
         WHEN LEAST(s.n_valid_u, s.n_valid_l) >= 300  THEN 300
         WHEN LEAST(s.n_valid_u, s.n_valid_l) >= 200  THEN 200
         ELSE 100 END                             AS support_level
FROM ce_strata s
JOIN ce_stratum_stats st ON st.PULocationID = s.PULocationID AND st.daypart = s.daypart AND st.day_type = s.day_type
WHERE LEAST(s.n_valid_u, s.n_valid_l) >= 100
ORDER BY s.pu_borough, s.pu_zone, s.daypart, s.day_type;