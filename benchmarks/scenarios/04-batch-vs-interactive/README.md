# Scenario 04 — Batch vs. Interactive

## Purpose

Validates that interactive (online) traffic is protected when a large batch
job is running concurrently. The batch API submits hundreds of requests via
`/v1/batches`, while interactive chat traffic flows through the standard tier.
Flow control should ensure that the batch workload does not degrade interactive
latency.

## What It Does

Runs **two workloads in parallel**:

1. **Interactive traffic** via the orchestrator: a single stream at standard
   priority, concurrency 15, simulating real-time user-facing requests.
2. **Batch job** via `submit-batch-job.sh`: 500 chat completion requests
   submitted through the `/v1/batches` API.

The batch job routes through the **batch-sheddable** tier (priority -1), while
interactive traffic uses the **standard** tier (priority 0).

## How to Run

```bash
./benchmarks/scenarios/04-batch-vs-interactive/run.sh
```

## How to Interpret Results

- **Interactive latency**: Should remain stable and comparable to the
  baseline (scenario 01 at concurrency 15). If interactive latency
  degrades significantly, the batch workload is leaking into the
  interactive band.
- **Batch completion time**: The batch job will take longer than if it ran
  alone, because it is in the lowest priority band and may be shed under
  pressure. This is expected — batch work should yield to interactive.
- **Shedding**: Expect shedding in the batch-sheddable band while
  interactive traffic is flowing. Once interactive traffic subsides, the
  batch job should accelerate.
- **Grafana**: Compare the `llm_d_flow_control_inflight_requests` panel
  for both priority bands to see how capacity is distributed.

## Expected Behavior

Flow control protects interactive traffic by giving it priority over the
batch workload. The batch job completes eventually, but yields capacity
to interactive requests whenever the system approaches saturation. Without
flow control, the batch job's 500 requests would compete equally with
interactive traffic, degrading user-facing latency.
