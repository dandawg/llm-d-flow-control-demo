# Scenario 03 — Intra-Tier Fairness

## Purpose

This is the **primary scenario of interest** for the client. It validates that
the round-robin fairness policy distributes capacity equitably among multiple
tenants within the same priority band, even when one tenant sends far more
traffic than the others.

## What It Does

Runs three concurrent traffic streams, all targeting the **standard** tier
(priority 0), but each identified by a different `x-llm-d-fairness-id` header:

| Stream | Fairness ID | Concurrency | Tokens (in/out) |
|--------|-------------|-------------|-----------------|
| 1 | tenant-a | 30 | 512 / 256 |
| 2 | tenant-b | 15 | 512 / 256 |
| 3 | tenant-c | 5 | 512 / 256 |

Total concurrent requests: **50** — enough to saturate the standard band's
150-slot budget across 2 vLLM replicas.

Tenant A is intentionally sending **6× more** traffic than Tenant C. Without
fairness, Tenant A would consume the majority of the band's capacity, starving
Tenant C.

## How to Run

```bash
./benchmarks/scenarios/03-intra-tier-fairness/run.sh
```

## How to Interpret Results

- **Throughput per tenant**: With fairness, all three tenants should achieve
  roughly **equal throughput** (requests completed per second) despite sending
  very different volumes of traffic.
- **Latency per tenant**: Tenant C (lowest sender) should *not* have worse
  latency than Tenant A. In a fair system, latency should be comparable
  across tenants.
- **Shedding per tenant**: If the band is saturated, shedding should be
  distributed proportionally — Tenant A (the heaviest sender) should see
  more shed requests than Tenant C.
- **Grafana**: Look at per-fairness-id panels. The round-robin policy
  alternates between fairness IDs, so in-flight request counts should be
  approximately balanced.

## Expected Behavior

The round-robin fairness policy ensures that no single tenant can monopolize
the priority band's capacity. Even though Tenant A sends 6× more traffic:

1. All three tenants get approximately equal access to the standard band.
2. Tenant A's excess requests are queued or shed.
3. Tenant C's requests flow through with minimal queuing.

**If fairness is NOT working**, Tenant A will dominate throughput and Tenant C
will experience significantly higher latency or lower completion rates.
