# Scenario 00 — Baseline Without Flow Control

## Purpose

Establishes the performance baseline with flow control **disabled**. The EPP
uses only the scheduling scorers (queue-scorer, kv-cache-utilization-scorer)
with no priority bands, fairness policies, or request shedding.

Compare the results from this scenario against
[01-baseline-with-fc](../01-baseline-with-fc/) to measure the overhead (or
benefit) of enabling flow control.

## What It Does

1. Swaps the EPP to the **no-FC** Helm values (`epp-values-no-fc.yaml`).
2. Waits for the EPP rollout to complete.
3. Runs a single traffic stream at increasing concurrency levels
   (1 → 5 → 10 → 20 → 40) using synthetic data (512 input tokens,
   256 output tokens).

## How to Run

```bash
./benchmarks/scenarios/00-baseline-no-fc/run.sh
```

## How to Interpret Results

- **Throughput (req/s)**: Should increase roughly linearly with concurrency
  until the backends saturate.
- **Latency (TTFT, e2e)**: Expect gradual increases as concurrency rises.
  Without flow control, there is no shedding — all requests are accepted,
  so latency may spike sharply at high concurrency.
- **Error rate**: At extreme concurrency the backends may OOM or timeout.
  Note where errors start — flow control should prevent this.

## Expected Behavior

Without flow control, the system processes all incoming requests on a
best-effort basis. At low concurrency, performance should be comparable to the
flow-control-enabled baseline. At high concurrency, expect higher tail latency
and potential errors since there is no mechanism to shed or queue excess load.
