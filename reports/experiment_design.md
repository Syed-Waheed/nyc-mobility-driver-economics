# Experiment Design: Reducing Long Waits in NYC HVFHV Operations

## 1. Business problem

Long waits are disproportionately concentrated in a small set of pickup-zone and time-period combinations. In the January 2025 analysis, 133 robust hotspot cells represented 5.96% of valid trips but accounted for 22.07% of waits of at least 10 minutes. In the January 16–31 stability check, the same cells accounted for 22.18% of long waits and 5.80% of valid waits.

These results motivate a targeted operational pilot. They do not establish why the waits occur or prove that a particular intervention will improve service.

## 2. Hypothesis

Targeted driver positioning or additional dispatch attention during selected hotspot location/time windows will reduce the share of ride requests that are not picked up within 10 minutes, compared with normal operations.

## 3. Proposed experiment

**Intervention:** During selected hotspot windows, test an operational policy such as targeted driver staging or enhanced dispatch coverage. The exact policy should be agreed with the operations team before the pilot.

**Control:** Continue normal dispatch operations during comparable control windows.

**Experimental unit:** A pickup-zone × time-window × date block, rather than an individual trip. This is intended to reduce contamination from shared driver supply and interactions between nearby requests.

**Assignment:** Randomly assign eligible, operationally feasible blocks to treatment or control, balancing by pickup zone, day of week and time period. Where supply spillovers are substantial, use a randomized switchback schedule within the same zone/time strata.

## 4. Outcomes and guardrails

**Primary outcome:** The percentage of eligible requests not picked up within 10 minutes. Include all eligible requests in the pilot measurement, not only completed trips; define how cancellations and no-driver outcomes are handled before the experiment begins.

**Secondary outcomes:** Median and P90 time to pickup among picked-up trips, completion rate, cancellation/no-driver rate, and the long-wait rate among trips with valid wait measurements.

**Guardrails:** Recorded driver pay per trip, pay per mile, pay per minute, operational cost, driver utilization, and service outcomes in nearby areas. Monitor whether improvement in a treated zone simply shifts waits elsewhere.

## 5. Analysis plan

Estimate the treatment-versus-control difference in the primary outcome, accounting for the randomization blocks and repeated observations within zones and dates. Report the absolute percentage-point difference, relative change and a confidence interval.

Before launch, determine the minimum operationally worthwhile improvement and calculate the required sample size using baseline rates, expected cluster-level variation and the chosen randomization design. The current January trip data alone is not sufficient to claim a reliable experimental sample size without these assumptions.

## 6. Decision rule

Recommend broader rollout only if the pilot produces a meaningful and sufficiently precise improvement in the primary outcome without unacceptable deterioration in guardrail metrics. Otherwise, refine or stop the intervention and investigate the underlying operational constraint.

## 7. Limitations

The historical dataset contains recorded trip records and has known timestamp exclusions; its wait analyses are not a complete record of every customer request. The predictive model is a proof of concept trained on one month of data. It should not automatically direct live dispatch decisions without additional prospective validation.

**Recommendation:** Pilot a targeted operational intervention in selected high-priority hotspot windows, measure its causal impact through random assignment, and expand only if the evidence supports doing so.