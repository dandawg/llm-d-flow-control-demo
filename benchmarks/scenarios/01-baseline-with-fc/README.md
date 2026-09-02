# Scenario 01 — Baseline With Flow Control

## Purpose

Establishes the performance baseline with flow control **enabled**. The EPP
uses the full scheduling and flow-control pipeline: priority bands, fairness
policies, ordering policies, and the concurrency-based saturation detector.

Compare against [00-baseline-no-fc](../00-baseline-no-fc/) to quantify the
impact of flow control on throughput, latency, and error rates.

## What It Does

1. Swaps the EPP to the **FC-enabled** Helm values (`epp-values.yaml`).
2. Waits for the EPP rollout to complete.
3. Runs the **same** traffic pattern as scenario 00: a single stream at
   increasing concurrency levels (1 → 5 → 10 → 20 → 40) with synthetic
   data (512 input tokens, 256 output tokens).

No priority headers are set, so all traffic lands in the **standard** tier
(priority 0).

## How to Run

```bash
./benchmarks/scenarios/01-baseline-with-fc/run.sh
```

## How to Interpret Results

- **Throughput**: Should be similar to scenario 00 at low concurrency. At
  high concurrency, flow control may queue or shed requests, so observed
  throughput may plateau rather than collapse.
- **Latency**: Expect more predictable tail latency than scenario 00. The
  global cap of 500 in-flight requests and per-band limits prevent runaway
  queuing inside vLLM.
- **Shedding**: Check `llm_d_flow_control_shed_requests_total` — at
  concurrency 40, some requests in the standard band may be shed.
- **Error rate**: Should be lower than scenario 00 at extreme concurrency
  because flow control prevents backend overload.

## Expected Behavior

Flow control acts as a pressure valve. At low concurrency the overhead is
negligible. At high concurrency, instead of letting all requests hit the
backends (causing OOM or extreme latency), flow control queues excess
requests and sheds them if the TTL expires. The result is bounded latency
at the cost of increased shed/rejection rates.
