# GLOSSARY.md

Only terms learned during this project. After each teach-back, add **your own-words** version.

| Term | Plain meaning | Where it shows up | Your own words |
|---|---|---|---|
| Grain | What one row represents. Here: one HVFHV trip record. | Every table, every join | _fill after Stage 0 teach-back_ |
| Request-to-pickup wait | pickup_datetime minus request_datetime, in minutes. An observed outcome, not a promised ETA. | Stage 0 onward | |
| Percentile (p90) | The value 90% of trips are at or below. Shows the bad tail that a median hides. | Stage 2 | |
| Survivorship bias | Only completed trips are in the data, so riders who gave up are invisible and waits are likely understated. | Limitations | |
| Take rate | Platform's share of what a rider pays. Not computable here (see D4). | Limitations | |
| Data contract | Written agreement on grain, scope, metric definitions and what the data cannot answer. | Stage 0 | |
| Sensitivity analysis | Re-running a result with and without a debatable choice to see whether the answer moves. | D11, D16 | |
| Worst-case bound | The most a result could change if the unknown rows took the lowest or highest possible value. | D11 | |
| Selection effect | When excluded rows are not a random sample, so the remaining rows differ from the whole. | D12 | |
| Denominator guard | Making a ratio NULL when its denominator is zero (NULLIF) instead of dividing by zero. | D3, D14 | |
| Flag vs exclusion | A flag labels a row but keeps it; a metric-specific exclusion drops it from one metric; a global removal deletes it everywhere (none here). | D14 | |
| Midnight-crossing trip | A trip that starts before a date boundary and ends after it; why 1,184 trips carried the congestion fee before Jan 5. | D17 | |
| Hash-based duplicate check | Compress each row into one number to find duplicates cheaply, then confirm on the real columns. | Stage 1D | |