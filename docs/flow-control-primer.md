# Flow Control Primer

## What is Flow Control?

Flow control is a pool defense mechanism for llm-d inference pools. It moves
intelligent queuing out of the backend model servers and into the gateway's
Endpoint Picker Plugin (EPP), creating a centralized, policy-aware dispatch
layer.

Without flow control, every incoming request is forwarded directly to a vLLM
pod. Each pod manages its own internal queue, and the gateway has no visibility
into how deep those queues are or what kind of work is waiting in them. This
creates two problems: requests pile up in isolated per-pod queues where they
cannot be reprioritized, and the gateway has no way to distinguish a
latency-sensitive chat completion from a bulk offline job.

Flow control solves this by inserting a priority queue between the gateway and
the backend pods. When the pool is saturated, the EPP holds incoming requests in
centralized queues organized by priority, fairness identity, and arrival time.
The dispatch loop then drains these queues in a controlled order, sending
requests to the best-scoring backend as capacity becomes available.

The result is that platform teams get explicit, declarative control over which
workloads get served first, which tenants get fair access, and which traffic can
be shed when resources are exhausted.

## Why Flow Control?

Consider a shared inference pool running `nvidia/NVIDIA-Nemotron-Nano-9B-v2` on
two GPU nodes. Three types of workloads share these resources:

- **Interactive chat** -- Users expect sub-second time-to-first-token. These
  requests are short-lived and latency-sensitive.
- **API calls** -- Programmatic requests from internal services. Moderate
  latency tolerance, but still need reasonable throughput.
- **Batch jobs** -- Offline processing of thousands of prompts. Latency does not
  matter; cost efficiency does.

Without flow control, all three workloads compete equally for GPU time. A burst
of 500 batch requests can saturate both vLLM pods, pushing interactive chat
requests to the back of per-pod queues. Response times for chat spike from
milliseconds to tens of seconds. Users see the application hang.

Flow control eliminates this problem by giving each workload class a declared
priority. Interactive chat is dispatched first. API calls go next. Batch
requests are dispatched only when spare capacity exists -- and if the pool stays
saturated, batch requests are the first to be shed.

## The 3-Tier Dispatch Hierarchy

When the pool is saturated and requests enter the flow control queue, dispatch
follows a strict three-tier hierarchy: priority, then fairness, then ordering.

### Tier 1 -- Priority

Every request is assigned to a **priority band** based on the
`InferenceObjective` CRD it maps to. Each InferenceObjective declares an integer
priority. The dispatch loop evaluates bands from highest priority to lowest,
always draining higher bands before considering lower ones.

In this deployment, three bands are configured:

| Priority | InferenceObjective Name | Intended Workload |
|----------|------------------------|-------------------|
| 100      | `realtime`             | Interactive chat  |
| 0        | `standard`             | API calls         |
| -1       | `batch-sheddable`      | Offline batch     |

A request tagged with `x-llm-d-inference-objective: realtime` enters the
priority-100 band and is dispatched before any request in the priority-0 or
priority-(-1) bands, regardless of arrival time.

**Negative priorities are sheddable.** A negative priority value signals that
the workload is expendable under pressure. The batch band (priority -1) has a
small capacity limit (`maxRequests: 50`), and when that limit is reached, new
batch requests are rejected outright rather than queued. This prevents
low-priority work from consuming queue resources that higher-priority traffic
needs.

### Tier 2 -- Fairness

Within a single priority band, multiple tenants may be submitting requests. The
`round-robin-fairness-policy` ensures that no single tenant monopolizes
dispatch.

Each request carries an `x-llm-d-inference-fairness-id` header that identifies
its tenant. The fairness policy maintains a rotating pointer across all active
tenant queues within the band. On each dispatch cycle, it selects the next
tenant in rotation, regardless of how many requests that tenant has queued.

This matters when tenants have unequal request volumes. Suppose tenant A submits
200 requests and tenant B submits 10, both at priority 0. Without fairness,
tenant A's requests would dominate dispatch simply by volume. With round-robin
fairness, the dispatch alternates: one from A, one from B, one from A, one from
B. Tenant B's 10 requests complete in roughly the same wall-clock time as tenant
A's first 10.

### Tier 3 -- Ordering

Within a single tenant queue (same priority band, same fairness ID), the
`fcfs-ordering-policy` dispatches requests in first-come-first-served order.
The request that arrived earliest is dispatched first.

### Putting It Together

The dispatch loop on each cycle:

1. Scans priority bands from highest to lowest.
2. Within the selected band, picks the next tenant queue via round-robin.
3. Within that tenant queue, picks the oldest request (FCFS).
4. Schedules the request to the best-scoring backend (scored by queue depth and
   KV-cache utilization).

## How Requests Enter the System

Clients control flow control behavior through two HTTP headers on each request.

### x-llm-d-inference-objective

This header maps the request to a named `InferenceObjective` CRD, which in turn
determines the request's priority band.

```
x-llm-d-inference-objective: realtime     # -> priority 100
x-llm-d-inference-objective: standard     # -> priority 0
x-llm-d-inference-objective: batch-sheddable  # -> priority -1
```

The EPP looks up the InferenceObjective by name and reads its `.spec.priority`
field to determine which band the request belongs to.

### x-llm-d-inference-fairness-id

This header identifies the tenant or workload stream for fairness accounting.

```
x-llm-d-inference-fairness-id: team-alpha
x-llm-d-inference-fairness-id: customer-12345
```

The value is an arbitrary string. All requests sharing the same fairness ID
within a priority band are treated as a single queue for round-robin purposes.

### Default Behavior

When headers are missing:

- **No `x-llm-d-inference-objective`**: The request defaults to priority **0**
  (the `standard` band).
- **No `x-llm-d-inference-fairness-id`**: The request is assigned to the
  fairness queue **`default-flow`**.

This means an unannotated request behaves as a standard-priority request
competing in the default fairness queue -- reasonable behavior for clients that
are unaware of flow control.

## Saturation Detection

Flow control only engages when the pool is **saturated**. Below saturation,
requests pass through the EPP immediately to a backend without entering any
queue.

Saturation is determined by the `concurrency-detector` plugin. It continuously
monitors the number of in-flight requests across all vLLM pods in the pool. The
detector is configured with:

```yaml
- type: concurrency-detector
  parameters:
    maxConcurrency: 15
    concurrencyMode: requests
    headroom: 0.0
```

- **maxConcurrency**: The per-endpoint "ideal" request capacity. The detector
  sums in-flight requests across all backends and compares the total against the
  aggregate capacity (`maxConcurrency × endpoint count`). When the ratio reaches
  or exceeds `1.0`, the pool is saturated.
- **concurrencyMode**: How in-flight work is counted. Valid values:
  - `requests` -- counts discrete HTTP requests (the default).
  - `tokens` -- uses a token estimator to count aggregate in-flight tokens
    instead of requests. The threshold is set via `maxTokenConcurrency`
    (default: `1000000`).
  - `hybrid` -- evaluates *both* request and token ratios per endpoint, taking
    the more constraining of the two. Pool saturation is the average of these
    per-endpoint maximums, so an endpoint that is saturated on *either*
    dimension contributes to backpressure.
- **headroom**: Allowed burst capacity above the ideal threshold, expressed as a
  fraction. At `0.0` (the default), saturation triggers exactly when in-flight
  load equals the `maxConcurrency` limit. Setting headroom to `0.2` allows a
  20 % burst -- for example, with `maxConcurrency: 15` per endpoint the
  effective limit becomes `15 × 1.2 = 18` before saturation is signaled. This
  gives the pool breathing room for short traffic spikes without immediately
  engaging the flow-control queues.

The EPP references this plugin via the `saturationDetector.pluginRef` field in
the EndpointPickerConfig. On every incoming request, the EPP checks the
detector's signal: if the pool is not saturated, the request skips flow control
entirely and is routed directly to the best-scoring backend.

## What Happens at Saturation

When the pool is saturated, every request follows this path:

```
Request arrives at EPP
        │
        ▼
  ┌───────────────┐
  │Pool saturated? │
  └──────┬────────┘
     No  │  Yes
   ┌─────┘─────┐
   ▼            ▼
Route to     Assign to
best backend priority band
                │
                ▼
         Place in tenant
         fairness queue
                │
                ▼
        Dispatch loop runs
                │
                ▼
       Scan bands top-down
          by priority
                │
                ▼
       Select next tenant
        via round-robin
                │
                ▼
       Select oldest request
           via FCFS
                │
                ▼
       Score available backends
                │
                ▼
       Dispatch to best-scoring
            vLLM pod
```

In detail:

1. **Request arrives.** The EPP receives the request via Envoy's ext-proc
   protocol.
2. **Saturation check.** The EPP queries the concurrency detector. If the pool
   is below `maxConcurrency`, the request bypasses flow control and goes
   directly to the best-scoring backend.
3. **Priority assignment.** The EPP reads `x-llm-d-inference-objective`, looks
   up the corresponding InferenceObjective CRD, and assigns the request to the
   matching priority band. If the header is absent, priority 0 is used.
4. **Fairness placement.** Within the priority band, the request is placed in
   the tenant queue identified by `x-llm-d-inference-fairness-id` (or
   `default-flow` if the header is absent).
5. **Queue admission.** The band checks its `maxRequests` limit. If the band is
   full, the request is rejected immediately (HTTP 429).
6. **Dispatch loop.** A continuous loop drains the queues. It scans bands from
   highest to lowest priority, selects the next tenant queue via round-robin
   within the chosen band, and picks the oldest request in that queue.
7. **Backend scoring.** The selected request is matched to a backend using the
   scheduling profile (queue-scorer at weight 2, kv-cache-utilization-scorer at
   weight 2). The backend with the best composite score receives the request.
8. **Dispatch.** The request is forwarded to the chosen vLLM pod.

## Sheddable Traffic

Negative-priority bands serve as the pressure relief valve for the pool.

The `batch-sheddable` band (priority -1) is configured with a strict capacity
limit:

```yaml
# From deployment/03-llm-d-router/epp-values.yaml — flowControl.priorityBands
- priority: -1
  maxRequests: "50"
  fairnessPolicyRef: round-robin-fairness-policy
  orderingPolicyRef: fcfs-ordering-policy
```

This means at most 50 batch requests can sit in the queue at any time. The 51st
batch request is rejected immediately. Combined with the global flow control TTL
of 60 seconds (`defaultRequestTTL: "60s"`), batch requests that wait too long
are also expired from the queue.

The batch processor that submits these requests is designed to handle rejections
gracefully. When a request is rejected or times out, the processor retries with
exponential backoff. Batch work therefore fills in around interactive traffic --
it consumes whatever GPU capacity is left over after higher-priority requests
are served, and backs off automatically when none is available.

The overall flow control budget is also capped globally at 500 in-flight
requests (`maxRequests: "500"`). This prevents the queue system itself from
consuming unbounded memory under extreme load.

## Key Configuration

Flow control is configured entirely within the `EndpointPickerConfig` embedded
in the EPP Helm values. The relevant top-level fields are:

| Field | Purpose |
|-------|---------|
| `featureGates` | Must include `flowControl` to enable the feature. |
| `plugins` | Declares the scoring, fairness, ordering, and detector plugins. |
| `saturationDetector.pluginRef` | Points to the detector plugin that signals saturation. |
| `flowControl.maxRequests` | Global cap on total queued requests across all bands. |
| `flowControl.defaultRequestTTL` | Maximum time a request can wait in queue before being expired. |
| `flowControl.priorityBands` | Ordered list of priority bands, each with its own capacity limit, fairness policy, and ordering policy. |

The InferenceObjective CRDs are declared separately (in the Helm values under
`inferenceObjectives`) and map objective names to integer priorities.

The standalone CRD manifests live in
`deployment/05-flow-control/inference-objectives.yaml`. The same values are
also embedded in the EPP Helm values
(`deployment/03-llm-d-router/epp-values.yaml`) so the chart can create them
automatically:

```yaml
# From deployment/03-llm-d-router/epp-values.yaml — router.inferenceObjectives
inferenceObjectives:
- name: realtime
  priority: 100
- name: standard
  priority: 0
- name: batch-sheddable
  priority: -1
```

Removing the `flowControl` feature gate from `featureGates` disables the entire
mechanism. The EPP falls back to direct routing using only the scheduling
scorers (queue-scorer and kv-cache-utilization-scorer), with no queuing,
priority, or fairness behavior.
