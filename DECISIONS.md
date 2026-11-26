# DECISIONS.md

Every methodological choice, in one format: **Decision / Reason / Alternative considered / Why rejected / Impact.**
Status: **LOCKED** = defined or backed by evidence. **PENDING** = waiting on an audit result.

---

## D1: Raw grain (LOCKED, Stage 0)
- **Decision:** One row in the raw file = one HVFHV trip record.
- **Reason:** The schema has no rider_id, driver_id or request_id.
- **Alternative considered:** Treat rows as riders or request cohorts.
- **Why rejected:** The data cannot identify repeat riders or drivers.
- **Impact:** No retention, per-driver utilization or per-rider metrics anywhere in this project.

## D2: Wait metric (LOCKED, Stage 0; on_scene evidence added in Stage 1, see D10)
- **Decision:** `wait_minutes = (pickup_datetime - request_datetime)` in minutes. Named "request-to-pickup wait" (observed), never "ETA".
- **Reason:** It is the only wait definition available for every row.
- **Alternative considered:** `on_scene_datetime - request_datetime` (driver arrival).
- **Why rejected:** on_scene_datetime is null for 5,035,135 of 20,405,666 rows, and the nulls are company-specific (D10): populated for 100.00% of Uber rows but 0.28% of Lyft rows.
- **Impact:** The metric bundles driver dispatch, driver travel to pickup and any boarding delay. It cannot separate them for all rows.

## D3: Pay metrics (LOCKED, Stage 0)
- **Decision:** `driver_pay`, `pay_per_mile = driver_pay / NULLIF(trip_miles, 0)`, `pay_per_minute = driver_pay / NULLIF(trip_time / 60.0, 0)`.
- **Reason:** Zero miles or zero trip_time exist in the data (min = 0 for both), so division must be explicit.
- **Alternative considered:** Add a small epsilon to the denominator.
- **Why rejected:** It manufactures huge fake ratios.
- **Impact:** Ratio metrics are computed on rows with a non-zero denominator. Always report how many rows were excluded. Stage 1C evidence: zero miles are 0.016% of Uber and 0.004% of Lyft rows, and the maxima of pay per mile and pay per minute are denominator artifacts, so ratio results use percentiles (never the maximum, never a mean of ratios). Decided in 1E (D14): rows with negative or zero pay stay in ratio statistics; only zero-denominator rows have no ratio (NULLIF). The non-null counts are asserted in `final_reconciliation`.

## D4: Take rate (LOCKED as "not defined", Stage 0)
- **Decision:** No "take rate" or "platform revenue" metric.
- **Reason:** `base_passenger_fare` excludes tolls, tips, taxes and fees, and `driver_pay` is described as net of commission, surcharges or taxes. The dictionary does not say what the gap between them contains. No cost or incentive fields exist.
- **Alternative considered:** `(base_passenger_fare - driver_pay) / base_passenger_fare` called take rate.
- **Why rejected:** The accounting is unverified, so the label would be an unsupported claim.
- **Impact:** At most a descriptive "driver_pay / base_passenger_fare" ratio, reviewed in Stage 1 after the fare audit and named as exactly that. Stage 1C evidence: driver_pay exceeds base_passenger_fare in 15.357% of Uber rows and 6.313% of Lyft rows, and the median ratio is about 0.733 (Uber) and 0.749 (Lyft). Pay above base fare is not automatically an error, since base fare is only one fare component, but it confirms that fare minus pay cannot be read as platform margin. D4 stands.

## D5: "Where" (LOCKED, Stage 0)
- **Decision:** Pickup zone (`PULocationID`), rolled up to borough via LEFT JOIN to the zone lookup. Unmatched IDs are audited, not assumed.
- **Reason:** Waiting happens at pickup.
- **Alternative considered:** Drop-off zone.
- **Why rejected:** It describes where trips end, not where riders wait.
- **Impact:** DOLocationID is used only for trip characteristics.

## D6: "When" (LOCKED, Stage 0)
- **Decision:** Hour (0-23) and weekday of `request_datetime`.
- **Reason:** Demand appears at request time, and request-time features keep a later model free of leakage.
- **Alternative considered:** Hour of pickup_datetime.
- **Why rejected:** Pickup time already contains the outcome (a longer wait pushes pickup later).
- **Impact:** All time buckets key off request time.

## D7: Summary statistics (LOCKED, Stage 0)
- **Decision:** Medians and percentiles (p75/p90/p95/p99), not means. Bootstrap CIs in Stage 3.
- **Reason:** Wait and pay are expected to be right-skewed (to be confirmed with the Stage 2 histogram).
- **Alternative considered:** Means with standard errors.
- **Why rejected:** A few extreme trips would dominate.
- **Impact:** Means may still be shown, but only beside the median.

## D8: Scope of rows (LOCKED, Stage 1)
- **Decision:** Keep trips with `pickup_datetime` in [2025-01-01, 2025-02-01). Implemented as an explicit filter in view `trips_scoped` (`sql/01_scope.sql`).
- **Evidence:** min pickup = 2025-01-01 00:00:00 and max pickup = 2025-01-31 23:59:59. In the request/pickup/dropoff month cross-tab, pickup month is 2025-01 for all 20,405,666 rows (20,393,027 + 11,470 + 1,164 + 5). So the file is cut by pickup date, not request date.
- **Alternative considered:** (B) request_datetime in Jan 2025; (A) full file with no explicit rule.
- **Why rejected:** (B) would drop 1,169 rows (1,164 requested Dec 31, 5 with request timestamps in February) based on the request column, whose ordering versus pickup is itself under investigation (D11). (A) gives the same rows today but leaves the rule undocumented.
- **Impact:** Expected 0 rows removed (reconfirmed by `scope_reconcile`). 11,475 trips end in February but are kept because pickup defines membership. Trips requested in January but picked up after Jan 31 are in the next monthly file and not observed here (month-end edge effect, size not measured). Stage 1B: the 1,164 requests made on Dec 31 are all non-negative waits (median Uber 4.7 min, Lyft 5.2 min) and are kept.

## D9: Tooling (LOCKED, Stage 0)
- **Decision:** DuckDB reads the Parquet directly. SQL lives in `sql/*.sql` and runs from Jupyter. Only small aggregated results go to pandas.
- **Reason:** About 20 million rows on a MacBook M2 that overheats.
- **Alternative considered:** Load into pandas, or install a separate SQL database.
- **Why rejected:** Memory/heat risk, and extra setup with no analytical gain.
- **Impact:** Raw data is never modified; cleaning happens in views.

## D10: on_scene_datetime availability (LOCKED as "not a cross-company metric", Stage 1)
- **Evidence:** HV0003 (Uber) 15,356,455 of 15,356,455 rows populated (100.00%). HV0005 (Lyft) 14,076 of 5,049,211 (0.28%). By wav_match_flag: N 76.36% populated, Y 64.97% populated. The WAV table mixes companies, so it cannot isolate a WAV effect.
- **Decision:** Do not use on_scene_datetime for any Uber vs Lyft or all-company wait metric. Treat it as a company-specific availability issue, not a WAV-only field.
- **Alternative considered:** Use request-to-on_scene as the main wait; assume missing means WAV-only.
- **Why rejected:** It would compare about 100% of Uber rows with about 0.3% of Lyft rows, and the "WAV-only" explanation does not match the observed counts.
- **Impact:** Primary wait stays request-to-pickup (D2). An optional Uber-only decomposition (request to on_scene, on_scene to pickup) may be added later, labelled Uber-only, after the timestamp-order checks. What the 14,076 Lyft rows are is checked by `lyft_onscene_profile` in `sql/01_audit_timestamps.sql`.

## D11: Pickup-before-request rows (LOCKED, Stage 1)
- **Decision (rule R1):** `is_wait_valid = (wait_seconds >= 0)`. Rows with wait_seconds < 0 are excluded from wait statistics only (wait medians and percentiles, wait hotspots, Stage 4 wait targets). Raw rows are never deleted, and timestamps are never repaired. The same rule applies to Uber and Lyft. Zero waits stay valid (about 0.001% of rows, Stage 1B).
- **Rows affected:** 199,788 of 20,405,666 (0.979%). Uber 120,967 of 15,356,455 (0.788%); Lyft 78,821 of 5,049,211 (1.561%). Rows left for wait statistics: 20,205,878 (Uber 15,235,488; Lyft 4,970,390, by subtraction), before any 1B cleaning.
- **Evidence (confirmed outputs):**
  - Gap size: under 1 min 36,021; 1 to 10 min 98,114; 10 to 60 min 65,649; 60 min or more 4. About 82% are 1 minute or more, so this is not just rounding noise.
  - Uber ordering of request / on_scene / pickup: A normal 15,176,848 (98.830%); B on_scene before request with non-negative wait 58,321 (0.380%); C negative, on_scene <= pickup < request 111,313 (0.725%); D negative, pickup < on_scene <= request 9,387 (0.061%); E negative, pickup < request < on_scene 267 (0.002%); F on_scene after pickup with non-negative wait 319 (0.002%).
  - Uber rows with on_scene before request, by how far: negative-wait rows 665 (under 1 min, median wait -19 s), 45,712 (1 to 10 min, -228 s), 74,323 (10 to 60 min, -758 s). Non-negative rows 2,871 (under 1 min, median 106 s), 30,276 (1 to 10 min, 181 s), 25,155 (10 to 60 min, 206 s), 19 (60 min or more, 1,881 s).
  - By flags: Uber negative rates range 0.557% to 1.831% across flag combinations; Lyft 1.429% to 37.326%. WAV-requested trips: Uber 679 of 37,074 (1.831%), Lyft 5,254 of 14,076 (37.326%). The pooled 11.599% for wav_request_flag = Y is driven by Lyft.
  - By hour (examples reported by the analyst): 04:00 Uber 3.872%, Lyft 5.026%; 05:00 3.200%, 5.584%; 06:00 2.220%, 3.529%; 18:00 0.251%, 0.578%; 22:00 0.127%, 0.233%.
  - By zone: the top five pickup zones by negative count hold 15,089 negatives (7.6% of all), with in-zone rates 1.050% to 1.888%. These show where invalid timestamps sit. They are not wait hotspots.
  - Pickup vs dropoff vs trip_time: exact match for 99.90% (Uber negative), 99.94% (Uber non-negative), 100.00% (Lyft, both groups).
  - Trip profile (medians, negative vs non-negative): Uber miles 9.190 vs 2.860, trip time 27.7 vs 15.0 min, base fare $40.58 vs $18.12, driver pay $32.83 vs $14.08. Lyft miles 5.814 vs 2.673, trip time 23.7 vs 14.85 min, base fare $29.38 vs $17.38, driver pay $25.07 vs $13.21.
- **Interpretation (hypotheses, not proven):**
  - H1 (evidence-supported): request_datetime is sometimes recorded later than events that should follow it. For 92.0% of Uber negative rows (111,313 of 120,967), on_scene and pickup both precede the recorded request, and Lyft shows negatives (1.561%) although almost none of its rows have an on_scene field.
  - H2 (competing hypothesis; partly consistent with Stage 1B evidence, not proven): for some pre-booked rides, request_datetime may hold a scheduled time. This fits longer trips, early-morning concentration, and drivers on scene 10 to 60 minutes before the recorded request. It would also make some non-negative waits (pattern B) not true rider waits. Tests: `request_second_pattern`, `negative_airport_profile` in `sql/01_audit_waits.sql`. Stage 1B results: among Uber rows with on_scene before request, request second = 00 in 96.39% of the 120,700 negative rows and 99.97% of the 58,321 non-negative rows, with 5-minute marks in 94.32% and 93.19%. If request seconds were arbitrary, about 1.7% would be second = 00. Airport drop-offs: Uber negative rows 32.84% vs 3.98% for non-negative rows; Lyft 25.29% vs 4.08%. These match what H2 predicts but are associations and do not prove a cause. Lyft's rounding pattern is not recorded yet.
  - Caution: the near-perfect pickup/dropoff/trip_time agreement is weak evidence. trip_time is likely derived from the same timestamps, so agreement is expected. It rules out independent pickup or dropoff errors but cannot show that pickup is correct in the real world.
- **Sensitivity (as run, minutes; excluded rows set to the lowest / highest possible wait):**
  - Uber median 3.800 (3.783 to 3.817); p90 8.033 (8.017 to 8.267).
  - Lyft median 4.083 (4.033 to 4.117); p90 8.033 (8.000 to 8.433).
  - Median gap, Lyft minus Uber: 0.283 observed, 0.216 to 0.334 across worst cases, positive in every case. So the sign of the median gap does not depend on this exclusion.
  - p90 gap: 0.000 observed, -0.267 to +0.416 across worst cases. A p90 difference between companies cannot be claimed from this data. The upper bound moves much more than the lower bound because p90 sits in a thin right tail, so a few very long true waits would shift it more than a few very short ones.
  - Scope of the check: it bounds only the excluded rows, not pattern B (see `uber_b_sensitivity`).
- **Why the rows stay available for volume and pay:** the trips are populated and plausible, and removing them would bias volume and pay toward shorter, cheaper trips, because they are systematically longer and higher-fare. They are not "ordinary" trips, but their wait timestamp is the unreliable part. Use for pay and volume is conditional on the Stage 1C audit.
- **Alternatives considered and why rejected:**
  - Drop the rows: loses valid volume and pay information and biases toward short trips.
  - Keep as-is: negative waits are impossible values and distort means and percentiles.
  - Recode negative waits to 0: invents a value.
  - Repair the timestamps: no basis to know the true request time.
  - Also exclude Uber rows with any on_scene order violation: asymmetric, because Lyft has on_scene for only 0.28% of rows, which would break Uber vs Lyft comparability.
- **Disclosure:** wait statistics exclude 1.561% of Lyft rows vs 0.788% of Uber rows, and the excluded rows are not random (D12).

## D12: Reporting rules for wait statistics (LOCKED, Stage 1)
- **Decision:** every wait table reports `n_valid` and `% excluded` next to each median and percentile. For zone x hour x weekday cells, a minimum number of valid rows is set in Stage 2 from the actual cell-size distribution.
- **Reason:** exclusion is not random. It is higher in early-morning hours, in longer trips, and for Lyft WAV-requested trips (37.326% excluded, so only 8,822 of 14,076 rows keep a valid wait).
- **Rules that follow:**
  - Lyft WAV-request wait statistics are shown only with their exclusion share and are not a headline comparison.
  - Negative-wait rates by hour or zone are data-quality diagnostics, never business wait hotspots.
  - Uber pattern B rows (58,321; 0.380% of Uber) stay in wait statistics (rule stays symmetric) and are listed as a limitation, with the bound from `uber_b_sensitivity`. Stage 1B check: removing them leaves Uber median 3.800 min and p90 8.033 min unchanged, and treating them as the highest possible wait moves p90 to about 8.15 min. They are documented but do not drive the headline metrics.
- **Alternative considered:** report only the headline median and percentiles. **Why rejected:** hides the selection effect.

## D13: Flag semantics for Stage 2 (LOCKED, Stage 1)
- **Evidence:** all 837,272 shared-request rows are Uber (771,581 + 65,691). Every Lyft row has shared_request_flag = N. WAV requests: 37,074 Uber + 14,076 Lyft = 51,150. WAV matched without a request: 1,153,806 Uber + 649,557 Lyft = 1,803,363. Lyft's on_scene_datetime is present on exactly its 14,076 WAV-requested rows.
- **Decision:** the shared-ride comparison (Stage 2F) is Uber-only: shared vs non-shared within Uber, never Uber vs Lyft. WAV analysis (Stage 2G) is keyed on wav_request_flag (demand for an accessible vehicle). WAV matched without a request is a separate group and is not called a WAV request.
- **Alternative considered:** use wav_match_flag as the WAV group. **Why rejected:** about 97% of matched-WAV rows were never requested as WAV.
- **Impact:** shapes the Stage 2F and 2G tables and what the README may claim. Stage 1D: 424 Lyft rows have shared_match_flag = Y with shared_request_flag = N (Uber 0). They are kept as-is; shared groups are defined within Uber only, and shared_match_flag is never used without a company filter (D17).

## D14: Analysis-family eligibility and global retention (LOCKED, Stage 1E)
- **Decision:** no row is removed globally. All 20,405,666 rows stay in `trips_clean`. Each analysis family follows one of three kinds of rule: global retention (all rows), metric-specific exclusion (the metric cannot exist for the row, the geography cannot be assigned, or D11), or flag-only (never excluded).
- **Final rules and row counts** (Stage 1E run; "derived" counts come from the overlap table and are asserted by `final_reconciliation`):

| Family | Rule | Rows | Not in family | Kind |
|---|---|---|---|---|
| F1 volume, company totals | all rows | 20,405,666 | 0 | global retention |
| F2 wait statistics | `is_wait_valid` (D11) | 20,205,878 (Uber 15,235,488; Lyft 4,970,390) | 199,788 | metric-specific |
| F3 zone and borough wait tables | valid wait and pickup in the five boroughs (`in_geo_wait_tables`) | 20,205,118 (Uber 15,234,971; Lyft 4,970,147, derived) | 200,548 (199,788 + 760) | metric-specific and scope (D15) |
| F4 pay level | all rows | 20,405,666 | 0 | global retention |
| F5 pay per mile | `trip_miles > 0` (`in_pay_per_mile`) | 20,403,060 | 2,606 (Uber 2,398; Lyft 208) | denominator guard |
| F6 pay per minute | `trip_time > 0` (`in_pay_per_minute`) | 20,405,662 | 4 (all Uber) | denominator guard |
| F7 wait x pay joint | valid wait plus the pay metric's own guard | pay level 20,205,878; per mile 20,203,530 (derived); per minute 20,205,875 (derived) | as above | metric-specific |
| Descriptive pay-to-fare ratio (D4) | `base_passenger_fare > 0` and `driver_pay >= 0` | 20,388,149 (derived) | 17,517 | denominator guard |

- **Flag-only, never excluded anywhere:** pay above base fare (2,677,072 rows; Uber 15.3572%, Lyft 6.3128%); Uber on_scene before request (179,021; 1.1658% of Uber, kept in wait statistics with the D12 disclosure); the 424 Lyft shared-flag rows; the 2 rows with implied speed of 100 mph or more; negative fare (2,427), zero fare (14,777; Lyft 13,945), negative pay (313) and zero pay (4,225) rows for every family except where the metric itself needs a positive denominator.
- **View versions:** `trips_clean` v1 held flags and guarded ratios. v2 adds three eligibility columns (`in_geo_wait_tables`, `in_pay_per_mile`, `in_pay_per_minute`) that only name the rules above, so every Stage 2 query uses the same filters. v2 adds no rule and removes no rows.
- **Alternatives considered:** excluding the 23,868 money-flagged rows from all pay metrics (rejected by D16); dropping unusual rows (speed, pay above fare) because they look odd (rejected: no evidence they are errors).
- **Reading the waterfall:** the label `0_no_candidate_rule_matched` (20,181,669 rows) means none of the five candidate cleaning rules matched. Informational flags can still be set on those rows.

## D15: Pickups outside the five boroughs (LOCKED, Stage 1E)
- **Evidence:** 774 pickups are in zones 1 (EWR, 1 row) and 265 (Outside of NYC, 773 rows): Uber 529, Lyft 245; 760 have a valid wait (Uber 517, Lyft 243). Company-level valid-wait median and p90 are unchanged with and without them (Uber 3.800 and 8.033 min; Lyft 4.083 and 8.033 min). Their own medians are higher (Uber 6.650, Lyft 6.033 min), on small counts.
- **Decision:** keep them in volume, company-level wait statistics and pay analyses. Exclude them only from zone and borough wait tables (F3), because they cannot be assigned to a borough hotspot.
- **Alternative considered:** drop them globally. **Why rejected:** they are valid trips with valid fields, and removing them changes nothing at company level.
- **Impact:** F3 has 760 fewer rows than F2. Dropoffs outside NYC (815,255; 3.995% of dropoffs) are unaffected because "where" is pickup-based.

## D16: Money-field anomalies are flag-only (LOCKED, Stage 1E)
- **Evidence:** 23,868 rows (0.117%; Uber 9,681 = 0.0630%, Lyft 14,187 = 0.2810%) have zero miles, zero time, fare at or below zero, or pay at or below zero. Only base_passenger_fare and driver_pay ever go negative (the other fee fields have a minimum of 0), so these are not whole-trip reversals.
- **Pre-registered test:** a flag becomes an exclusion for a metric only if the metric cannot exist for the row, or dropping flagged rows moves p10, p50 or p90 by 1% or more.
- **Result:** across pay, pay per mile and pay per minute, for both companies, p10/p50/p90 change by at most 0.132% (largest: Uber pay per minute p10, 0.758 to 0.759, a rounding-level change). Most changes are 0.000% to 0.071%.
- **Decision:** no money-field exclusion. Only the denominator guards in D14 apply.
- **Limits of the test:** it covers p10, p50 and p90 only. Means, maxima and extreme tails were not tested, so Stage 2 reports percentiles and never a mean of ratios or a maximum. The flagged set is small, so quantiles cannot move far by construction; the test confirms rather than discovers.

## D17: Stage 1D integrity findings, no row action (LOCKED, Stage 1D)
- **Duplicates:** none. 20,405,666 distinct hashes on all 25 columns and on the trip fingerprint.
- **Zone lookup and joins:** 265 unique IDs (1 to 265); special rows 1 (EWR, Newark Airport), 264 (Unknown), 265 (Outside of NYC). The join is lossless (20,405,666 to 20,405,666) with 0 unmatched pickups or dropoffs. Zone 264 has no trips.
- **Flags:** all five flags contain only Y and N. `wav_requested_not_matched` is 0.
- **Lyft shared exception:** 424 Lyft rows (0.0084% of Lyft) have shared_match = Y and shared_request = N; Uber has 0. All have dispatching base B03406, as does every Lyft row. They are spread over the month but the daily rate rises about 4x from Jan 19 (100 rows on Jan 1 to 18, 324 on Jan 19 to 31). None has a negative wait. Cause unexplained. Kept as-is, not relabeled.
- **CBD congestion fee:** 1,184 fee-positive rows have pickup before Jan 5. All are Uber at $1.50, picked up on Jan 4 (22:00: 5 rows, 23:00: 1,179 rows) and dropped off on or after Jan 5. None of 661,475 Jan 4 trips ending before Jan 5 has the fee. This is a midnight-crossing effect, not a contradiction of the Jan 5 start, and it indicates the timestamps are in NYC local time (inference). Rows kept and not recoded.
- **Nulls:** only on_scene_datetime and originating_base_num (24.68% each). Base-number fields are not used by any business question.

## Stage 1 audit log (evidence; decisions are D1 to D17)
- **1A timestamps:** scope is pickup in January 2025 (D8): 20,405,666 rows. 199,788 negative waits (0.979%); Uber 120,967, Lyft 78,821. Uber ordering: 98.830% normal; 58,321 on_scene before request with non-negative wait; 111,313 + 9,387 + 267 negative; 319 on_scene after pickup with non-negative wait. Request timestamps in the suspect Uber groups are heavily rounded (second = 00 in 96.39% and 99.97%; 5-minute marks 94.32% and 93.19%). Negative-wait rows skew to airport drop-offs (Uber 32.84% vs 3.98%; Lyft 25.29% vs 4.08%). Cause unproven (D11).
- **1B waits:** valid waits 20,205,878. Uber mean 4.556, median 3.800, p75 5.517, p90 8.033, p95 10.217, p99 15.783 min. Lyft mean 4.691, median 4.083, p75 5.767, p90 8.033, p95 9.867, p99 14.533 min. Median gap about 17 s; identical p90, so no p90 difference is claimed. Zero waits about 0.001%. The 1,164 Dec 31 requests are all non-negative (median Uber 4.7, Lyft 5.2 min) and are kept.
- **1C money:** zero miles Uber 0.016%, Lyft 0.004%; negative fare 0.016% and 0.001%; zero fare 0.005% and 0.276%; negative pay 0.002% and 0; zero pay 0.028% and 0; pay above base fare 15.357% and 6.313%. Median pay-to-fare ratio about 0.733 (Uber), 0.749 (Lyft). Implied speed mostly 5 to 30 mph.
- **1D integrity:** see D17.
- **1E rules waterfall (each row counted once under the first rule it hits):** 20,181,669 no candidate rule matched; 199,788 negative wait; 760 pickup outside NYC; 2,347 zero miles or time; 17,157 fare zero or negative; 3,945 pay zero or negative. Total 20,405,666. 223,997 rows hit at least one candidate rule (1.098%); none is removed. Largest overlaps: 199,359 negative wait only; 14,749 zero fare only; 3,640 zero pay only; 2,408 negative fare only; 1,912 zero miles only; 415 rows combine a negative wait with a money flag.
- **Stage 1 status:** complete. Global removals: 0 rows. Remaining check: the `final_reconciliation` query must return the expected values listed in `sql/01_clean.sql`. Open, non-blocking: Lyft's request-second rounding pattern is not recorded yet, and the hour-of-day volume curve was not reviewed.