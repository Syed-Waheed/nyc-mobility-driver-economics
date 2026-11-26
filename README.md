# Rider Wait Time and Driver Pay in NYC Uber/Lyft Trips

> Status: Stage 1 (data audit) complete. Stages 2 to 6 (analysis, statistics, experiment design, dashboard) are not done yet, so there are no findings below. Numbers appear only after they are computed and reviewed.

## Dashboard
_Tableau Public link and screenshot: added in Stage 6._

## TL;DR
_4-5 findings with numbers and one recommendation: added in Stage 6, only from calculated results._

## Business question
Where and when do riders wait longest, how does driver pay relate to those conditions, how do Uber and Lyft differ, and what should the marketplace test first? This is observational analysis, so findings are associations, not causes.

## Data and scope
- **Source:** NYC TLC High Volume FHV trip records, file `fhvhv_tripdata_2025-01.parquet`, plus the TLC Taxi Zone Lookup. Dictionary: `data/data_dictionary_trip_records_hvfhs.pdf`.
- **Grain:** one row = one HVFHV trip record (no rider or driver identifiers).
- **Companies:** HV0003 = Uber (15,356,455 rows), HV0005 = Lyft (5,049,211 rows).
- **Row scope:** `pickup_datetime` in January 2025. This is the full file: 20,405,666 rows, 0 removed by the scope rule (D8).
- **Completed trips only:** cancelled requests are not in the data.
- **Wait metric:** request-to-pickup wait in minutes, an observed outcome and not a promised ETA (D2).

### Data quality summary (Stage 1)
| Check | Result |
|---|---|
| Duplicates (all 25 columns, and trip fingerprint) | none |
| Zone join (pickup and dropoff) | lossless, 0 unmatched |
| Flags | all five contain only Y and N |
| Nulls | only `on_scene_datetime` and `originating_base_num` (24.68%) |
| Negative waits (pickup before request) | 199,788 rows (0.979%); excluded from wait statistics only (D11) |
| Valid waits | 20,205,878 (Uber 15,235,488; Lyft 4,970,390) |
| Zero or negative fare, pay, miles or time | 23,868 rows (0.117%); flagged, not excluded (D16) |
| Rows removed globally | **0** |

How each analysis family treats rows (D14):
- **Company totals, pay level:** all 20,405,666 rows.
- **Wait statistics:** 20,205,878 valid-wait rows.
- **Zone and borough wait tables:** 20,205,118 rows (valid wait and pickup inside the five boroughs).
- **Pay per mile:** 20,403,060 rows (miles above 0). **Pay per minute:** 20,405,662 rows (time above 0).

## Approach
1. Stage 0: grain, scope and metric definitions (D1 to D9).
2. Stage 1: data audit with documented rules (D10 to D17). Raw data is never modified: `trips_raw` (all rows), `trips_scoped` (scope rule, wait seconds), `trips_clean` (flags, guarded ratios and eligibility columns, no rows removed).
3. Stage 2: DuckDB SQL analysis. Stage 3: statistics with bootstrap confidence intervals. Stage 4 (optional): predicting long waits. Stage 5: experiment design only. Stage 6: Tableau, memo, defense sheet.

Every wait table reports `n_valid` and `% excluded` next to each statistic (D12). See `DECISIONS.md` for every choice and its evidence.

## Findings
_Stage 2._

## Statistical / ML analysis
_Stages 3-4._

## Experiment design
_Stage 5 (design only, no experiment was run)._

## Limitations (running log)
- Completed trips only, so waits are likely understated where riders gave up (survivorship bias).
- Request-to-pickup wait bundles driver dispatch, driver travel and boarding delay.
- No supply, cancellation, ETA-shown or incentive data. Take rate cannot be computed: pay exceeds base fare in 13.119% of rows (Uber 15.357%, Lyft 6.313%), so fare minus pay is not read as platform margin (D4).
- TLC does not guarantee data accuracy.
- One month of data. January 2025 includes the start of the MTA congestion fee (Jan 5), so results may not generalize to other months. The fee appears on 1,184 trips picked up late on Jan 4 that ended after midnight; this is a midnight-crossing effect (D17).
- Timestamps appear to be NYC local time (the fee starts at the data clock's Jan 5 midnight). This is an inference; the dictionary text reviewed does not state a timezone.
- `on_scene_datetime` is populated for 100.00% of Uber rows but only 0.28% of Lyft rows, so it cannot support cross-company wait comparisons (D10).
- Trips requested in January but picked up after Jan 31 sit in the next monthly file and are not observed here (month-end edge effect, size not measured).
- 199,788 rows (0.979%) have pickup before request (Uber 0.788%, Lyft 1.561%). They are excluded from wait statistics only, never deleted or repaired, and kept for volume and pay (D11). The excluded rows are not random: they skew to longer trips, early-morning hours, airport drop-offs and Lyft WAV requests (37.326% excluded), so every wait table reports `n_valid` and `% excluded` (D12).
- Worst-case bounds on the excluded rows move median waits by seconds and do not change the sign of the Lyft-minus-Uber median gap. The observed p90 is the same for both companies and its bounds overlap, so no p90 difference is claimed (D11).
- Hypothesis, not proven: request timestamps are sometimes recorded later than the events they should precede, or hold a scheduled time for pre-booked rides. In the suspect Uber groups, request seconds are heavily rounded (second = 00 in 96.39% and 99.97%). The data cannot confirm the cause. Lyft's rounding pattern has not been recorded yet.
- 58,321 Uber rows have on_scene before request but a non-negative wait. They stay in wait statistics; removing them leaves Uber's median (3.800 min) and p90 (8.033 min) unchanged (D12).
- Shared-ride comparisons are Uber-only: no Lyft row has `shared_request_flag = Y` (D13). 424 Lyft rows have `shared_match_flag = Y` without a request; they are kept as-is and their cause is unexplained (D17).
- 774 pickups outside the five boroughs (EWR and "Outside of NYC") stay in company-level results but are left out of zone and borough wait tables (D15).
- Lyft has 13,945 zero-fare rows (0.276% of Lyft rows); they are excluded only from the descriptive pay-to-fare ratio.
- The sensitivity test of money-flagged rows covers p10, p50 and p90 only (D16).

## How to reproduce
_Final instructions in Stage 6. Current pipeline:_
1. Download the TLC HVFHV Parquet for January 2025, the Taxi Zone Lookup CSV and the HVFHS data dictionary from the TLC Trip Record Data page (https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page) into `data/`.
2. Run the SQL in `sql/` in order from the notebooks: `00_setup`, `01_scope`, `01_audit_*`, `01_clean`, `01_clean_sensitivity`. Each file holds named blocks (`-- name:`); blocks starting with `create_` build views.
3. Notebooks `00` to `04` in `notebooks/` run the stages and print the tables that DECISIONS.md cites.