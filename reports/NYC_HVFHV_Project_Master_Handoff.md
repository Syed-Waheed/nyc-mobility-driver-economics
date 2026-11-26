# NYC TLC HVFHV Rider Wait \& Driver Pay Analytics — Master Project Handoff

Use this document as the persistent project context if the assistant loses conversational history. It captures the project from setup through data validation, business findings, predictive modelling, experiment proposal, Excel, and planned Tableau dashboards. Treat the numeric outputs below as source-grounded facts that were shared and reviewed in the project; do not invent missing numbers or silently reconcile unresolved discrepancies.

## 0. Instructions for the project mentor

Act as a senior Data Analyst / Product Analytics mentor and an approachable Data Science coach. The user is a fresher building a portfolio project targeting Data Analyst roles, ideally with a genuine but proportionate Data Science add-on. The goal is a defensible, resume-ready project that the user can explain and own in interviews—not maximal technical complexity.

Preferred teaching style: **what it is → why it matters → easy example → what we found → what we do next**. Explain in plain language first, then add technical detail as useful. Give exact filenames and instructions about where code goes. Track progress in 5-percentage-point increments and say how much remains. Do not ask the parked teach-back questions until the project work is finished.

Workflow is fixed:

- SQL is authored in `.sql` files in VS Code.
- SQL is executed in Jupyter via the existing Python `load_queries()` and `run()` functions using DuckDB.
- Do not tell the user to execute SQL directly in VS Code or install a SQL extension.
- Avoid full-table scans and rebuilding already validated outputs unnecessarily. The source has about 20.4 million rows and the user's MacBook has limited memory.
- Use actual query outputs and existing summary CSVs. Never invent statistics, dollar values, columns, files, or model results.
- If a result is missing, state that clearly and request the smallest check needed.
- Preserve raw records; cleaning decisions are flag-/metric-specific and documented.

## 1. Project identity and business question

**Title:** NYC TLC HVFHV Rider Wait \& Driver Pay Analytics

**Central business question:** Where and when do NYC high-volume ride-hailing trips experience longer waits, how does recorded driver pay vary across operating conditions, how do Uber and Lyft compare fairly, and what operational intervention should be tested first?

**Source:** official NYC TLC High Volume For-Hire Vehicle trip data for January 2025 (`fhvhv_tripdata_2025-01.parquet`), `taxi_zone_lookup.csv`, and `data_dictionary_trip_records_hvfhs.pdf`.

**Raw grain:** one trip record. There are no rider IDs or driver IDs in this extract. The data represents observed trip records, not all requests; cancellations, unfulfilled requests, and unmet demand are not comprehensively represented.

**Stack:** DuckDB/SQL for scale and transformations; Python/Jupyter/pandas/scikit-learn for audit, stats and modelling; Excel for an aggregated analysis workbook; Tableau for executive storytelling.

**Project root:** `/Users/waheed/Desktop/Project1`.

Expected/known structure:

```
Project1/
├── data/
│   ├── fhvhv_tripdata_2025-01.parquet
│   ├── taxi_zone_lookup.csv
│   ├── data_dictionary_trip_records_hvfhs.pdf
│   ├── stage4_model_sample.parquet
│   └── stage4_model_performance.csv
├── sql/
│   ├── 00_setup.sql
│   ├── 00_scope_probe.sql
│   ├── 01_scope.sql
│   ├── 01_clean.sql
│   ├── 02_features.sql
│   ├── 02d_hotspots.sql
│   ├── 02d2_hotspots_zone_hour.sql
│   ├── 02d3_hotspots_zone_daypart.sql
│   ├── 02e_company_like_for_like.sql
│   ├── 02g_shared_wav.sql
│   ├── 03_stage3_validation.sql
│   └── 04_predictive_model.sql
├── notebooks/
│   ├── 00_stage0_scope_probe.ipynb
│   ├── 13_stage2g_shared_wav.ipynb
│   └── 14_stage4_predictive_modeling.ipynb
├── dashboard/
│   └── data/  (aggregated Stage 2A–2F/2G CSV outputs)
├── reports/
├── README.md
├── DECISIONS.md
├── GLOSSARY.md
└── requirements.txt
```

Some files may be elsewhere or have variants/checkpoints; always confirm the actual file before relying on it. Notebook 13 uses the current in-memory DuckDB connection for Stages 0–3 and Stage 2G work. Notebook 14 loads the compact Parquet modelling sample independently.

## 2. Query loader/workflow

The working loader used in the notebook:

```
import os
from pathlib import Path
import duckdb

ROOT = Path.cwd() if (Path.cwd() / "data").exists() else Path.cwd().parent
os.chdir(ROOT)
con = duckdb.connect()

def load_queries(path):
    text = Path(path).read_text(encoding="utf-8")
    queries, current_name, current_sql = {}, None, []
    for line in text.splitlines():
        if line.strip().startswith("-- name:"):
            if current_name is not None:
                queries[current_name] = "\n".join(current_sql).strip()
            current_name = line.split("-- name:", 1)[1].strip()
            current_sql = []
        else:
            current_sql.append(line)
    if current_name is not None:
        queries[current_name] = "\n".join(current_sql).strip()
    return queries

def run(queries, name):
    return con.execute(queries[name]).df()
```

The notebook rebuilds tables from `sql/00_setup.sql`, `sql/01_scope.sql`, `sql/01_clean.sql` and `sql/02_features.sql` by executing queries whose names start with `create_`. The feature reconciliation was checked through `features_reconcile`.

## 3. Stage 0 — scope and raw data checks

- `trips_raw` starts from the January 2025 Parquet data.
- Total row count: **20,405,666**.
- Company/license counts: Uber (`HV0003`) **15,356,455**; Lyft (`HV0005`) **5,049,211**.
- Timestamp ranges observed:
    - request: 2024-12-31 22:31:09 to 2025-02-01 00:10:00
    - on-scene: 2024-12-31 23:25:35 to 2025-01-31 23:59:59
    - pickup: 2025-01-01 00:00:00 to 2025-01-31 23:59:59
    - drop-off: 2025-01-01 00:01:48 to 2025-02-01 01:50:34
- Month cross-tab (`request_month`, `pickup_month`, `dropoff_month`):
    - 2025-01 / 2025-01 / 2025-01: **20,393,027**
    - 2025-01 / 2025-01 / 2025-02: **11,470**
    - 2024-12 / 2025-01 / 2025-01: **1,164**
    - 2025-02 / 2025-01 / 2025-02: **5**
- Interpretation: the dataset is effectively aligned to January pickup date, not a clean January request-date window. A December request picked up in January belongs in the pickup-month scope. Do not filter every analysis blindly to request month; use the scoped output/metric's defined period and document scope precisely.
- `taxi_zone_lookup.csv` is used to translate location IDs into zone/borough labels. Zone join reconciliation reported **zero unmatched pickup zone IDs** in the audited join.

## 4. Stage 1 — data-quality decisions and features

### Main metric contract

- Primary wait = `pickup_datetime - request_datetime` in minutes.
- `is_wait_valid = (wait_seconds >= 0)`.
- Negative waits are excluded from wait statistics only. They are never deleted from the source or globally cleaned away. Zero waits stay valid (about 0.001%).
- `driver_pay` is the directly recorded pay field; do not call it total driver earnings.
- `pay_per_mile` and `pay_per_minute` are only meaningful where their denominators are positive; zero denominators are handled as missing, not by adding an arbitrary epsilon.
- `on_scene_datetime` is not the primary wait metric.

### Negative wait finding

- Negative waits: **199,788 / 20,405,666 = 0.979%**.
- Uber: **120,967 / 15,356,455 = 0.788%**.
- Lyft: **78,821 / 5,049,211 = 1.561%**.
- Gap distribution: under 1 min 36,021; 1–10 min 98,114; 10–60 min 65,649; 60+ min 4. About 82% are at least one minute, so this is not simply rounding noise.
- Uber ordering categories recorded in the audit: normal sequence 15,176,848 (98.830%); on-scene before request but non-negative wait 58,321 (0.380%); negative sequence with on-scene and pickup both before request 111,313 (0.725%); pickup before on-scene before/equal request 9,387 (0.061%); pickup before request before on-scene 267 (0.002%); on-scene after pickup with non-negative wait 319 (0.002%). These values are included as diagnostic evidence, not business outcomes.
- In 92.0% of Uber negative-wait rows (111,313 of 120,967), on-scene and pickup both precede the recorded request. Lyft has negative waits despite almost no on-scene data. Interpretation that timestamps may be recorded out of temporal order is evidence-supported, but the reason is not established.
- Stage 1B sensitivity: excluding Uber's on-scene-before-request but non-negative group of 58,321 leaves Uber median 3.800 min and P90 8.033 min unchanged; a worst-case sensitivity moves P90 to about 8.15 min. Keep these records under the symmetric valid-wait rule and document the caveat.
- Negative-wait rates vary by WAV/flag patterns; Lyft WAV-requested group is especially affected (37.326%). This is a separate timestamp-quality issue, not proof that WAV alone causes missing timestamps.

### `on_scene_datetime` availability

- Uber: 15,356,455 rows, 15,356,455 with on-scene (100.00%).
- Lyft: 5,049,211 rows, only 14,076 with on-scene (0.28%).
- By WAV-match flag, the queried N group had 18,551,153 rows and 14,165,575 with on-scene (76.36%); Y had 1,854,513 rows and 1,204,956 with on-scene (64.97%). This proves it is not simply WAV-match-only.
- An older flag-combination total was calculated as 1,854,885 but the subsequent `wav_match_flag = Y` output was 1,854,513, a **372-row discrepancy**. Do not pretend this discrepancy was resolved; only investigate if it affects a final metric. It is not a headline finding.
- Decision: do not use `on_scene_datetime` as cross-company rider wait.

### Out-of-borough pickups

- 774 pickups were in EWR (zone 1: one row) or “Outside of NYC” (zone 265: 773 rows): Uber 529, Lyft 245; 760 had valid waits (Uber 517, Lyft 243).
- Their inclusion/exclusion did not change company median/P90: Uber 3.800 / 8.033; Lyft 4.083 / 8.033.
- Decision: keep them for volume and company-level/pay metrics, exclude only from five-borough/zone wait tables where they cannot be assigned to a NYC borough.

### Money anomalies are flag-only

Stage 1E found negative/zero/null money and other anomalies. They were flagged and audited, not globally removed. Examples of existing checks include fare components, `flag_pay_negative`, `flag_pay_zero`, `flag_any_money`, `flag_pay_gt_fare`, `flag_zero_miles`, `flag_zero_time`, `flag_speed_ge_100mph`, `flag_pickup_outside_nyc`, and other flag columns. Don't over-interpret `driver_pay > base_passenger_fare` as a data error automatically because base fare and driver pay have different composition.

Tables include `trips_raw`, `trips_scoped`, `trips_clean`, `trips_features`, and `zones`. `trips_clean` has 45 fields, including timestamps, trip attributes, fare components, flags, `wait_seconds`, `is_wait_valid`, `wait_minutes`, `pay_per_mile`, and `pay_per_minute`.

## 5. Stage 2 — descriptive analyses

### Stage 2A — overall waits/company distribution

- Uber median wait: **3.800 min**.
- Lyft median wait: **4.083 min**.
- P90: **8.033 min for both**.
- Valid waits are the basis of these metrics. The full distribution outputs are available in `dashboard/data/2a_wait_profile_by_company.csv`, which includes `n_scoped`, `n_valid`, negative exclusions, mean, P50/P75/P90/P95/P99. `2a_wait_bins_by_company.csv` contains histogram bins and cumulative shares.

### Stage 2B — geography

- Staten Island median wait: **5.100 min**, longest among boroughs in the analysis.
- Manhattan median wait: **3.533 min**, shortest.
- Source summaries available as `2b_borough_wait_profile.csv`, `2b_zone_wait_profile.csv`, `2b_zone_wait_profile_by_company.csv`.
- Avoid ranking tiny zones without sample-size/small-sample protections. The borough table is company-stratified; don't average company medians and call it a pooled borough median. Use verified pooled figures or label the company-specific values correctly.

### Stage 2C — time of day

- 7 AM had the worst wait outcomes; 10 AM had the best in the hourly analysis.
- Trip volume peaked around 6 PM, illustrating that the busiest hour is not necessarily the worst-wait hour.
- Negative-wait exclusions peaked around 04:00–05:00; volume patterns support but do not prove timezone interpretation.
- Key outputs include `2c_hour_profile.csv`, `2c_hour_weekday_profile.csv`, `2c_hourly_volume_curve.csv`, `2c_weekday_profile.csv`, and `2c_hour_exclusion_sensitivity.csv`.

### Stage 2D — hotspot designs

Files include `sql/02d_hotspots.sql`, `sql/02d2_hotspots_zone_hour.sql`, and `sql/02d3_hotspots_zone_daypart.sql` with multiple competing hotspot resolutions. The design chosen for the headline finding is **Design C / zone × daypart × day type**, from `02d3_hotspots_zone_daypart.sql` (`zdd_cells`, `zdd_hotspots`). It uses a cell-specific long-wait rate, Wilson lower bound, baseline for the matching daypart/day-type slot, minimum adequate sample tiers and robust exclusion sensitivity.

Headline full-month result: **133 robust hotspot cells account for 5.96% of valid trips and 22.07% of long waits (wait ≥10 min)**. The output covers concentrated airport and outer-borough cells, but airport-baseline sensitivity changes which cells are flagged; don't represent the set as immutable truth. Other hotspot resolutions are supporting/appendix analysis, not the dashboard headline.

### Stage 2E — like-for-like Uber/Lyft comparisons

- Pooled statistics can be confounded by operating mix, so company comparison used common-supported pickup zone × daypart × day-type strata and standardized/stratified outputs.
- Standardized median difference: Lyft about **18.4 seconds slower**.
- Standardized P99: Lyft about **67.3 seconds faster**.
- Median comparison reverses at airports.
- A standardized long-wait-share gap can change sign under exclusion bounds. Therefore don't claim a consistent company winner or only use pooled medians. Relevant data files: `2e_standardized_summary.csv`, `2e_standardized_support.csv`, `2e_stratum_compare.csv`, `2e_stratum_diff_summary.csv`, `2e_support_by_borough.csv`, `2e_support_curve.csv`, `2e_share_exclusion_bounds.csv`.

### Stage 2F — driver pay

- Differences in raw company pay distributions are strongly affected by trip-length mix.
- Pay per trip, pay per mile and pay per minute tell different stories and trade-offs.
- Lyft recorded pay bunches at **$5.47**.
- Tested money-field sensitivity statistics moved by no more than **0.289%**.
- No take rate can be calculated reliably from these fields.
- CSVs in `dashboard/data/` include `2f_pay_by_borough_company.csv`, `2f_pay_by_daypart_company.csv`, `2f_pay_by_distance_band.csv`, `2f_pay_by_duration_band.csv`, `2f_pay_by_hour_company.csv`, `2f_pay_by_wait_band.csv`, `2f_pay_by_wait_within_distance.csv`, `2f_pay_by_zone_company.csv`, `2f_pay_by_zone.csv`, `2f_pay_distribution.csv`, `2f_ppm_distribution.csv`, `2f_ppmin_distribution.csv`, `2f_fare_component_audit.csv`, `2f_money_filter_robustness.csv`, `2f_pay_mean_sensitivity.csv`, `2f_pay_gt_fare_by_distance_band.csv`, `2f_pay_to_fare_by_company.csv`, `2f_ratio_denominator_diagnostics.csv`, and `2f_reconcile.csv`. Their columns were inspected. Use actual source outputs to populate charts; exact distribution percentiles/dollar figures beyond stated findings were not pasted into the handoff and must not be invented.

### Stage 2G — shared rides and WAV

Shared group CSV/notebook output columns: `shared_group`, `n_rows`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `wait_p50_min`, `wait_p90_min`, `pct_wait_ge10`, `median_miles`.

Correct rows:

- **Shared requested, matched:** 471,930 total; 466,787 valid; 5,143 negative-wait exclusions (1.090%); median 7.017 min; P90 14.200 min; 27.910% waits ≥10 min; median miles 5.70.
- **Shared requested, not matched:** 365,342 total; 361,794 valid; 3,548 excluded (0.971%); median 5.700; P90 **9.133**; waits ≥10 **6.968%**; median miles 2.33.
- **Not shared:** 14,519,183 total; 14,406,907 valid; 112,276 excluded (0.773%); median 3.700; P90 7.683; waits ≥10 4.578%; median miles 2.82. The P90 and long-wait share columns were once mixed up in a written summary. The current notebook `sh` output confirms the values above; use this corrected version.

A like-for-like Uber comparison was subsequently run in `sql/02g_shared_wav.sql` under query `shared_vs_not_shared_zone_daypart`. It uses common pickup-zone × daypart cells with at least 50 valid waits in both groups and equal cell weights for shared vs non-shared:

- Raw long-wait rate: shared-requested **18.766%**; not shared **4.578%**.
- Standardized long-wait rate: shared-requested **17.963%**; not shared **4.438%**.
- Gap: **13.524 percentage points**.
- 1,182 common cells; coverage **99.77%** of shared-requested valid waits and **97.92%** of non-shared valid waits.
- Shared matched trips are longer (median 5.70 miles vs 2.33 for requested/unmatched and 2.82 not shared); this is selection/operating-mix, not causal proof.

WAV group output reconciles to Uber 15,356,455 and Lyft 5,049,211 records:

- Uber WAV requested: 37,074 rows; 36,395 valid; 679 excluded (1.831%); median 8.067; P90 14.550; long waits 31.944%; median miles 2.80; Access-A-Ride overlap 4.60%.
- Uber WAV vehicle, not requested: 1,153,806 rows; 1,147,070 valid; 6,736 excluded (0.584%); median 3.833; P90 8.033; long waits 5.266%; median miles 2.25.
- Uber no WAV: 14,165,575 rows; 14,052,023 valid; 113,552 excluded (0.802%); median 3.783; P90 8.017; long waits 5.288%; median miles 2.95.
- Lyft WAV requested: 14,076 rows; 8,822 valid; 5,254 excluded (**37.326%**); median 5.950; P90 11.500; long waits 15.745%; median miles 2.66; Access-A-Ride 4.52%.
- Lyft WAV vehicle, not requested: 649,557 rows; 638,653 valid; 10,904 excluded (1.679%); median 4.017; P90 7.967; long waits 4.637%; median miles 2.96.
- Lyft no WAV: 4,385,578 rows; 4,322,915 valid; 62,663 excluded (1.429%); median 4.083; P90 8.033; long waits 4.756%; median miles 2.66. Interpretation: WAV-requested trips have elevated waits for Uber, but location/time mix isn't yet matched. Lyft WAV-requested results are heavily affected by the 37.326% negative-wait exclusion rate. Do not directly rank Lyft vs Uber WAV waits. Keep WAV requested distinct from a WAV-capable vehicle that was not requested.

## 6. Stage 3 focused validations

File: `sql/03_stage3_validation.sql`. Queries run through notebook 13.

### 7 AM vs 10 AM monthly validation

- 7 AM: trip rows 932,409; valid waits 911,980; long waits 99,314; median **4.983 min**; P90 **10.267 min**; long-wait rate **10.890%**.
- 10 AM: trip rows 879,047; valid waits 864,280; long waits 21,812; median **3.350 min**; P90 **6.533 min**; long-wait rate **2.524%**.
- Gap in monthly rate: **8.366 percentage points**; ratio about 4.31×.

### Daily stability

Daily paired request-date summaries compared 7 AM to 10 AM across Jan 1–31.

- 7 AM median wait higher on **31/31 days**.
- 7 AM long-wait rate higher on **30/31 days**; Jan 29 was the exception.
- Median daily long-wait-rate gap: **6.831 percentage points**.
- Mean daily gap: **7.018 points**, approximate daily-level t interval **5.055–8.981 points**.
- Caveat: daily differences can be serially dependent, so the interval is approximate.

### Hotspot second-half stability

We ran `stage3_hotspot_second_half_persistence` using the **original full-month-selected 133 robust Design C cells**, not a newly selected cell set. Results Jan 16–31:

- original hotspot cells: 133; all 133 had valid waits.
- 128/133 (96.24%) still showed a long-wait rate at least 2× the corresponding daypart/weekend slot rate.
- 625,538 valid waits; 125,673 long waits within original cells.
- original hotspot cells contained **5.80%** of valid waits and **22.18%** of long waits.
- hotspot long-wait rate **20.09%** vs overall **5.25%**.
- Caveat: selected on the full month, so it is a stability/sensitivity check, not independent holdout validation.

We decided to keep Stage 3 lean and focus on key findings rather than further exploratory analysis.

## 7. Stage 4 predictive modelling

We did not skip the DS add-on. The question is: **Can we identify recorded trips at higher risk of a wait ≥10 minutes from information available at request time?**

SQL file `sql/04_predictive_model.sql`, named query `create_stage4_model_sample`, built `data/stage4_model_sample.parquet` from `trips_clean`:

- request dates January 1–31
- companies HV0003 and HV0005
- non-null pickup zone
- valid wait (`is_wait_valid = TRUE`)
- `in_geo_wait_tables = TRUE`
- deterministic \~1% sample: `hash(CAST(request_datetime AS VARCHAR) || '|' || CAST(PULocationID AS VARCHAR) || '|' || CAST(DOLocationID AS VARCHAR) || '|' || hvfhs_license_num || '|' || COALESCE(dispatching_base_num,'')) % 100 = 0`
- target `1` if `wait_minutes >= 10`, otherwise `0`
- row features: split, request date, hour, ISO weekday, pickup zone, company, shared-requested flag, WAV-requested flag, target. No post-outcome fare, pay, actual pickup, trip duration or distance is used as a feature.
- sample shape: **201,602 rows × 9 columns**, \~0.3 MB Parquet.

Time split:

- Train Jan 1–21: 134,168 rows; 7,468 long waits; 5.57% event rate.
- Validation Jan 22–24: 20,991 rows; 1,041 long waits; 4.96% event rate.
- Test Jan 25–31: 46,443 rows; 2,107 long waits; 4.54% event rate. The declining event rate is a potential temporal shift to mention.

Models implemented in `notebooks/14_stage4_predictive_modeling.ipynb`:

1. Smoothed zone-hour baseline from training data only, with alpha=100 smoothing toward overall training event rate.
2. Logistic regression with one-hot encoding of pickup zone, request hour, weekday, company, shared-request and WAV-request; `max_iter=1000`, `C=1.0`, no class weights, random seed 42.
3. Random forest with one-hot encoded features; 100 trees, max depth 16, minimum leaf 50, `max_features='sqrt'`, `n_jobs=2`, `random_state=42`.

Validation performance: \| Model \| Average precision \| ROC-AUC \| Brier \| Top 10% long-wait rate \| Share of waits captured in top 10% \| \|---\|---:\|---:\|---:\|---:\|---:\| \| Zone-hour baseline \| 0.1212 \| 0.6725 \| 0.0460 \| 14.6190% \| 29.4909% \| \| Logistic regression \| 0.1317 \| 0.7008 \| 0.0456 \| 16.6667% \| 33.6215% \| \| Random forest \| 0.1367 \| 0.6910 \| 0.0454 \| 17.2381% \| 34.7743% \|

Final test performance (Jan 25–31, 46,443 rows; observed long-wait rate 4.54%): \| Model \| Average precision \| ROC-AUC \| Brier \| Top 10% long-wait rate \| Share of waits captured in top 10% \| \|---\|---:\|---:\|---:\|---:\|---:\| \| Zone-hour baseline \| 0.1204 \| 0.6643 \| 0.0421 \| 12.6803% \| 27.9544% \| \| Logistic regression \| 0.1282 \| 0.7015 \| 0.0419 \| 15.6297% \| 34.4566% \| \| Random forest \| 0.1358 \| 0.6905 \| 0.0416 \| 16.2110% \| 35.7380% \|

Performance results saved in `data/stage4_model_performance.csv` (six rows, train split is not an evaluation row; includes validation and test comparisons). Chosen candidate: random forest for prioritization because it has highest test average precision, lowest Brier, and highest top-10% capture. Logistic regression has highest ROC-AUC. Explain trade-offs rather than saying one model wins every metric. Random forest is not a proven live dispatch system; prospective testing would be required to prove operational impact. Evaluation is on one month of data and completed trips with valid waits only.

## 8. Experimental design proposal

This is a proposal, not a completed experiment.

- Business issue: long waits concentrated in a small set of zone/time cells.
- Hypothesis: targeted driver positioning or additional dispatch coverage in selected hotspot windows lowers the proportion of all eligible requests not picked up within 10 minutes compared with normal operations.
- Experimental unit: pickup-zone × time-window × date block (not individual trip), to manage driver-supply interference.
- Assignment: randomize feasible blocks, balanced by zone, weekday and daypart; consider randomized switchback where driver spillovers are likely.
- Primary outcome: share of all eligible requests not picked up within 10 minutes. Need request/cancellation/unfulfilled data during pilot because completed-trip table alone cannot fully measure it.
- Secondary outcomes: median/P90 among picked-up trips, completion, cancellations/no-driver outcomes.
- Guardrails: driver pay per trip/mile/minute, cost, driver utilization, nearby-zone effects/service displacement.
- Before launch: define minimum worthwhile effect; calculate sample size using baseline, cluster-level variance/correlation and randomization plan; historical data alone is not enough to assert a credible sample size.
- Roll out only if the randomized pilot shows a meaningful, sufficiently precise improvement without unacceptable guardrail deterioration.

## 9. Excel deliverable

An Excel workbook was generated at `/mnt/data/NYC_HVFHV_Excel_Analysis_Workbook.xlsx`, intended to be saved into `Project1/reports/NYC_HVFHV_Excel_Analysis_Workbook.xlsx` after downloading/copying.

It is intended as an 11-sheet analysis and presentation workbook with executive overview/KPIs, wait analysis, hotspot summaries, Uber/Lyft, shared/WAV, recorded pay, model comparisons, definitions/decisions, etc. The generated workbook must be validated against real CSV exports before claiming every displayed value is confirmed. If you have access, do a limited check of key values against actual source CSVs and fix any mismatch; don't silently trust mockup values.

## 10. Tableau dashboard plan

A rough image mockup was generated only as a visual reference; it is not a real data-connected Tableau dashboard and some pay/borough numbers in the mockup were illustrative/unverified. Use only actual CSV outputs for final visualizations.

Build three dashboards/tabs:

### Dashboard 1 — Executive Overview

Title: **NYC RIDE-HAILING: RIDER WAIT \& DRIVER PAY** Subtitle: *January 2025 \| Where long waits concentrate, how providers compare, and what to test next*

KPI row:

1. Total original trip records **20.41M** (20,405,666).
2. Uber median wait **3.80 min**.
3. Lyft median wait **4.08 min**.
4. Hotspot share of long waits **22.07%**, from **5.96%** of valid trips.
5. 7 AM vs 10 AM long-wait rates **10.89% vs 2.52%**.

Main views:

- Borough median wait (sorted horizontal bars; actual pooled/company grain must be labelled correctly. `2b_borough_wait_profile.csv` has company rows; don't average medians and call it pooled. Verified anchor figures Staten Island 5.100; Manhattan 3.533.)
- Hourly/daypart long-wait view from actual hourly output (`2c_hour_profile.csv` or compatible profile; heatmap can use `2d_slot_baseline.csv` for hour × weekday with `pct_wait_ge10`).
- Hotspot concentration: compare valid-trip share and long-wait share; use `2d3_zone_daypart_hotspots.csv` fields `hotspot_robust_flag`, `n_valid`, `n_wait_ge10`; aggregate correctly.
- Uber vs Lyft: P50/P90 from `2a_wait_profile_by_company.csv` or standardized summary; annotate P99/airport caveat.
- Footer with wait definition, negative-wait handling, completed-trip scope, on-scene caveat, observational nature and no take rate.

### Dashboard 2 — Driver Pay Economics

Use actual sources:

- `2f_pay_by_distance_band.csv` fields include `company`, `distance_band`, `n`, `pct_of_company`, `pay_p25`, `pay_p50`, `pay_p75`, `ppm_p50`, `ppmin_p50`, `median_miles`, `median_minutes`.
- `2f_pay_by_duration_band.csv` similar fields.
- `2f_pay_by_borough_company.csv`, `2f_pay_by_daypart_company.csv`, `2f_pay_by_hour_company.csv`, `2f_pay_by_wait_band.csv`, `2f_pay_by_zone_company.csv` and distribution files as appropriate. Use two separate pay efficiency panes; don't use dual axes for pay-per-mile and pay-per-minute because units differ. State the trade-off and record-pay caveats.

### Dashboard 3 — Model Evaluation

Source: `data/stage4_model_performance.csv`. Show held-out test comparison and metric definitions. Test period Jan 25–31; n=46,443; 4.54% long-wait event rate. Random forest highlighted for AP/Brier/top-10 capture; logistic regression has highest ROC-AUC. State one-month/proof-of-concept limitation.

### Style

- Navy `#163B65` (header), blue/Uber `#2F80ED`, purple/Lyft `#8B5CF6`, coral/long-wait risk `#D95D39`, canvas `#F3F6FA`, secondary text `#64748B`.
- White chart cards, restrained typography, whitespace, light gridlines, direct labels, consistent units, meaningful annotations. Avoid rainbow colors/gauges.
- Initial dashboard size roughly 1440 × 1000 px, then check actual laptop viewing and scrolling.
- Header should include NYC skyline image, title/subtitle, navigation controls for Overview / Driver Pay Economics / Model Evaluation, and a static “Jan 2025” date badge. Since sources are mostly fixed January aggregate files, do not pretend the date badge is a working date filter unless we build compatible filtered sources.
- NYC skyline generic SVG assets were packed in `tableau_brand_assets.zip`; user can save under `dashboard/assets/`. Uber/Lyft logos should be downloaded from official media assets, or use consistent text labels if logo assets are difficult. Do not use a governmental logo falsely.
- Build individual worksheets and place them in containers. Do not use the mockup as a single background image: all charts must be actual Tableau worksheets.

### Candidate Tableau calculated fields (only use if the selected source contains raw columns)

`Wait Minutes`:

```
DATEDIFF('second', [request_datetime], [pickup_datetime]) / 60.0
```

`Valid Wait Minutes`:

```
IF NOT ISNULL([request_datetime])
AND NOT ISNULL([pickup_datetime])
AND [Wait Minutes] >= 0
THEN [Wait Minutes]
END
```

`Long Wait Flag`:

```
IF ISNULL([Valid Wait Minutes]) THEN NULL
ELSEIF [Valid Wait Minutes] >= 10 THEN 1
ELSE 0
END
```

`Long Wait Rate`:

```
SUM([Long Wait Flag]) / COUNT([Valid Wait Minutes])
```

`Pay per Mile`:

```
IF [trip_miles] > 0 THEN [driver_pay] / [trip_miles] END
```

`Pay per Minute` (trip\_time in seconds):

```
IF [trip_time] > 0 THEN [driver_pay] / ([trip_time] / 60.0) END
```

For pre-aggregated summaries, use the existing fields and aggregation level; don't recompute percentile medians by averaging other group medians. Check whether percent columns are stored in 0–100 or 0–1 units before percent formatting. Never join summary CSVs of incompatible grains.

## 11. Storytelling: simple interview version

**30-second pitch:** “I analyzed about 20.4 million NYC TLC high-volume ride-hailing trip records for January 2025 to understand where and when rider waits are longest, how Uber and Lyft compare under different operating conditions, and how recorded driver pay varies. I used DuckDB/SQL for data quality and aggregation, retained raw records while excluding negative waits only from wait metrics, identified a small group of hotspot zone/time cells with a disproportionate share of long waits, compared companies with a like-for-like approach, and built a time-based long-wait risk model. The random forest captured about 35.7% of test-set long waits when prioritizing the top 10% of scored trips, versus 28.0% for a zone-hour baseline. I translated the findings into a targeted, randomized operational pilot proposal and a Tableau/Excel reporting package. The findings are observational; the pilot is needed to test causal impact.”

**Plain-language narrative:**

1. First, I checked what each row represented and which dates were really covered. The file is a pickup-date-based monthly extract with some requests and drop-offs crossing month boundaries.
2. I audited timestamps rather than deleting inconvenient data. Negative waits appeared in 0.979% of rows, so they are excluded from wait statistics only. On-scene data is too uneven between Uber and Lyft to compare their waits fairly.
3. Median wait alone hid important differences. Staten Island waited longer than Manhattan, and 7 AM was consistently worse than 10 AM.
4. I identified hotspot zone/time cells where long waits were concentrated. The original 133 cells represented only 5.96% of valid waits but 22.07% of long waits. The same cells remained high-impact in a second-half stability check, with a clear caveat that the set was selected on the full month.
5. Uber/Lyft comparisons depend on metric and operating conditions. Uber's pooled median was lower, but P90 was tied and the standardized tail comparison told a different story; at airports the median gap reversed.
6. Shared-requested trips had a much higher long-wait rate even after comparing shared and non-shared rides across common pickup-zone/daypart cells. This remains observational, and matched trips were longer.
7. Pay per trip, mile and minute answered different questions. I avoided calling driver\_pay total earnings or claiming a take rate.
8. Finally, I asked whether a model could identify long-wait risk. A random forest improved average precision and top-10% capture compared with a historical zone-hour baseline on later test dates, but one month of completed-trip data does not prove that a dispatch change causes waits to improve.
9. So I recommend testing targeted positioning/dispatch coverage in selected hotspot windows with random assignment and guardrails, rather than asserting the intervention works already.

## 12. Potential interview questions and defensible answers

**Why January 2025?** It is a defined official monthly TLC slice with over 20 million records; the project is scoped as a focused operational case study. Do not generalize automatically to every season/year.

**What exactly is wait?** Pickup datetime minus request datetime, converted to minutes, for rows with non-negative wait. We don't substitute on-scene time because availability is company-specific.

**Why not delete negative waits?** They are a data-quality problem for wait calculations but can still be legitimate observed trip records for other fields. Deleting whole rows would affect unrelated pay/volume analyses. We exclude them only for wait metrics and document the 0.979% exclusion.

**Does that capture all rider frustration?** No. The dataset is completed trip records; cancels, unfulfilled requests and unmet demand are not fully represented. The observed wait analysis may understate the broader marketplace problem.

**Why median plus P90?** Median describes a typical trip; P90 reveals the longer-wait tail. A single mean or median can hide operationally painful extremes.

**Why long wait = 10 minutes?** It is a chosen operational threshold for segmenting the wait distribution. It is a definition for this analysis, not a universal service standard. Explain and keep it consistent.

**How did you avoid small-zone noise?** The hotspot method uses minimum sample adequacy and Wilson lower confidence bounds, with the relevant daypart/day-type baseline and sensitivity to exclusion uncertainty. Don't claim it corrects every bias.

**What does “133 hotspots” mean?** In the full-month Design C, 133 robust zone × daypart × day-type cells met the specified threshold. They represented 5.96% of valid waits/trips but 22.07% of waits ≥10 minutes. The second-half check uses the same full-month-selected cells and is not independent validation.

**Why compare companies like-for-like?** The companies operate in different location/time mixes. Raw averages can mislead. Stratification/standardization on common zone/daypart/day-type support makes the comparison fairer but only for the cells/groups with support; exclusions and uncertainty still matter.

**Can you say Uber is faster?** Not universally. Pooled Uber median 3.800 min vs Lyft 4.083 min; P90 tied at 8.033; standardized median about 18.4 seconds longer for Lyft but standardized P99 about 67.3 seconds faster; airports reverse the median difference.

**Do shared rides cause long waits?** No causal claim. All shared-requested Uber trips showed 18.766% raw long waits vs 4.578% non-shared; standardized rates 17.963% vs 4.438% over 1,182 common zone/daypart cells. Longer trip distances/selection could still explain part of the association.

**Why not rank Lyft WAV waits against Uber?** Lyft WAV requested has 37.326% negative-wait exclusions, versus 1.831% for Uber WAV-requested. The valid subset differs materially, so a direct company ranking is not reliable.

**What does driver\_pay represent?** The recorded driver-pay field, not necessarily total driver earnings. Pay per trip/mile/minute describe distinct trade-offs; no company take rate can be calculated from available fields.

**Why this model and target?** Predicting wait ≥10 minutes is actionable as a prioritization/risk-ranking question. Features are intended to be available at request time; post-outcome fields such as actual pickup, fare/pay and trip duration are excluded to avoid leakage.

**Why time split?** It better reflects predicting the future from the past. Train Jan 1–21, validation Jan 22–24, test Jan 25–31. The event rate falls from 5.57% to 4.54%, so temporal drift is a potential limitation.

**Why random forest if logistic regression has better ROC-AUC?** The operational objective prioritizes identifying long waits within limited capacity. Random forest has higher test average precision (0.1358 vs 0.1282), lower Brier (0.0416 vs 0.0419) and greater top-10% capture (35.74% vs 34.46%). Logistic regression still has higher ROC-AUC (0.7015 vs 0.6905). Thus, selection depends on objective, not one universal score.

**Does the model prove a dispatch change works?** No. It predicts risk in observed trips. Only a prospective randomized pilot can estimate causal impact.

**How would you test the recommendation?** Randomize feasible pickup-zone × time-window × date blocks or run a randomized switchback, measure all-eligible-request time-to-pickup/10-minute outcome, predefine sample size/minimum effect, and monitor pay, completion, costs, and displacement to nearby zones.

**What would you do next with more data?** Add all request/cancel/no-driver records and multiple months/seasons; validate data timestamp mechanisms; run out-of-time evaluations across seasons; test the intervention prospectively; assess fairness/accessibility outcomes without over-interpreting WAV data quality.

## 13. Resume-bullet direction (use only after dashboard and workbook QA)

Possible draft bullets; do not add unmeasured claims:

- Analyzed 20.4M NYC TLC HVFHV trip records using DuckDB SQL and Python to audit timestamps, quantify rider waits, compare provider operating conditions, and profile recorded driver-pay trade-offs.
- Identified 133 full-month-selected zone/daypart/day-type hotspot cells representing 5.96% of valid waits but 22.07% of long waits; tested second-half stability and documented selection limitations.
- Built and evaluated a time-split long-wait risk classifier; on a Jan 25–31 test sample, the random forest achieved 0.1358 average precision and captured 35.74% of long waits in the highest-risk 10%, versus 27.95% for the zone-hour baseline.
- Developed an operational pilot proposal and Tableau/Excel reporting package, distinguishing predictive association from causal impact.

Only use the Tableau/Excel claim once the dashboard is actually published and workbook values have been reconciled to CSV source results.

## 14. Current status and remaining tasks

Core SQL audits, descriptive analysis, shared/WAV outputs, Stage 3 hourly/hotspot checks, and Stage 4 model comparison are substantially complete. An Excel workbook has been generated at `/mnt/data/NYC_HVFHV_Excel_Analysis_Workbook.xlsx`; download/copy it into `Project1/reports/` and verify key values against actual sources before final use. A rough dashboard mockup and skyline SVG pack were generated. The mockup is not a Tableau workbook and includes some illustrative/unverified values; do not reuse those values.

Remaining work:

1. Validate Excel KPI and chart values against actual source CSVs (small check only).
2. Build three real Tableau dashboards: Executive Overview, Driver Pay Economics, Model Evaluation.
3. Connect actual prepared aggregated CSV sources; avoid joins between incompatible summary grains.
4. Build worksheets, titles, KPI cards, header, navigation, annotations, source/limitations footer; verify every display against source.
5. Publish on Tableau Public if appropriate and retain screenshot/link.
6. Write final one-page business memo and README, glossary/decision references, final resume bullets and interview defense sheet.
7. Practice explaining the project in plain language after deliverables are complete; do not quiz the user before then.

## 15. Progress convention

Previously estimated around **90% complete** before actual Tableau construction and final QA. Treat this as a rough planning estimate, not a file-based measurement. Tableau/dashboard creation, workbook QA, memo/README and publication remain. Give an update at each next 5% completion milestone, explicitly saying how much remains, and don't inflate completion before a milestone's deliverable is actually done.

## 16. Tableau output inventory captured from the actual CSV-header scan

The user scanned CSV headers with pandas `pd.read_csv(path, nrows=0)` and found 52 CSVs when Jupyter checkpoint copies are included. Ignore `.ipynb_checkpoints` copies in Tableau; use the canonical `dashboard/data/` files and the two Stage 4 files. The following paths/columns were actually shown in the console output and are useful for mapping worksheets. Do not treat a CSV's existence as validation of its numeric contents.

- `dashboard/data/2a_wait_bins_by_company.csv`: `hvfhs_license_num`, `company`, `bin_start_min`, `bin_label`, `n_rows`, `pct_of_scoped`, `pct_of_valid`, `cum_pct_of_valid`
- `dashboard/data/2a_wait_profile_by_company.csv`: `hvfhs_license_num`, `company`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `mean_min`, `p50_min`, `p50_sec`, `p75_min`, `p90_min`, `p95_min`, `p99_min`
- `dashboard/data/2b_borough_wait_profile.csv`: `company`, `pu_borough`, `n_zones`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `mean_min`, `p50_min`, `p75_min`, `p90_min`, `p95_min`, `p99_min`
- `dashboard/data/2b_zone_wait_profile.csv`: `PULocationID`, `pu_borough`, `pu_zone`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `pct_uber_of_valid`, `p50_min`, `p75_min`, `p90_min`, `p95_min`, `sample_tier`, `rank_in_borough_p50`, `rank_overall_p50`
- `dashboard/data/2b_zone_wait_profile_by_company.csv`: `company`, `PULocationID`, `pu_borough`, `pu_zone`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `p50_min`, `p75_min`, `p90_min`, `p95_min`, `sample_tier`
- `dashboard/data/2c_hour_exclusion_sensitivity.csv`: `company`, `request_hour`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `p50_valid_min`, `p50_low_min`, `p50_high_min`, `p50_bound_width_sec`, `p50_level_low_pct`, `p50_level_high_pct`, `p90_valid_min`, `p90_low_min`, `p90_high_min`, `p90_bound_width_sec`, `p90_level_low_pct`, `p90_level_high_pct`
- `dashboard/data/2c_hour_profile.csv`: `company`, `request_hour`, `n_scoped`, `pct_of_company_volume`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `p50_min`, `p75_min`, `p90_min`, `p95_min`
- `dashboard/data/2c_hour_weekday_profile.csv`: `company`, `request_isodow`, `request_hour`, `n_scoped`, `pct_of_company_volume`, `avg_trips_per_day`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `p50_min`, `p75_min`, `p90_min`, `p95_min`, `sample_tier`
- `dashboard/data/2c_hourly_volume_curve.csv`: `company`, `day_type`, `request_hour`, `n_scoped`, `pct_of_company_daytype_volume`
- `dashboard/data/2c_weekday_profile.csv`: `company`, `request_isodow`, `dow_name`, `n_days`, `n_scoped`, `pct_of_company_volume`, `avg_trips_per_day`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `p50_min`, `p75_min`, `p90_min`, `p95_min`
- `dashboard/data/2d_slot_baseline.csv`: `request_isodow`, `request_hour`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `n_wait_ge10`, `pct_wait_ge10`
- `dashboard/data/2d_hotspot_by_slot.csv`: `request_isodow`, `request_hour`, `n_adequate_cells`, `n_hotspot_cells`, `n_robust_cells`
- `dashboard/data/2d_zone_hour_weekday_hotspots.csv`: `PULocationID`, `pu_borough`, `pu_zone`, `request_isodow`, `request_hour`, `n_days`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `avg_trips_per_day`, `pct_uber_of_valid`, `p50_min`, `p90_min`, `sample_tier`, `n_wait_ge10`, `pct_wait_ge10`, `pct_wait_ge10_wilson_low`, `pct_wait_ge10_wilson_high`, `pct_ge10_if_excluded_all_short`, `pct_ge10_if_excluded_all_long`, `slot_pct_wait_ge10`, `zone_pct_wait_ge10_all_hours`, `ratio_vs_slot`, `excess_vs_slot_pts`, `excess_vs_zone_pts`, `wilson_low_frac`, `slot_frac`, `hotspot_flag`, `hotspot_robust_flag`
- `dashboard/data/2d2_coverage_tradeoff.csv`: `design`, `n_slots`, `n_cells`, `n_adequate_cells`, `valid_rows`, `pct_valid_rows_in_adequate_cells`, `zones_with_adequate_cell`
- `dashboard/data/2d2_coverage_tradeoff_by_borough.csv`: `design`, `pu_borough`, `n_zones`, `n_cells`, `n_adequate_cells`, `zones_with_adequate_cell`, `valid_rows`, `pct_valid_rows_in_adequate_cells`
- `dashboard/data/2d2_zone_hour_hotspots.csv`: `PULocationID`, `pu_borough`, `pu_zone`, `request_hour`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `avg_trips_per_day`, `pct_uber_of_valid`, `p50_min`, `p90_min`, `sample_tier`, `n_wait_ge10`, `pct_wait_ge10`, `pct_wait_ge10_wilson_low`, `pct_wait_ge10_wilson_high`, `pct_ge10_if_excluded_all_short`, `pct_ge10_if_excluded_all_long`, `slot_pct_wait_ge10`, `zone_pct_wait_ge10_all_hours`, `ratio_vs_slot`, `excess_vs_slot_pts`, `excess_vs_zone_pts`, `wilson_low_frac`, `slot_frac`, `hotspot_flag`, `hotspot_robust_flag`
- `dashboard/data/2d2_zone_hour_hotspots.csv` (checkpoint copy was also found): same schema as the canonical `2d2_zone_hour_hotspots.csv` listed above; ignore checkpoint duplicate.
- `dashboard/data/2d3_coverage_tradeoff_v2.csv`: `design`, `n_slots`, `n_cells`, `n_adequate_cells`, `zones_with_adequate_cell`, `total_valid_rows`, `valid_rows_in_adequate_cells`, `pct_valid_rows_in_adequate_cells`
- `dashboard/data/2d3_zone_daypart_hotspots.csv`: `PULocationID`, `pu_borough`, `pu_zone`, `daypart`, `day_type`, `n_days`, `n_scoped`, `n_valid`, `n_excluded_negative_wait`, `pct_excluded`, `avg_trips_per_day`, `pct_uber_of_valid`, `p50_min`, `p90_min`, `sample_tier`, `n_wait_ge10`, `pct_wait_ge10`, `pct_wait_ge10_wilson_low`, `pct_wait_ge10_wilson_high`, `pct_ge10_if_excluded_all_short`, `pct_ge10_if_excluded_all_long`, `slot_pct_wait_ge10`, `slot_pct_wait_ge10_ex_airports`, `zone_pct_wait_ge10_all_slots`, `ratio_vs_slot`, `excess_vs_slot_pts`, `excess_vs_zone_pts`, `excess_long_waits_vs_slot`, `excess_long_waits_vs_zone`, `wilson_low_frac`, `slot_frac`, `hotspot_flag`, `hotspot_robust_flag`, `hotspot_type`, `hotspot_flag_ex_airport_baseline`, `is_airport_zone`
- `dashboard/data/2d3_zone_severity.csv`: `PULocationID`, `pu_borough`, `pu_zone`, `n_scoped`, `n_valid`, `n_excluded`, `pct_excluded`, `n_wait_ge10`, `zone_pct_wait_ge10`, `zone_pct_wait_ge10_wilson_low`, `city_pct_wait_ge10`, `ratio_vs_city`, `n_adequate_cells`, `zone_severity_flag`
- `dashboard/data/2e_share_exclusion_bounds.csv`: `min_n`, `uber_share_valid_pct`, `lyft_share_valid_pct`, `diff_share_valid_pts`, `uber_share_if_excluded_short_pct`, `uber_share_if_excluded_long_pct`, `lyft_share_if_excluded_short_pct`, `lyft_share_if_excluded_long_pct`, `diff_lower_bound_pts`, `diff_upper_bound_pts`
- `dashboard/data/2e_standardized_summary.csv`: `min_n`, `grp`, `scheme`, `uber_p50`, `lyft_p50`, `diff_p50_sec`, `uber_p75`, `lyft_p75`, `diff_p75_sec`, `uber_p90`, `lyft_p90`, `diff_p90_sec`, `uber_p95`, `lyft_p95`, `diff_p95_sec`, `uber_p99`, `lyft_p99`, `diff_p99_sec`, `uber_share_ge10_pct`, `lyft_share_ge10_pct`, `diff_share_pts`
- `dashboard/data/2e_standardized_support.csv`: `min_n`, `grp`, `n_strata`, `uber_valid_in_support`, `uber_pct_of_group`, `lyft_valid_in_support`, `lyft_pct_of_group`, `max_stratum_weight_pct`, `airport_weight_pct`
- `dashboard/data/2e_stratum_compare.csv`: `pu_borough`, `pu_zone`, `daypart`, `day_type`, `n_valid_u`, `n_valid_l`, `pct_excluded_uber`, `pct_excluded_lyft`, `uber_p50`, `lyft_p50`, `d50_sec`, `uber_p75`, `lyft_p75`, `uber_p90`, `lyft_p90`, `d90_sec`, `uber_p95`, `lyft_p95`, `uber_share_ge10_pct`, `lyft_share_ge10_pct`, `dshare_pts`, `support_level`
- `dashboard/data/2e_stratum_diff_summary.csv`: `min_n`, `n_strata`, `n_lyft_median_higher`, `pct_pooled_weight_lyft_median_higher`, `d50_p25_sec`, `d50_median_sec`, `d50_p75_sec`, `n_lyft_p90_higher`, `d90_median_sec`, `n_lyft_share_higher`, `dshare_median_pts`
- `dashboard/data/2e_support_by_borough.csv`: `min_n`, `pu_borough`, `n_strata`, `n_strata_common_support`, `uber_valid_total`, `lyft_valid_total`, `uber_pct_in_support`, `lyft_pct_in_support`
- `dashboard/data/2e_support_curve.csv`: `min_n`, `n_strata_with_valid`, `n_strata_common_support`, `uber_valid_total`, `uber_valid_in_support`, `uber_pct_in_support`, `lyft_valid_total`, `lyft_valid_in_support`, `lyft_pct_in_support`
- `dashboard/data/2f_fare_component_audit.csv`: `company`, `n_rows`, `n_base_fare_positive`, `pct_rows_tolls`, `pct_rows_bcf`, `pct_rows_sales_tax`, `pct_rows_congestion_surcharge`, `pct_rows_airport_fee`, `pct_rows_cbd_fee`, `pct_rows_tips`, `sales_tax_to_base_p25`, `sales_tax_to_base_p50`, `sales_tax_to_base_p75`, `bcf_to_base_p25`, `bcf_to_base_p50`, `bcf_to_base_p75`
- `dashboard/data/2f_money_filter_robustness.csv`: `metric`, `scenario`, `company`, `n`, `mean_value`, `total_value`, `p10`, `p50`, `p90`, `p99`, `n_pct_vs_S0`, `mean_value_pct_vs_S0`, `total_value_pct_vs_S0`, `p10_pct_vs_S0`, `p50_pct_vs_S0`, `p90_pct_vs_S0`, `p99_pct_vs_S0`
- `dashboard/data/2f_pay_by_borough_company.csv`: `company`, `pu_borough`, `n`, `pay_p50`, `ppm_p50`, `ppmin_p50`, `median_miles`, `median_minutes`
- `dashboard/data/2f_pay_by_daypart_company.csv`: `company`, `daypart`, `day_type`, `n`, `pay_p50`, `ppm_p50`, `ppmin_p50`, `median_miles`, `median_minutes`
- `dashboard/data/2f_pay_by_distance_band.csv`: `company`, `distance_band`, `n`, `pct_of_company`, `pay_p25`, `pay_p50`, `pay_p75`, `ppm_p50`, `ppmin_p50`, `median_miles`, `median_minutes`
- `dashboard/data/2f_pay_by_duration_band.csv`: `company`, `duration_band`, `n`, `pct_of_company`, `pay_p25`, `pay_p50`, `pay_p75`, `ppm_p50`, `ppmin_p50`, `median_miles`, `median_minutes`
- `dashboard/data/2f_pay_by_hour_company.csv`: `company`, `request_hour`, `n`, `pay_p50`, `ppm_p50`, `ppmin_p50`, `median_miles`
- `dashboard/data/2f_pay_by_wait_band.csv`: `company`, `wait_band`, `n`, `pct_of_company_valid`, `pay_p25`, `pay_p50`, `pay_p75`, `ppm_p50`, `ppmin_p50`, `median_miles`, `median_minutes`
- `dashboard/data/2f_pay_by_wait_within_distance.csv`: `company`, `distance_band`, `wait_band`, `n`, `sample_tier`, `pay_p50`, `ppm_p50`, `ppmin_p50`
- `dashboard/data/2f_pay_by_zone.csv`: `PULocationID`, `pu_borough`, `pu_zone`, `is_airport_zone`, `n`, `sample_tier`, `pct_uber`, `pay_p50`, `ppm_p50`, `ppmin_p50`, `median_miles`, `median_minutes`, `n_2_5mi`, `ppm_p50_2_5mi`, `rank_ppm_p50`
- `dashboard/data/2f_pay_by_zone_company.csv`: `company`, `PULocationID`, `pu_borough`, `pu_zone`, `n`, `sample_tier`, `pay_p50`, `ppm_p50`, `ppmin_p50`, `median_miles`
- `dashboard/data/2f_pay_distribution.csv`: `company`, `n`, `mean_pay`, `min_pay`, `p01`, `p05`, `p10`, `p25`, `p50`, `p75`, `p90`, `p95`, `p99`, `max_pay`
- `dashboard/data/2f_pay_gt_fare_by_distance_band.csv`: `company`, `distance_band`, `n`, `pct_pay_gt_fare`, `pay_to_base_fare_p50`
- `dashboard/data/2f_pay_mean_sensitivity.csv`: `company`, `n`, `mean_all`, `median`, `mean_trimmed_1_99`, `mean_positive_pay_only`, `max_pay`, `pct_of_total_pay_from_top_1pct_trips`, `pct_of_trips_in_top_1pct`
- `dashboard/data/2f_pay_to_fare_by_company.csv`: `company`, `n`, `n_pay_gt_fare`, `pct_pay_gt_fare`, `mean_ratio`, `p01`, `p05`, `p25`, `p50`, `p75`, `p95`, `p99`
- `dashboard/data/2f_ppm_distribution.csv`: `company`, `n_rows`, `n_eligible`, `n_no_ratio_zero_miles`, `mean_ppm`, `p01`, `p05`, `p10`, `p25`, `p50`, `p75`, `p90`, `p95`, `p99`, `max_ppm`
- `dashboard/data/2f_ppmin_distribution.csv`: `company`, `n_rows`, `n_eligible`, `n_no_ratio_zero_time`, `mean_ppmin`, `p01`, `p05`, `p10`, `p25`, `p50`, `p75`, `p90`, `p95`, `p99`, `max_ppmin`
- `dashboard/data/2f_ratio_denominator_diagnostics.csv`: `metric`, `company`, `denominator_bucket`, `n`, `ratio_p50`, `ratio_p99`, `ratio_max`
- `dashboard/data/2f_reconcile.csv`: `company`, `n_rows`, `n_five_borough`, `n_pay_null`, `n_pay_negative`, `n_pay_zero`, `n_pay_positive`, `n_zero_miles`, `n_zero_time`, `n_in_pay_per_mile`, `n_in_pay_per_minute`, `n_valid_wait`, `n_valid_wait_and_ppm`, `n_valid_wait_and_ppmin`, `n_fare_negative`, `n_pay_gt_fare`
- `data/stage4_model_performance.csv`: `evaluation_split`, `model`, `average_precision`, `roc_auc`, `brier_score`, `top10_long_wait_rate_pct`, `long_wait_capture_pct`
- `data/taxi_zone_lookup.csv`: `LocationID`, `Borough`, `Zone`, `service_zone`

Checkpoint copies also appeared for several Stage 2A and Stage 2F CSV files under `dashboard/data/.ipynb_checkpoints/`. Do not connect those checkpoint copies to Tableau; use canonical exports.

## 17. Portable startup instruction for future chats

When beginning a new session, attach this Markdown file and say:

“Read this entire handoff first. Treat it as the source of truth for the project context, verified findings, metric definitions, limitations, code workflow and current status. Do not restart prior analysis. We are at the final Tableau phase. Help me build the three real Tableau dashboards using the actual CSV sources and exact column names, validate displayed values, and then finalize the business memo, README, resume bullets and interview defence. Explain step by step, in plain language, give exact instructions for VS Code vs Jupyter vs Tableau, and update progress in 5% increments. Clearly label any unverified facts and do not invent values.”

---

Read the attached \*\*NYC HVFHV Project Master Handoff\*\* before responding. Treat it as the canonical project context for our business question, data scope, metric definitions, decisions, findings, SQL/Jupyter workflow, model results, limitations, and Tableau plans.

Do not restart or repeat completed analyses. We are finishing the actual Tableau dashboards, validating the workbook, and packaging the business memo, README, and resume bullets.

Guide me step by step in plain language. Tell me exactly what to open, where to paste code, and how to verify the output. Remember that SQL is written in VS Code and executed through Jupyter using DuckDB. Reuse the verified results and existing CSV outputs. Never invent values or silently fill gaps. At each 5% progress milestone, tell me how much of the project remains.

My goal is to finish a credible Data Analyst project with a real Data Science add-on, then learn to explain and defend every important decision in interviews. Prioritize completion and ownership over adding unnecessary complexity.

---
