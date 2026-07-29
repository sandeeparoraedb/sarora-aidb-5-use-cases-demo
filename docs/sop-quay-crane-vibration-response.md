---
title: "SOP: Quay Crane Vibration Alarm Response"
category: "Crane Automation -- Standard Operating Procedure"
---

## Purpose

Defines the response when a quay crane's condition-monitoring system
reports vibration or bearing-temperature readings outside normal range.

## Trigger thresholds

- **Watch**: vibration sustained above 1.5x the crane's 90-day rolling
  baseline for more than 24 hours.
- **Inspect**: vibration sustained above 2x baseline for more than 48
  hours, OR bearing temperature more than 8C above baseline for more than
  12 hours.
- **Stop and inspect immediately**: vibration above 3x baseline at any
  single reading, OR any abnormal noise reported by the operator.

## Response steps

1. Shift supervisor is notified automatically when a crane crosses the
   Watch threshold.
2. Maintenance planner reviews the crane's recent work-order history for a
   matching prior failure signature before scheduling inspection.
3. Inspection is scheduled into the next vessel-call gap where the crane
   is not required -- not mid-call unless the Stop threshold is hit.
4. Findings and any parts replaced are logged as a new work order,
   referencing any prior work orders with a matching signature.

## Related work orders

WO-4411 (crane 7, London Gateway) and WO-5207 (crane 3, Santos) are both
examples of the Watch-threshold pattern being missed until near-failure --
the basis for tightening the Inspect threshold in this revision.
