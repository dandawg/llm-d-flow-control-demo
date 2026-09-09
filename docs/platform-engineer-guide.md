# Platform Engineer Guide

This guide is for the person deploying, configuring, and tuning llm-d flow
control. It explains the _why_ behind every configuration choice in this PoC
so you can adapt it to your own environment with confidence.

For deployment steps, see the [Deployment Guide](../deployment/README.md).
For a conceptual overview of how flow control works, read the
[Flow Control Primer](flow-control-primer.md) first.

---

## Flow Control in 60 Seconds

Flow control is a centralized queuing and dispatch layer inside the llm-d
Endpoint Picker Plugin (EPP). When your inference pool is saturated, instead of
blindly forwarding requests to overloaded vLLM pods, the EPP holds them in
priority-ordered queues and dispatches them in a controlled sequence:

1. **Priority** -- Higher-priority requests are dispatched before lower ones.
2. **Fairness** -- Within a priority band, tenants get equal access via
   round-robin.
3. **Ordering** -- Within a tenant queue, requests are served
   first-come-first-served.

When the pool is _not_ saturated, flow control is invisible -- requests pass
straight through to the best-scoring backend with zero additional latency.

For the full story, see the [Flow Control Primer](flow-control-primer.md).

---

## Configuration Deep-Dive

All flow control configuration lives in the `EndpointPickerConfig` embedded in
the EPP Helm values. In this PoC, that file is
[`deployment/03-llm-d-router/epp-values.yaml`](../deployment/03-llm-d-router/epp-values.yaml).

This section walks through every significant setting, explains why the PoC
value was chosen, and describes what happens when you change it.

### Feature Gates

```yaml
featureGates:
- flowControl
```

The `flowControl` feature gate is the master switch. Without it, the EPP uses
only its scheduling scorers (queue-scorer, kv-cache-utilization-scorer) and
routes every request directly to a backend -- no queuing, no priority, no
fairness.

**Why this matters:** You can A/B test flow control by toggling this single
gate. The PoC includes `epp-values-no-fc.yaml` for exactly this purpose, and
`make swap-fc-off` / `make swap-fc-on` automate the switch.

### Saturation Detection

```yaml
- type: concurrency-detector
  parameters:
    maxConcurrency: 15
    concurrencyMode: requests
    headroom: 0.0
```

The saturation detector determines _when_ flow control engages. This is the
most impactful setting in the entire configuration because it defines the
boundary between "requests flow through directly" and "requests enter the
priority queue."

**Important:** The detector is an instantaneous per-request gate, not an
intelligent scaling or spike-detection system. On every incoming request, the
EPP counts current in-flight work, compares it to a fixed threshold, and either
routes directly or enqueues. There is no time-window analysis, moving average,
smoothing, or delay.

#### `maxConcurrency: 15`

This is the per-endpoint "ideal" concurrent request capacity. The detector
multiplies this by the number of ready endpoints to get the pool's total
capacity. With 2 vLLM replicas, the pool capacity is `15 x 2 = 30` concurrent
requests.

**Why 15?** This value was chosen empirically for the Nemotron Nano 9B model on
A10G GPUs. At 15 concurrent requests per pod, the model maintains reasonable
TTFT and does not thrash the KV cache. Going higher means the pool tolerates
more load before queuing begins, but individual request latency rises because
each pod is juggling more work. Going lower means flow control engages sooner,
which protects latency but may queue requests unnecessarily during moderate
load.

**How to find the right value for your model:**

1. Run the baseline scenario (`make benchmark-00`) with increasing concurrency
   levels (the scenario already sweeps 1, 5, 10, 20, 40).
2. Watch the TTFT and KV cache utilization in Grafana.
3. Find the concurrency level where TTFT starts to degrade noticeably or KV
   cache crosses ~80%. That is your `maxConcurrency`.

#### `concurrencyMode: requests`

How in-flight work is counted. Three modes are available:

| Mode | Counts | Best For |
|------|--------|----------|
| `requests` | Discrete HTTP requests | Fixed-size workloads, simple capacity model |
| `tokens` | Estimated in-flight tokens | Variable-length prompts where long inputs dominate |
| `hybrid` | Both, taking the more constraining | Mixed workloads with unpredictable prompt lengths |

**Why `requests`?** This PoC uses fixed prompt/output token counts in its
benchmarks, so request-level counting is predictable and easy to reason about.
For production workloads with highly variable prompt lengths, `hybrid` mode
gives more accurate saturation detection because a single 4K-token prompt
consumes far more GPU resources than a 128-token prompt.

#### `headroom: 0.0`

A buffer above the ideal capacity threshold, expressed as a fraction. At `0.0`,
saturation triggers the instant in-flight requests reach `maxConcurrency x
endpoint_count`. Setting headroom to `0.2` raises the effective threshold by
20% -- with 2 replicas at `maxConcurrency: 15`, the pool would tolerate 36
in-flight requests instead of 30 before queuing begins.

Headroom is **not** an intelligent burst-detection or auto-scaling mechanism. It
simply raises the fixed numerical threshold at which the per-request gate trips.
Every request still gets the same instantaneous check: count in-flight work,
compare to the (now slightly higher) threshold, route or enqueue.

**Why 0.0?** For a demo, we want flow control to engage predictably and
visibly. Any headroom raises the threshold, making it harder to observe
the transition from direct routing to queuing.

**When to raise headroom:** In production, a pool that sits right at its
capacity boundary will experience **queue chatter** -- rapid oscillation between
queuing and direct routing as individual requests complete and new ones arrive.
One request finishes, the ratio dips below 1.0, the next request bypasses the
queue, the ratio jumps back, and the request after that enters the queue. This
on/off flapping adds jitter without providing meaningful protection.

A headroom of `0.1` to `0.2` eliminates chatter by requiring the pool to be
meaningfully over capacity before flow control engages. The tradeoff is that
requests arriving during the headroom buffer period get slightly higher latency
because the backends are briefly overloaded beyond their ideal capacity.

### Global Flow Control Settings

```yaml
flowControl:
  maxRequests: "500"
  defaultRequestTTL: "60s"
```

#### `maxRequests: "500"`

The global cap on total queued requests across all priority bands combined.
This is a safety valve that prevents the queue system from consuming unbounded
memory.

**Why 500?** With 2 vLLM replicas and a `maxConcurrency` of 15, the pool can
handle ~30 concurrent requests. A queue of 500 means roughly 16x the pool's
instantaneous capacity can be buffered. This is generous enough for burst
absorption but bounded enough to prevent memory pressure on the EPP pod.

**Sizing guidance:** Set this to `10-20x` your pool's concurrent capacity. If
you have 4 replicas at `maxConcurrency: 15`, pool capacity is 60, so a
`maxRequests` of 600-1200 is reasonable. Too low and you reject requests
unnecessarily during bursts. Too high and a sustained overload can exhaust EPP
memory.

#### `defaultRequestTTL: "60s"`

Maximum time a request can wait in queue before being expired. Expired requests
are removed from the queue and the client receives an error.

**Why 60s?** This balances two concerns:

- **Too short** (e.g., 10s): Requests get expired before the dispatch loop
  reaches them during heavy load, even though they would have been served in
  another few seconds. This causes unnecessary failures.
- **Too long** (e.g., 300s): Clients have already timed out or given up, but
  their requests are still consuming queue slots. The queue fills with "dead"
  requests that will never be read.

**Relationship to client timeout:** The TTL should be shorter than your
client's read timeout. If your gateway HTTPRoute has a 300s timeout (as in this
PoC) and your client SDK has a 120s timeout, setting the TTL to 60s ensures
expired requests are cleaned up well before the client gives up. If the TTL is
longer than the client timeout, the queue wastes slots on requests whose
clients have already disconnected.

### Priority Bands

```yaml
priorityBands:
- priority: 100
  maxRequests: "200"
  fairnessPolicyRef: round-robin-fairness-policy
  orderingPolicyRef: fcfs-ordering-policy
- priority: 0
  maxRequests: "150"
  fairnessPolicyRef: round-robin-fairness-policy
  orderingPolicyRef: fcfs-ordering-policy
- priority: -1
  maxRequests: "50"
  fairnessPolicyRef: round-robin-fairness-policy
  orderingPolicyRef: fcfs-ordering-policy
```

Each priority band is an independent queue with its own capacity limit. The
dispatch loop scans bands from highest priority to lowest, always draining
higher bands before considering lower ones.

#### Per-Band `maxRequests`: 200 / 150 / 50

Each band's `maxRequests` is a hard cap on how many requests can queue in that
band simultaneously. The values above were chosen for this PoC's workload mix:

| Band | Priority | `maxRequests` | Reasoning |
|------|----------|---------------|-----------|
| Premium (`realtime`) | 100 | 200 | Largest allocation because this traffic must never be rejected. Users are watching. |
| Standard | 0 | 150 | Moderate allocation for programmatic API traffic that can tolerate some queuing. |
| Low-Priority (`low-priority`) | -1 | 50 | Small allocation by design. Low-priority work should fill in around interactive traffic, not compete with it. |

The global `maxRequests: 500` is a separate safety ceiling on total queued
requests across all bands combined. It does not redistribute unused capacity
between bands -- each band can only fill to its own `maxRequests` limit. The
global cap matters only if you later add bands or raise per-band limits and
want an upper bound on total queue depth.

**How to size for your workload mix:**

- Estimate the peak burst depth for each traffic class. How many requests of
  each type might arrive in the time it takes the pool to process one request?
- Allocate slots proportionally, with a bias toward higher-priority traffic.
- Keep low-priority bands intentionally small. Their purpose is to absorb
  spare capacity, not to buffer large backlogs.

#### What Happens When a Band Is Full

Every band behaves the same way when it reaches its `maxRequests` limit: the
next request for that band is **rejected immediately** with HTTP 429. This
applies equally to premium (200), standard (150), and batch (50).

The difference is not in mechanism but in design intent:

- **Low-priority (priority -1)** has a small limit _on purpose_. It is
  sized to fill up quickly under load, acting as the pressure relief valve for
  the pool. Low-priority clients are designed to retry with exponential backoff, so
  rejected requests are not lost.

> **Expected client behavior:** The small low-priority limit only works safely if the
> client handles 429 responses gracefully. At a minimum, the client
> should implement **exponential backoff with jitter** -- wait 1s, 2s, 4s, 8s,
> etc. (plus a random offset to avoid thundering herd) before retrying a
> rejected request. The client should also cap the total number of retries to
> avoid infinite loops if the pool is persistently overloaded. If your
> client does _not_ retry on 429, rejected requests are lost permanently and
> the small band limit becomes a data loss risk rather than a backpressure
> mechanism. Design your submission pipeline accordingly.
- **Premium (priority 100)** and **standard (priority 0)** have larger limits
  because rejecting this traffic is painful. If these bands are hitting 429s,
  the pool is severely overloaded and you need to either scale up replicas or
  reduce `maxConcurrency` to queue more aggressively.

Additionally, the dispatch loop always drains higher-priority bands first. So
even when all three bands have queued requests, premium requests are
dispatched before standard, and standard before batch. The small batch limit
combined with lowest dispatch priority means low-priority traffic absorbs overload
from both directions: it is the first to be rejected and the last to be
served.

#### Fairness and Ordering Policies

All three bands reference the same policies:

- **`round-robin-fairness-policy`** -- Rotates dispatch across tenant queues
  within the band. Prevents any single tenant from monopolizing capacity.
- **`fcfs-ordering-policy`** -- Within a single tenant queue, dispatches the
  oldest request first.

You could configure different policies per band (e.g., no fairness for the
low-priority band if you do not care about tenant equity in that tier), but in practice the
round-robin + FCFS combination works well for all tiers.

**Available built-in fairness policies:**

| Policy | Behavior |
|--------|----------|
| `round-robin-fairness-policy` | Rotates dispatch across per-tenant queues within a band. Each tenant gets an equal share of dispatch slots regardless of how many requests they have queued. *Used in this PoC.* |
| `global-strict-fairness-policy` | Ignores per-tenant flow isolation entirely. All requests within the band are placed in a single global queue whose order is determined solely by the ordering policy. This is the default if no `fairnessPolicyRef` is set on a band. |

**Available built-in ordering policies:**

| Policy | Behavior |
|--------|----------|
| `fcfs-ordering-policy` | Dispatches the oldest request first (first-come-first-served). Simple and predictable. *Used in this PoC.* |
| `edf-ordering-policy` | Earliest Deadline First. Derives each request's deadline from its TTL and dispatches whichever request is closest to expiring. Useful when requests have different TTLs and you want to minimize expirations. |
| `slo-deadline-ordering-policy` | Orders by the `x-llm-d-slo-ttft-ms` header value. Requests with a tighter SLO target are dispatched first. Requests without the header are placed behind all SLO-bearing requests. Useful when clients declare latency targets and you want the system to honor them. |

**Why this PoC uses round-robin + FCFS:** Round-robin ensures fair bandwidth
between tenants during saturation, and FCFS is the simplest ordering to reason
about. For most deployments, this combination is a solid default. Consider
switching ordering policies when you need SLO-aware dispatch or have mixed-TTL
workloads where deadline-driven ordering would reduce unnecessary expirations.

### Scheduling Profile

```yaml
schedulingProfiles:
- name: default
  plugins:
  - pluginRef: queue-scorer
    weight: 2
  - pluginRef: kv-cache-utilization-scorer
    weight: 2
```

The scheduling profile determines which backend receives each dispatched
request. It runs after the dispatch loop selects a request from the queue.

#### `queue-scorer` (weight: 2)

Scores backends by their current queue depth. A backend with fewer in-flight
requests scores higher. This distributes new requests toward less-loaded pods.

#### `kv-cache-utilization-scorer` (weight: 2)

Scores backends by their KV cache pressure. A backend with more free KV cache
scores higher. This prevents sending new requests to a pod whose cache is
nearly full, which would cause cache eviction and degrade all requests on that
pod.

**Why equal weights?** Both signals are equally important for this model size.
For larger models where KV cache is the primary bottleneck, you might increase
the kv-cache weight to `3` or `4`. For smaller models where queue depth is more
predictive of latency, increase the queue-scorer weight.

### InferenceObjectives

```yaml
inferenceObjectives:
- name: realtime
  priority: 100
- name: standard
  priority: 0
- name: low-priority
  priority: -1
```

InferenceObjective CRDs map names to integer priorities. Clients select an
objective by setting the `x-llm-d-inference-objective` HTTP header. The EPP
resolves the header value to a CRD and reads its priority to determine which
band handles the request.

**Why these specific priority values?**

- **100 for premium:** A high positive number that leaves room to insert
  tiers above standard but below premium in the future (e.g., `urgent: 50`).
- **0 for standard:** The default. Requests without an objective header land
  here automatically.
- **-1 for low-priority:** The lowest priority in our tier structure. The
  EPP does not treat negative priorities differently from positive ones -- the
  sign has no special meaning. We use -1 simply because it sorts below 0,
  ensuring low-priority work is dispatched last.

---

## Designing Your Priority Tiers

The 3-tier structure in this PoC is a starting point. Here is a framework for
designing your own:

### Step 1: List Your Workload Classes

Write down every distinct type of traffic that hits your inference pool. For
each, note:

- **Latency sensitivity:** Does a human see the response in real time? Is it a
  background job?
- **Failure tolerance:** Can the client retry? Is the request idempotent?
- **Volume pattern:** Steady trickle or bursty?

### Step 2: Group Into Bands

Merge workload classes that share the same latency sensitivity and failure
tolerance into a single band. You want the fewest bands that still provide
meaningful differentiation.

**Rule of thumb:** 2-4 bands is typical. More than 5 bands adds complexity
without proportional benefit because the dispatch loop scans linearly.

### Step 3: Assign Priorities

Use widely spaced integers to leave room for future tiers:

| Band | Suggested Priority | Notes |
|------|-------------------|-------|
| Emergency / bypass | 1000 | For operational overrides, health checks |
| Premium | 100 | Chat, autocomplete, streaming — real-time user-facing |
| Standard API | 0 | Programmatic requests, moderate latency tolerance |
| Low-priority | -1 | Batch processing, offline analytics, background / async |
| Best-effort / test | -100 | Dev/test traffic, fully sheddable |

### Step 4: Size Band Capacities

For each band, estimate the peak burst depth and allocate `maxRequests`
accordingly. Reserve the most capacity for your highest-priority band -- that
is the traffic you must never reject.

---

## Tuning Knobs Reference

| Parameter | Location | Default (PoC) | Effect | Symptom to Watch |
|-----------|----------|---------------|--------|------------------|
| `maxConcurrency` | concurrency-detector | 15 | Per-endpoint capacity threshold for saturation detection | TTFT degradation at high load means value is too high; frequent queue chatter means value is too low |
| `concurrencyMode` | concurrency-detector | requests | Unit of measurement for in-flight work | Variable-length prompts causing uneven backend load suggests switching to `hybrid` |
| `headroom` | concurrency-detector | 0.0 | Raises the fixed saturation threshold to prevent queue chatter (not intelligent burst detection) | Queue engaging/disengaging rapidly ("chatter") means raise headroom (0.1-0.2) |
| `maxRequests` (global) | flowControl | 500 | Global queue capacity across all bands | EPP memory pressure means value is too high; unnecessary 429s means value is too low |
| `defaultRequestTTL` | flowControl | 60s | Max queue wait before expiry | High expiry rate means TTL is too short or pool is undersized; dead requests in queue means TTL is too long |
| `maxRequests` (per band) | priorityBands | 200/150/50 | Per-band queue capacity | 429s on a high-priority band means its allocation is too small |
| `priority` | InferenceObjective | 100/0/-1 | Dispatch order between bands | No latency differentiation between tiers means priorities are too close or pool is not saturated |
| queue-scorer `weight` | schedulingProfiles | 2 | Influence of queue depth on backend selection | Uneven request distribution across pods means increase weight |
| kv-cache-utilization-scorer `weight` | schedulingProfiles | 2 | Influence of KV cache on backend selection | One pod's KV cache full while other is low means increase weight |

---

## Customization Checklist

When adapting this PoC for your own environment, update these items:

### Model

- [ ] Update `MODEL_NAME` and `MODEL_SHORT_NAME` in `config.env`
- [ ] Update the vLLM deployment image and model arguments in
      `deployment/02-vllm/vllm-deployment.yaml`
- [ ] Re-derive `maxConcurrency` for your model (run baseline benchmarks)
- [ ] Adjust vLLM resource requests (GPU count, memory) for your model size

### Cluster

- [ ] Update `CLUSTER_NAME` and `AWS_REGION` in `config.env`
- [ ] Adjust node group instance types in `cluster/cluster.yaml` (match GPU to
      your model's VRAM requirements)
- [ ] Update `VLLM_REPLICAS` in `config.env` (affects pool capacity calculation)

### Priority Tiers

- [ ] Define your InferenceObjective names and priorities in
      `deployment/03-llm-d-router/epp-values.yaml` (under `inferenceObjectives`)
- [ ] Update the priority bands to match (under `flowControl.priorityBands`)
- [ ] Update `deployment/05-flow-control/inference-objectives.yaml` to match
- [ ] Update the `FC_*_OBJECTIVE` variables in `config.env`
- [ ] Update benchmark scenario headers to use your objective names

### Capacity Sizing

- [ ] Set `maxConcurrency` based on your model's empirical capacity per pod
- [ ] Set per-band `maxRequests` based on your expected workload mix
- [ ] Set global `maxRequests` to at least the sum of all per-band `maxRequests`
- [ ] Set `defaultRequestTTL` to less than your client's read timeout

### Observability

- [ ] Verify Prometheus scrape targets match your pod labels
- [ ] Update Grafana dashboard queries if you changed metric label values

---

## Troubleshooting

### EPP not picking up configuration changes

**Symptom:** You edited `epp-values.yaml` and ran `helm upgrade`, but behavior
has not changed.

**Diagnosis:**
```bash
# Check the EPP pod restarted
kubectl get pods -n llm-d-poc -l app.kubernetes.io/name=llm-d-router-gateway

# Check the EPP logs for config load
kubectl logs -n llm-d-poc deployment/vllm-nemotron-nano-9b-epp | grep -i "config\|plugin\|flow"

# Verify the config inside the pod
kubectl exec -n llm-d-poc deployment/vllm-nemotron-nano-9b-epp -- \
  cat /config/default-plugins.yaml
```

**Fix:** `helm upgrade` should trigger a pod restart. If it did not, delete the
EPP pod manually: `kubectl delete pod -n llm-d-poc -l
app.kubernetes.io/name=llm-d-router-gateway`

<!-- SCREENSHOT: EPP pod logs showing "flow control enabled" or similar startup
     message. Capture from `kubectl logs` output.
     Save as: docs/images/epp-flow-control-startup-log.png -->

### Pool never saturates (flow control never engages)

**Symptom:** Queue depth stays at 0 even under heavy load. The saturation gauge
on the Flow Control Overview dashboard never reaches 1.0.

**Diagnosis:**
```bash
# Check how many endpoints the EPP sees
kubectl logs -n llm-d-poc deployment/vllm-nemotron-nano-9b-epp | grep -i "endpoint\|ready"

# Check pool saturation metric directly
curl -s http://localhost:9090/api/v1/query?query=llm_d_epp_flow_control_pool_saturation | jq
```

**Likely causes:**
- `maxConcurrency` is set too high. If your model can only handle 10 concurrent
  requests comfortably but `maxConcurrency` is 30, the pool will never appear
  saturated to the detector.
- Not enough load. Increase benchmark concurrency.
- EPP is not seeing all endpoints. Check that the InferencePool selector
  matches your vLLM pod labels.

### All traffic getting rejected (429s across all bands)

**Symptom:** Every request returns HTTP 429 regardless of priority.

**Diagnosis:**
```bash
# Check global queue depth
curl -s http://localhost:9090/api/v1/query?query=sum\(llm_d_epp_flow_control_queue_size\) | jq

# Check if backends are healthy
kubectl get pods -n llm-d-poc -l app=vllm-nemotron-nano-9b
```

**Likely causes:**
- vLLM pods are unhealthy or not ready. The EPP has no backends to dispatch to,
  so the queue fills to capacity and rejects everything.
- Global `maxRequests` is too low for the load level.
- `defaultRequestTTL` is too short, causing requests to expire faster than they
  can be dispatched.

### Fairness not balanced between tenants

**Symptom:** One tenant gets significantly more throughput than others despite
round-robin fairness being configured.

**Diagnosis:**
```bash
# Check dispatch counts by fairness_id
curl -s http://localhost:9090/api/v1/query?query=sum%20by\(fairness_id\)\(rate\(llm_d_epp_flow_control_requests_total\{outcome%3D%22Dispatched%22\}[1m]\)\) | jq

# Verify headers are being set correctly
# Send a test request and check EPP logs
kubectl logs -n llm-d-poc deployment/vllm-nemotron-nano-9b-epp --tail=50
```

**Likely causes:**
- The `x-llm-d-inference-fairness-id` header is not being set on requests,
  so all requests land in the `default-flow` fairness queue (which is fair
  by definition -- one queue has nothing to round-robin against).
- The pool is not saturated. Fairness only matters under saturation; below
  saturation, requests bypass the queue entirely and fairness has no effect.
- One tenant is sending requests with much smaller prompts. Round-robin gives
  each tenant equal _dispatch rate_ (requests per cycle), but if one tenant's
  requests complete 5x faster, that tenant's throughput appears higher even
  though dispatch is fair.

### Premium latency is high despite having highest priority

**Symptom:** Premium TTFT is elevated even though the priority band is
configured at 100.

**Diagnosis:**
```bash
# Check if saturation detector is triggering
curl -s http://localhost:9090/api/v1/query?query=llm_d_epp_flow_control_pool_saturation | jq

# Check premium queue depth (should be low if priority is working)
curl -s http://localhost:9090/api/v1/query?query=llm_d_epp_flow_control_queue_size\{priority%3D%22100%22\} | jq
```

**Likely causes:**
- The `x-llm-d-inference-objective: realtime` header is not set correctly.
  Without it, requests default to priority 0 (standard).
- The pool is so overloaded that even the premium band is full. Check if the
  premium band's `maxRequests` (200) is being reached.
- Backend scoring is sending premium requests to an already-overloaded pod.
  Check per-pod KV cache utilization.

<!-- SCREENSHOT: Terminal output of `kubectl get inferenceobjective -n llm-d-poc`
     showing all three objectives with their priorities.
     Save as: docs/images/inference-objectives-kubectl.png -->

---

## What to Read Next

- [Flow Control Primer](flow-control-primer.md) -- Full conceptual deep-dive
  into the 3-tier dispatch hierarchy.
- [Architecture Guide](architecture.md) -- Component overview and request flow
  diagrams.
- [Operator Guide](operator-guide.md) -- How to read the dashboards, what good
  and bad look like, and how to respond to operational signals.
- [Deployment Guide](../deployment/README.md) -- Step-by-step deployment
  walkthrough.
