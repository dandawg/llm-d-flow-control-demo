# llm-d Flow Control — Standalone Benchmark Guide

This guide provides everything you need to reproduce the flow-control benchmark
scenarios against your own llm-d deployment. It is completely self-contained —
no scripts, Makefiles, or config files from the demo repository are required.
Copy the EPP configurations and `aiperf` commands below, adapt the placeholders
to your environment, and run.

## Benchmark Overview

The guide walks through four scenarios, each building on the last:

| # | Scenario | What It Proves |
|---|----------|---------------|
| 00 | **Baseline Without Flow Control** | Establishes raw performance numbers — throughput, latency, and error rates at increasing concurrency with no protection. This is the control group. |
| 01 | **Baseline With Flow Control** | Repeats the same concurrency sweep with flow control enabled but no priority headers. At low concurrency FC is idle — comparing to Scenario 00 shows the overhead is negligible. At high concurrency FC may start queuing or shedding, demonstrating its protective effect. |
| 02 | **Priority Tiers** | Sends traffic at three different priority levels simultaneously. Shows that high-priority (realtime) requests stay fast while low-priority traffic absorbs shedding. |
| 03 | **Intra-Tier Fairness** | Three tenants share the same priority band but send wildly different volumes (6:3:1 ratio). Shows that the round-robin fairness policy gives each tenant equal throughput. |

Scenarios 00 and 01 are an A/B pair — run them back-to-back and compare.
Scenarios 02 and 03 demonstrate specific flow-control features under
saturation.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Tuning for Your Environment](#2-tuning-for-your-environment)
3. [EPP Configurations](#3-epp-configurations)
4. [Scenario 00 — Baseline Without Flow Control](#scenario-00--baseline-without-flow-control)
5. [Scenario 01 — Baseline With Flow Control](#scenario-01--baseline-with-flow-control)
6. [Scenario 02 — Priority Tiers](#scenario-02--priority-tiers)
7. [Scenario 03 — Intra-Tier Fairness](#scenario-03--intra-tier-fairness)
8. [Reading the Results](#reading-the-results)

---

## 1. Prerequisites

### Tools

- **aiperf** — the benchmarking CLI for OpenAI-compatible inference endpoints.

  ```bash
  pip install aiperf
  ```

- **helm** — for deploying or updating the EPP configuration (if using the
  llm-d Helm chart). If you manage configs through GitOps, extract the
  `EndpointPickerConfig` YAML from Section 3 and apply it through your
  pipeline instead.

- **kubectl** — with access to the cluster where llm-d is deployed.

### Environment Variables

Set these two variables before running any commands. Every `aiperf` invocation
in this guide references them.

```bash
export MODEL_NAME="gpt-oss-20b"          # your model name
export GATEWAY_URL="http://<gateway-ip>" # HTTP endpoint of the inference gateway
```

To discover the gateway IP from a Gateway API resource:

```bash
GATEWAY_IP=$(kubectl get gateway <gateway-name> \
  -n <gateway-namespace> \
  -o jsonpath='{.status.addresses[0].value}')
export GATEWAY_URL="http://${GATEWAY_IP}"
```

---

## 2. Tuning for Your Environment

The EPP configuration in Section 3 was originally sized for a 2-replica
Nemotron-9B deployment on A10G GPUs. You will need to adjust several values
to match your model, hardware, and scale.

| Parameter | Original Value | What It Controls | How to Adjust |
|-----------|---------------|-----------------|---------------|
| `maxConcurrency` | `15` | Per-backend request threshold that triggers the saturation detector. When any backend exceeds this, flow control begins queuing/shedding. | Profile your model under load. Set this to the concurrency level where a single replica starts to degrade (latency spikes, OOM risk). Larger models on faster GPUs may support higher values. |
| `maxRequests` (global) | `500` | Total in-flight request cap across all priority bands. | Scale roughly with your replica count. More replicas = higher global cap. |
| `maxRequests` (per band) | `200` / `150` / `50` | Per-band budgets that carve up the global cap. | Adjust proportions based on your traffic mix. The numbers must sum to <= the global cap. |
| `defaultRequestTTL` | `60s` | How long a queued request waits before being shed. | Shorter TTL = faster shedding under pressure (better for latency-sensitive traffic). Longer TTL = more requests eventually served (better for throughput). |

**aiperf concurrency values** in the commands below were chosen to push a
2-replica deployment into saturation. Scale these up or down so that the total
concurrent requests across all streams is enough to saturate your cluster. A
good rule of thumb: total concurrency should be 2-3x what your cluster can
sustain at acceptable latency.

---

## 3. EPP Configurations

There are only two EPP configurations across all four scenarios. Apply the
relevant one by updating your EPP's `pluginsCustomConfig` (in Helm values,
GitOps manifests, or however you manage the EPP deployment), then restart or
roll out the EPP pods.

### Config A — Flow Control Disabled

Used by **Scenario 00** only. Only the two scheduling scorers are active. There
is no flow control feature gate, no saturation detector, no priority bands, and
no fairness or ordering policies.

```yaml
apiVersion: llm-d.ai/v1alpha1
kind: EndpointPickerConfig
plugins:
- type: queue-scorer
- type: kv-cache-utilization-scorer
schedulingProfiles:
- name: default
  plugins:
  - pluginRef: queue-scorer
    weight: 2
  - pluginRef: kv-cache-utilization-scorer
    weight: 2
```

### Config B — Flow Control Enabled

Used by **Scenarios 01, 02, and 03**. Enables the full flow-control pipeline
with three priority bands, round-robin fairness, FCFS ordering, and a
concurrency-based saturation detector.

```yaml
apiVersion: llm-d.ai/v1alpha1
kind: EndpointPickerConfig
featureGates:
- flowControl
plugins:
- type: queue-scorer
- type: kv-cache-utilization-scorer
- type: round-robin-fairness-policy
- type: fcfs-ordering-policy
- type: concurrency-detector
  parameters:
    maxConcurrency: 15       # <-- tune for your backend (see Section 2)
    concurrencyMode: requests
    headroom: 0.0
saturationDetector:
  pluginRef: concurrency-detector
flowControl:
  maxRequests: "500"         # <-- global cap (see Section 2)
  defaultRequestTTL: "60s"   # <-- queue timeout (see Section 2)
  priorityBands:
  - priority: 100
    maxRequests: "200"       # realtime tier budget
    fairnessPolicyRef: round-robin-fairness-policy
    orderingPolicyRef: fcfs-ordering-policy
  - priority: 0
    maxRequests: "150"       # standard tier budget
    fairnessPolicyRef: round-robin-fairness-policy
    orderingPolicyRef: fcfs-ordering-policy
  - priority: -1
    maxRequests: "50"        # low-priority tier budget
    fairnessPolicyRef: round-robin-fairness-policy
    orderingPolicyRef: fcfs-ordering-policy
schedulingProfiles:
- name: default
  plugins:
  - pluginRef: queue-scorer
    weight: 2
  - pluginRef: kv-cache-utilization-scorer
    weight: 2
```

### InferenceObjective CRDs

Both configs require these three `InferenceObjective` resources. They map the
`x-llm-d-inference-objective` header to a priority band. The Helm chart creates
these automatically; if you use GitOps, add them to your repo:

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: realtime
spec:
  targetModel: $MODEL_NAME   # replace with your model name
  priority: 100
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: standard
spec:
  targetModel: $MODEL_NAME
  priority: 0
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: low-priority
spec:
  targetModel: $MODEL_NAME
  priority: -1
```

---

## Scenario 00 — Baseline Without Flow Control

### Purpose

Performance baseline with flow control **disabled**. Concurrency sweep
(1 / 5 / 10 / 20 / 40) shows where throughput, latency, and errors degrade
with no protection.

### EPP Config

Apply **Config A** (flow control disabled) from Section 3.

### Commands

Run sequentially (one at a time) or all in parallel. Each run lasts 120s.

```bash
# Concurrency 1
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 1 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/00-baseline-no-fc/concurrency-1

# Concurrency 5
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 5 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/00-baseline-no-fc/concurrency-5

# Concurrency 10
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 10 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/00-baseline-no-fc/concurrency-10

# Concurrency 20
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 20 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/00-baseline-no-fc/concurrency-20

# Concurrency 40
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 40 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/00-baseline-no-fc/concurrency-40
```

### What to Look For (in aiperf output)

Compare the summary table printed by each `aiperf profile` run:

- **Throughput (req/s)** — should increase with concurrency until backends saturate.
- **TTFT and request latency** — expect sharp spikes at high concurrency (no protection).
- **Error rate** — note where errors begin. Scenario 01 should prevent these.

---

## Scenario 01 — Baseline With Flow Control

### Purpose

Same concurrency sweep as Scenario 00, but with flow control **enabled**. At
low concurrency FC is idle (overhead check). At high concurrency FC queues and
sheds excess requests (protection check).

### EPP Config

Apply **Config B** (flow control enabled) from Section 3, then wait for the
EPP to roll out.

### Commands

Identical to Scenario 00. No priority headers — all traffic lands in the
**standard** tier (priority 0).

```bash
# Concurrency 1
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 1 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/01-baseline-with-fc/concurrency-1

# Concurrency 5
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 5 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/01-baseline-with-fc/concurrency-5

# Concurrency 10
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 10 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/01-baseline-with-fc/concurrency-10

# Concurrency 20
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 20 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/01-baseline-with-fc/concurrency-20

# Concurrency 40
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 40 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  --output-artifact-dir results/01-baseline-with-fc/concurrency-40
```

### What to Look For (in aiperf output)

Compare each concurrency level side-by-side with Scenario 00:

- **Low concurrency (1–10)** — throughput and latency should be nearly identical to Scenario 00, proving FC adds negligible overhead.
- **High concurrency (20–40)** — latency should be more bounded and error rate lower than Scenario 00. Throughput may plateau instead of collapsing.

---

## Scenario 02 — Priority Tiers

### Purpose

Three concurrent streams at different priority tiers under saturation. Does
high-priority traffic stay fast while low-priority absorbs the pressure?

### EPP Config

**Config B** (same as Scenario 01).

### Commands

Run all three streams **simultaneously** (`&` at the end). Total concurrency
is 50.

```bash
# Stream 1: Realtime (priority 100) — light, fast requests
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 10 \
  --benchmark-duration 120 \
  --isl 128 --osl 64 \
  --streaming \
  -H "x-llm-d-inference-objective:realtime" \
  --output-artifact-dir results/02-priority-tiers/realtime &

# Stream 2: Standard (priority 0) — medium requests
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 20 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  -H "x-llm-d-inference-objective:standard" \
  --output-artifact-dir results/02-priority-tiers/standard &

# Stream 3: Low-priority (priority -1) — heavy requests
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 20 \
  --benchmark-duration 120 \
  --isl 1024 --osl 512 \
  --streaming \
  -H "x-llm-d-inference-objective:low-priority" \
  --output-artifact-dir results/02-priority-tiers/low-priority &

wait
```

### Traffic Summary

| Stream | Header Value | Priority Band | Concurrency | Tokens (in/out) |
|--------|-------------|---------------|-------------|-----------------|
| Realtime | `realtime` | 100 (200 slots) | 10 | 128 / 64 |
| Standard | `standard` | 0 (150 slots) | 20 | 512 / 256 |
| Low-priority | `low-priority` | -1 (50 slots) | 20 | 1024 / 512 |

### What to Look For (in aiperf output)

Compare the summary tables from each stream's output directory:

- **Realtime** should have the lowest TTFT and request latency.
- **Low-priority** should have the highest latency and most errors.
- **Key check**: realtime latency stays stable even as low-priority degrades.

---

## Scenario 03 — Intra-Tier Fairness

### Purpose

Three tenants share the same priority band but send at a 6:3:1 ratio. The
round-robin fairness policy should give each tenant equal throughput.

### EPP Config

**Config B** (same as Scenario 01).

### Commands

Run all three streams **simultaneously**. All target the **standard** tier
(priority 0) with different `x-llm-d-inference-fairness-id` headers. Total
concurrency is 50.

```bash
# Tenant A — heavy sender (30 concurrent)
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 30 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  -H "x-llm-d-inference-objective:standard" \
  -H "x-llm-d-inference-fairness-id:tenant-a" \
  --output-artifact-dir results/03-intra-tier-fairness/tenant-a &

# Tenant B — medium sender (15 concurrent)
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 15 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  -H "x-llm-d-inference-objective:standard" \
  -H "x-llm-d-inference-fairness-id:tenant-b" \
  --output-artifact-dir results/03-intra-tier-fairness/tenant-b &

# Tenant C — light sender (5 concurrent)
aiperf profile \
  --url "$GATEWAY_URL" \
  --model "$MODEL_NAME" \
  --concurrency 5 \
  --benchmark-duration 120 \
  --isl 512 --osl 256 \
  --streaming \
  -H "x-llm-d-inference-objective:standard" \
  -H "x-llm-d-inference-fairness-id:tenant-c" \
  --output-artifact-dir results/03-intra-tier-fairness/tenant-c &

wait
```

### Traffic Summary

| Tenant | Fairness ID | Concurrency | Send Ratio | Tokens (in/out) |
|--------|-------------|-------------|------------|-----------------|
| A (heavy) | `tenant-a` | 30 | 6x | 512 / 256 |
| B (medium) | `tenant-b` | 15 | 3x | 512 / 256 |
| C (light) | `tenant-c` | 5 | 1x | 512 / 256 |

### What to Look For (in aiperf output)

Compare the summary tables from each tenant's output directory:

- **Throughput (req/s)** should be roughly **equal** across all three tenants despite the 6:3:1 send ratio.
- **Latency** should be comparable — Tenant C should not be worse than Tenant A.
- **If fairness is NOT working**, Tenant A dominates throughput and Tenant C has significantly higher latency or lower completion rates.

---

## Reading the Results

### aiperf Output (primary)

Each `aiperf profile` run prints a summary table to the terminal and writes
files to the `--output-artifact-dir`:

| File | Contents |
|------|----------|
| `profile_export_aiperf.json` | Aggregated stats (min/max/avg/p50/p90/p99) as JSON. |
| `profile_export_aiperf.csv` | Same stats, one metric per row — spreadsheet-friendly. |
| `profile_export.jsonl` | One record per request with individual latency, token counts, and error info. |

Key metrics in the summary table:

| Metric | What to Compare |
|--------|----------------|
| **Request Throughput (req/s)** | Across concurrency levels and scenarios. |
| **Time to First Token (ms)** | Sensitive to queuing — the first metric to degrade. |
| **Request Latency (ms)** | End-to-end time from request to final token. |
| **Error rate** | Failed requests. Should decrease when FC is active. |

### Prometheus Metrics (optional)

If you have Prometheus scraping the EPP, these metrics provide deeper visibility
into flow-control internals that aiperf cannot see:

| Metric | What It Shows |
|--------|--------------|
| `llm_d_flow_control_inflight_requests` | In-flight requests by `priority_band`. |
| `llm_d_flow_control_shed_requests_total` | Shed (rejected) requests by `priority_band`. |
| `llm_d_flow_control_queued_requests` | Queued requests waiting for capacity by `priority_band`. |

### Quick Comparison Checklist

| Compare | What It Proves |
|---------|----------------|
| Scenario 00 vs 01 at high concurrency | FC bounds tail latency and reduces errors. |
| Scenario 02: realtime vs low-priority | Priority tiers protect high-value traffic. |
| Scenario 03: tenant-a vs tenant-c throughput | Fairness prevents a heavy sender from starving others. |
