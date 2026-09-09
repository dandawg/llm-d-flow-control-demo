# Operator Guide

This guide is for the person watching the system -- whether in production or
during a demo. It teaches you to read the Grafana dashboards, recognize healthy
and unhealthy states, and respond to operational signals.

For configuration and tuning details, see the
[Platform Engineer Guide](platform-engineer-guide.md).
For a conceptual overview, read the
[Flow Control Primer](flow-control-primer.md).

---

## Accessing the Dashboards

```bash
# Start port-forwards (if not already running)
make observability-port-forward

# Or manually:
kubectl port-forward -n llm-d-monitoring svc/grafana 3000:3000 &
kubectl port-forward -n llm-d-monitoring svc/prometheus 9090:9090 &
```

Open [http://localhost:3000](http://localhost:3000) and log in with
`admin` / `admin`. Four dashboards are available under the `llm-d` tag.

---

## Dashboard Tour

### 1. Flow Control Overview

**When to use:** This is your primary operational dashboard. Start here when
checking system health or during any flow control demo.

<!-- SCREENSHOT: Full Flow Control Overview dashboard during steady-state load
     (e.g., during Phase 3 of the live demo). Show all 6 panels visible.
     Save as: docs/images/dashboard-fc-overview-full.png -->

#### Panel: Pool Saturation (gauge)

**Metric:** `llm_d_epp_flow_control_pool_saturation`

**What it shows:** The ratio of current in-flight requests to total pool
capacity, as a 0-to-1 gauge. This is the single most important indicator of
whether flow control is actively engaged.

| Reading | Color | Meaning |
|---------|-------|---------|
| 0.0 -- 0.69 | Green | Pool is healthy. Requests bypass the queue entirely. |
| 0.70 -- 0.89 | Yellow | Pool is getting warm. Approaching saturation. |
| 0.90 -- 1.0 | Red | Pool is saturated. Flow control is actively queuing. |

**What good looks like:** Under normal load, the gauge sits in the green zone.
Requests flow through without queuing, and latency is determined entirely by
the model server.

**What bad looks like:** The gauge is pegged at 1.0 continuously. This means
the pool is perpetually saturated and every request goes through the queue.
While flow control handles this gracefully, sustained saturation means your
pool is undersized for the traffic volume.

<!-- SCREENSHOT: Pool Saturation gauge in green (unsaturated state).
     Capture during Phase 1 of the live demo or during idle.
     Save as: docs/images/fc-saturation-gauge-green.png -->

<!-- SCREENSHOT: Pool Saturation gauge in red (saturated state).
     Capture during Phase 3 or Phase 5 of the live demo.
     Save as: docs/images/fc-saturation-gauge-red.png -->

#### Panel: Pool Saturation Over Time (timeseries)

**Metric:** `llm_d_epp_flow_control_pool_saturation`

**What it shows:** The same saturation ratio as the gauge, plotted over time.
This lets you see when saturation began, how long it lasted, and whether it
correlates with specific events (benchmark phases, traffic bursts).

**What to look for:**
- Clean transitions from 0 to 1 and back indicate load-driven saturation that
  resolves when load drops.
- Sustained 1.0 for extended periods means the pool cannot keep up.
- Rapid oscillation between 0 and 1 ("queue chatter") means the pool is sitting
  right at its capacity boundary. Because saturation detection is an
  instantaneous per-request check (not a smoothed average), each request
  completing briefly drops the ratio below 1.0, the next request bypasses the
  queue, and the ratio jumps back. Raising `headroom` from `0.0` to `0.1`--`0.2`
  eliminates this by requiring the pool to be meaningfully over capacity before
  flow control engages. Alternatively, lowering `maxConcurrency` shifts the
  threshold so the pool saturates more decisively.

#### Panel: Queue Depth by Tier (timeseries)

**Metric:** `sum by(priority) (llm_d_epp_flow_control_queue_size)`

**What it shows:** How many requests are waiting in each tier's queue.
The series are labeled by tier name: `premium`, `standard`, `batch`.

**What good looks like:** During saturation:
- Premium queue stays low or at zero -- requests are dispatched
  almost immediately because they are highest priority.
- Standard queue shows moderate depth -- requests queue briefly
  before dispatch.
- Batch queue shows the highest depth -- these requests wait the
  longest.

**What bad looks like:**
- Premium queue is high. This means even the highest-priority traffic is
  backlogged, indicating severe overload.
- All queues are at their `maxRequests` limits. The pool is overwhelmed.
- Queue depth never returns to 0 after load drops. Something is blocking
  dispatch (check backend health).

<!-- SCREENSHOT: Queue Depth panel showing tier differentiation.
     The premium line should be near zero while standard and batch show depth.
     Capture during Phase 3 of the live demo.
     Annotate/circle the premium line staying flat near zero.
     Save as: docs/images/fc-queue-depth-by-tier.png -->

#### Panel: Dispatch Rate by Tier (timeseries)

**Metric:** `sum by(priority) (rate(llm_d_epp_flow_control_requests_total{outcome="Dispatched"}[1m]))`

**What it shows:** How many requests per second are being dispatched (sent to a
backend) from each tier.

**What good looks like:** Premium dispatch rate should be proportional to
premium request arrival rate -- meaning nearly all premium requests are
dispatched without significant queuing delay. Lower tiers show
dispatch rates that reflect leftover capacity.

**What bad looks like:** Dispatch rate for all tiers drops to zero while queues
are growing. This means backends are not accepting work (check vLLM pod health).

#### Panel: Rejection Rate by Tier (timeseries)

**Metric:** `sum by(priority) (rate(llm_d_epp_flow_control_requests_total{outcome!="Dispatched"}[1m]))`

**What it shows:** How many requests per second are being rejected (shed,
expired, or failed) per tier. This counts all non-dispatched outcomes.

**What good looks like:** Under moderate saturation:
- Premium rejection rate is zero or negligible.
- Standard rejection rate is low.
- Batch rejection rate is elevated -- this is expected and healthy. The batch
  tier is the pressure relief valve.

**What bad looks like:**
- Premium rejections are non-zero. This means even high-priority traffic is
  being shed, indicating the premium tier's `maxRequests` (200) is full.
- All tiers show high rejection rates. The pool is severely overwhelmed.

<!-- SCREENSHOT: Rejection Rate panel showing low-priority shedding while premium
     stays at zero. Capture during Phase 5 of the live demo.
     Annotate the low-priority line spiking and the premium line at zero.
     Save as: docs/images/fc-rejection-rate-by-tier.png -->

#### Panel: Queue Wait Time p95 by Tier (timeseries)

**Metric:** `histogram_quantile(0.95, sum by(le, priority) (rate(llm_d_epp_flow_control_request_queue_duration_seconds_bucket[1m])))`

**What it shows:** The 95th percentile time a request spent waiting in the
queue before being dispatched, broken out by tier.

**What good looks like:**
- Premium wait time is near zero (milliseconds).
- Standard wait time is moderate (sub-second).
- Batch wait time is highest (seconds) -- this is expected.

**What bad looks like:**
- Premium wait time is high (seconds). Priority is not providing the expected
  insulation.
- All tiers have similar wait times. The tier differentiation is not
  working (check that `x-llm-d-inference-objective` headers are being set
  correctly on requests).

---

### 2. Latency by Tier

**When to use:** Deep-dive into per-tier latency characteristics. Use this to
compare how different tiers experience the system.

<!-- SCREENSHOT: Full Latency by Tier dashboard during Phase 3 of the live demo.
     The key visual is the TTFT panels showing clear separation between tiers.
     Save as: docs/images/dashboard-latency-by-tier-full.png -->

#### Panels: TTFT p50 / p95 / p99 by Tier

**Metric:** `histogram_quantile(0.50|0.95|0.99, sum by(le, priority) (rate(llm_d_epp_request_ttft_seconds_bucket[1m])))`

**What it shows:** Time to first token at different percentiles, broken out by
tier. This is the metric users feel most directly -- how long they
wait before the response starts streaming.

**What good isolation looks like:** Under saturation, the TTFT lines for each
tier should separate clearly:
- Premium: lowest TTFT, relatively stable.
- Standard: moderate TTFT, rises under load.
- Batch: highest TTFT, most variable.

The gap between premium and standard TTFT is the clearest proof that tier
isolation is working. If they overlap, flow control is not differentiating effectively.

<!-- SCREENSHOT: TTFT p95 panel showing clear tier separation.
     Premium should be visibly lower than standard, which is lower than batch.
     Capture during Phase 3 of the live demo.
     Draw arrows or annotate showing the gap between tier lines.
     Save as: docs/images/latency-ttft-p95-separation.png -->

**What bad looks like:**
- All three tiers have similar TTFT. Either flow control is not engaged (check
  the saturation gauge), or the headers are not being set correctly.
- Premium TTFT is spiking. Check if the pool has any healthy backends.

#### Panels: ITL p50 / p95 / p99 by Tier

**Metric:** `histogram_quantile(0.50|0.95|0.99, sum by(le, priority) (rate(llm_d_epp_request_streaming_itl_seconds_bucket[1m])))`

**What it shows:** Inter-token latency -- the time between consecutive tokens
in a streaming response. This affects the perceived "typing speed" of the
model.

**What to expect:** ITL is primarily a function of the model server's internal
scheduling, not flow control. Tiers may show slightly different ITL
under heavy load because the scheduling scorers route higher-priority requests
to less-loaded backends, but the differences are typically smaller than TTFT
differences.

#### Panel: Request Duration p95 by Tier

**Metric:** `histogram_quantile(0.95, sum by(le, priority) (rate(llm_d_epp_request_duration_seconds_bucket[1m])))`

**What it shows:** Total end-to-end request time (from arrival at the EPP to
completion of the response), at p95.

**What to expect:** This includes queue wait time + model processing time. The
priority separation should be most visible here because queue wait time
dominates for lower tiers under saturation.

#### Panel: Queue Wait p95 by Tier

**Metric:** `histogram_quantile(0.95, sum by(le, priority) (rate(llm_d_epp_flow_control_request_queue_duration_seconds_bucket[1m])))`

**What it shows:** Same as the Queue Wait Time panel on the Flow Control
Overview, but alongside the other latency metrics for easy comparison.

---

### 3. Fairness Analysis

**When to use:** When validating that the round-robin fairness policy is
working correctly. This is the primary dashboard for Scenario 03 (intra-tier
fairness).

<!-- SCREENSHOT: Full Fairness Analysis dashboard during Scenario 03.
     The key visual is dispatch counts being roughly equal despite unequal send rates.
     Save as: docs/images/dashboard-fairness-analysis-full.png -->

#### Panel: Dispatch Count by Tenant (timeseries)

**Metric:** `sum by(fairness_id) (rate(llm_d_epp_flow_control_requests_total{outcome="Dispatched"}[1m]))`

**What it shows:** Dispatch rate (requests/second) for each tenant identified
by `fairness_id`.

**What good looks like:** All tenant lines converge to approximately the same
dispatch rate, even if the tenants are sending vastly different volumes of
traffic. In Scenario 03, tenant-a sends 30 concurrent requests while tenant-c
sends 5, but their dispatch rates should be nearly identical under saturation.

**What bad looks like:** One tenant's line is significantly higher than others.
This indicates the round-robin fairness policy is not rotating correctly
(unlikely) or that the pool is not saturated (fairness only applies during
saturation).

<!-- SCREENSHOT: Dispatch Count by Tenant showing converged lines.
     All three tenant lines should be close together.
     Annotate that tenant-a sends 6x more traffic but gets equal dispatch.
     Save as: docs/images/fairness-dispatch-count-equal.png -->

#### Panel: Jain's Fairness Index (timeseries + stat)

**Metric:** Computed as \(\frac{(\sum r_i)^2}{n \cdot \sum r_i^2}\) where
\(r_i\) is each tenant's dispatch rate.

**What it shows:** A single number from 0 to 1 measuring how fairly capacity
is distributed:

| Value | Interpretation |
|-------|----------------|
| 1.0 | Perfectly fair -- all tenants get equal dispatch rate |
| 0.9 -- 0.99 | Very good -- minor imbalances, likely due to measurement noise |
| 0.8 -- 0.89 | Acceptable -- some imbalance, investigate if persistent |
| < 0.8 | Poor -- significant unfairness, check configuration |

The timeseries shows how the index evolves over time. The stat panel shows
the current instantaneous value.

**What good looks like:** The index stays above 0.95 during sustained
saturation with multiple tenants.

**What bad looks like:** The index drops below 0.8 persistently. Check that
`x-llm-d-inference-fairness-id` headers are set and that multiple distinct
IDs are in use.

<!-- SCREENSHOT: Jain's Fairness Index stat panel showing a value >= 0.95.
     Capture during Phase 4 of the live demo or Scenario 03.
     Save as: docs/images/fairness-jains-index-stat.png -->

#### Panel: Avg Wait Time by Tenant (timeseries)

**Metric:** `sum by(fairness_id) (rate(llm_d_epp_flow_control_request_queue_duration_seconds_sum{outcome="Dispatched"}[1m])) / sum by(fairness_id) (rate(llm_d_epp_flow_control_request_queue_duration_seconds_count{outcome="Dispatched"}[1m]))`

**What it shows:** Average time each tenant's requests spend waiting in the
queue before being dispatched.

**What good looks like:** Wait times are approximately equal across tenants.
Even the heavy sender (tenant-a) should not see dramatically different wait
times than the light sender (tenant-c).

#### Panel: TTFT p95 by Tenant (timeseries)

**Metric:** `histogram_quantile(0.95, sum by(le, fairness_id) (rate(llm_d_epp_request_ttft_seconds_bucket[1m])))`

**What it shows:** Time to first token at p95, broken out by tenant. This is
the user-facing impact of fairness -- do all tenants experience similar
responsiveness?

#### Panel: Queue Depth by Tenant (timeseries)

**Metric:** `sum by(fairness_id) (llm_d_epp_flow_control_queue_size)`

**What it shows:** How many requests from each tenant are currently queued.

**What good looks like:** The heavy sender (tenant-a) has a much deeper queue
than the light sender (tenant-c), but both are being dispatched at equal
rates. The heavy sender's excess requests simply wait longer.

---

### 4. vLLM Backend Health

**When to use:** When diagnosing backend-level issues. Use this when you
suspect the problem is with the model servers rather than flow control.

<!-- SCREENSHOT: Full vLLM Backend Health dashboard during moderate load.
     Save as: docs/images/dashboard-vllm-health-full.png -->

#### Panel: Running Requests per Pod (timeseries)

**Metric:** `vllm:num_requests_running`

**What it shows:** How many requests each vLLM pod is actively processing.

**What good looks like:** Both pods show similar request counts, indicating
the scheduling scorers are distributing work evenly.

**What bad looks like:** One pod has significantly more running requests than
the other. The queue-scorer weight may need adjustment, or one pod is slower
(check GPU throttling, OOM events).

#### Panel: Waiting Requests per Pod (timeseries)

**Metric:** `vllm:num_requests_waiting`

**What it shows:** How many requests are queued inside each vLLM pod's internal
engine queue (separate from the EPP flow control queue).

**What good looks like:** Near zero when flow control is enabled. The EPP
should be metering dispatch so that vLLM pods are not internally queuing.

**What bad looks like:** Persistently high waiting requests mean the EPP is
dispatching faster than the pods can process. Either `maxConcurrency` is set
too high, or the model is slower than expected.

#### Panel: KV Cache Utilization per Pod (timeseries)

**Metric:** `avg by(pod) (vllm:kv_cache_usage_perc)`

**What it shows:** What fraction of each pod's KV cache memory is in use. The
KV cache stores attention key-value pairs for in-flight requests.

| Utilization | Color | Meaning |
|-------------|-------|---------|
| 0 -- 0.69 | Green | Healthy. Plenty of cache available. |
| 0.70 -- 0.89 | Yellow | Getting warm. Long prompts may cause eviction. |
| 0.90 -- 1.0 | Red | Critical. Cache eviction is likely, degrading all requests. |

**What good looks like:** Both pods stay in the green zone under normal load.
The kv-cache-utilization-scorer in the scheduling profile should steer new
requests toward the pod with more free cache.

**What bad looks like:** One pod is red while the other is green. The
scheduling scorer is not weighting cache pressure enough, or one pod is
receiving requests with much larger prompts.

<!-- SCREENSHOT: KV Cache panel showing both pods in green/yellow range.
     Save as: docs/images/vllm-kv-cache-healthy.png -->

#### Panel: Token Throughput (timeseries)

**Metric:** `sum(rate(vllm:prompt_tokens_total[1m])) + sum(rate(vllm:generation_tokens_total[1m]))`

**What it shows:** Total tokens processed per second across all vLLM pods
(prompt + generation combined).

**What good looks like:** Throughput is stable and proportional to load. It
should rise with concurrency and plateau when the pool is saturated.

#### Panel: TTFT p95 from vLLM (timeseries)

**Metric:** `histogram_quantile(0.95, sum by(le) (rate(vllm:time_to_first_token_seconds_bucket[1m])))`

**What it shows:** Time to first token as measured by vLLM itself (not the
EPP). This excludes queue wait time, so it reflects pure model processing
latency.

**What to compare:** If EPP-reported TTFT is much higher than vLLM-reported
TTFT, the difference is queue wait time introduced by flow control. This gap
is expected under saturation and should be larger for lower tiers.

#### Panel: Ready Endpoints (timeseries)

**Metric:** `llm_d_epp_ready_endpoints`

**What it shows:** How many vLLM pods the EPP considers ready to receive
requests.

**What good looks like:** Matches your `VLLM_REPLICAS` count (2 in this PoC).

**What bad looks like:** Drops below expected count. A pod may be restarting,
OOM-killed, or failing health checks. When this drops, pool capacity decreases
and saturation is more likely.

---

## Reading the Signals: A Flow Control Lifecycle

This section walks through what you will see on the dashboards during a
typical flow control lifecycle, from idle to overload and back.

### State 1: Idle

**What is happening:** No client traffic or very low traffic. The pool is far
below its capacity.

**What you see:**
- Saturation gauge: **0.0** (green)
- Queue depth: **0** across all tiers
- Dispatch/rejection rates: **0** or negligible
- TTFT: Low and stable (just model processing time)
- vLLM running requests: **0** or very low
- KV cache: Near **0%**

**What it means:** The system is healthy and waiting for work. Flow control
exists but is not engaged because there is nothing to queue.

### State 2: Load Ramp (Approaching Saturation)

**What is happening:** Traffic is increasing. Backends are getting busier but
can still keep up.

**What you see:**
- Saturation gauge: **0.3 -- 0.7** (green/yellow), rising
- Queue depth: Still **0** -- requests are routed directly
- TTFT: Gradually increasing as backends get busier
- vLLM running requests: Rising proportionally
- KV cache: Climbing, proportional to concurrent requests

**What it means:** The system is absorbing load. Flow control is monitoring
saturation but not yet queuing anything.

### State 3: Steady Saturation (Priority Differentiation)

**What is happening:** Traffic exceeds pool capacity. Flow control is engaged
and actively managing the queue.

**What you see:**
- Saturation gauge: **1.0** (red)
- Queue depth: Tiers show differentiated depth -- premium low,
  standard moderate, batch high
- Dispatch rate: Premium dispatches are steady; standard and low-priority fill the
  remaining capacity
- Rejection rate: Low-priority tier may start rejecting if it hits its 50-slot limit
- TTFT: Clear separation -- premium lowest, standard middle, low-priority highest
- Queue wait time: Same tiered pattern

**What it means:** Flow control is working exactly as designed. Higher-priority
traffic is getting preferential access to the pool, and lower-priority traffic
is absorbing the pressure.

<!-- SCREENSHOT: Saturation Over Time panel showing the transition from 0 to 1.
     Capture a time range that includes the transition point.
     Annotate the exact moment saturation hits 1.0.
     Save as: docs/images/fc-saturation-transition.png -->

### State 4: Overload (Shedding)

**What is happening:** Traffic is significantly beyond pool capacity. The batch
tier's queue is full and requests are being rejected.

**What you see:**
- Saturation gauge: **1.0** (red)
- Queue depth: Low-priority tier at its `maxRequests` limit (50)
- Rejection rate: Low-priority tier shows sustained rejections. If overload is severe
  enough, standard tier may start rejecting too.
- Dispatch rate: Remains stable for premium; lower tiers show what they can
  manage
- TTFT: Premium should still be reasonable; batch TTFT is very high for
  requests that do get through

**What it means:** The pressure relief valve is working. Batch traffic is being
shed to protect higher-priority workloads. The batch processor retries with
backoff, so no work is lost -- it just takes longer.

**When to be concerned:** If premium rejections appear, the pool is severely
overwhelmed. Consider scaling vLLM replicas, reducing load, or increasing the
premium tier's `maxRequests`.

### State 5: Recovery

**What is happening:** Traffic has decreased. The pool is draining its queues.

**What you see:**
- Saturation gauge: Drops from **1.0** toward **0.0**
- Queue depth: All tiers drain to **0**
- Rejection rate: Returns to **0**
- TTFT: Drops back to baseline (model processing time only)
- Queue wait time: Drops to near **0**

**What it means:** The system recovers automatically. Once load is below
capacity, requests bypass the queue entirely and latency returns to normal.

**Recovery time:** How fast queues drain depends on how deep they were. A queue
of 50 batch requests drains in the time it takes the pool to process 50
requests (a few minutes). Recovery is faster for higher tiers because
the dispatch loop serves them first.

---

## Operational Runbook

### Queue depth is climbing and not draining

**Severity:** Warning (may escalate)

**Check:**
1. Are vLLM pods healthy? `kubectl get pods -n llm-d-poc -l app=vllm-nemotron-nano-9b`
2. Is the Ready Endpoints count dropping on the vLLM Health dashboard?
3. What is the KV cache utilization? If above 90%, pods may be thrashing.

**Likely cause:** Backends are too slow to drain the queue, either because
they are overloaded, unhealthy, or the `maxConcurrency` is set too high
(dispatching more than the pods can actually handle).

**Action:**
- If pods are unhealthy, investigate vLLM logs: `kubectl logs -n llm-d-poc -l app=vllm-nemotron-nano-9b --tail=50`
- If KV cache is critical, the scheduler should steer away -- check scorer
  weights in the scheduling profile.
- If the pool is simply undersized, scale up: `make scale-up` or increase
  `VLLM_REPLICAS`.

### Shed rate is high across all tiers

**Severity:** Critical

**Meaning:** The pool is overwhelmed. Every tier is hitting its `maxRequests`
limit or the global cap.

**Check:**
1. Is this a sustained state or a transient burst?
2. What is the total queue depth vs. the global `maxRequests` (500)?
3. Has a sudden traffic spike occurred (new client, runaway batch job)?

**Action:**
- Immediate: Identify and throttle the traffic source causing the overload.
- Short-term: Scale vLLM replicas if GPU nodes are available.
- Long-term: Re-evaluate `maxConcurrency` and tier allocations. If the pool
  oscillates between saturated and unsaturated during transient load ("queue
  chatter"), raising `headroom` from `0.0` to `0.1`--`0.2` raises the fixed
  threshold so flow control only engages when the pool is meaningfully over
  capacity. Note that headroom does not absorb bursts intelligently -- it
  simply raises the static threshold, so requests during the headroom window
  hit slightly overloaded backends rather than entering the queue.

### Premium latency is high despite having highest priority

**Severity:** High

**Check:**
1. Is the saturation gauge at 1.0? If not, flow control is not engaged and
   latency is purely a model issue.
2. Is the premium queue depth > 0? If yes, even high-priority traffic is
   backlogged.
3. Are `x-llm-d-inference-objective: realtime` headers present on the
   requests? Check EPP logs.
4. What does vLLM's own TTFT p95 show? If vLLM TTFT is also high, the
   problem is at the model server, not flow control.

**Action:**
- If headers are missing, fix the client configuration.
- If the premium queue has depth, the pool needs more capacity.
- If vLLM TTFT is high, check GPU utilization and KV cache pressure.

### Fairness index is low (< 0.8)

**Severity:** Medium

**Check:**
1. Are distinct `x-llm-d-inference-fairness-id` headers being set? Without
   them, all requests go to `default-flow` and the index is trivially 1.0
   (one queue is always "fair" with itself).
2. Is the pool saturated? Fairness only applies during saturation.
3. How many tenants are active? With only 2 tenants, minor dispatch
   imbalances have an outsized effect on the Jain index.

**Action:**
- Verify headers are set correctly on each traffic source.
- If the pool is not saturated, increase load or decrease `maxConcurrency`
  to trigger saturation (for demo/testing purposes).
- If the index is low with many tenants, check EPP logs for fairness
  policy errors.

### KV cache is critical on one pod while another is underutilized

**Severity:** Warning

**Check:**
1. What are the respective running request counts? The overloaded pod may
   be receiving more requests.
2. Are request prompt sizes uniform? One pod may be processing larger
   prompts that consume more cache.

**Action:**
- Increase the `kv-cache-utilization-scorer` weight relative to
  `queue-scorer` in the scheduling profile. This makes the EPP favor
  the pod with more free cache.
- If prompt sizes vary widely, consider using `concurrencyMode: hybrid`
  in the saturation detector.

---

## Key PromQL Queries

These queries are ready to paste into the Prometheus UI at
[http://localhost:9090](http://localhost:9090). Each includes context about
when to use it and how to interpret the result.

### Pool State

**Is the pool saturated right now?**
```promql
llm_d_epp_flow_control_pool_saturation
```
Returns 0-1. Values >= 1.0 mean flow control is engaged.

**Total queued requests across all tiers:**
```promql
sum(llm_d_epp_flow_control_queue_size)
```
If this equals your global `maxRequests` (500), new requests of any priority
will be rejected.

### Dispatch and Rejection

**Dispatch rate by tier (per second):**
```promql
sum by(priority) (rate(llm_d_epp_flow_control_requests_total{outcome="Dispatched"}[1m]))
```
Shows how fast each tier is draining.

**Rejection rate by tier (per second):**
```promql
sum by(priority) (rate(llm_d_epp_flow_control_requests_total{outcome!="Dispatched"}[1m]))
```
Any non-zero value on the premium tier (priority=100) is cause for concern.

**Dispatch rate by tenant (fairness check):**
```promql
sum by(fairness_id) (rate(llm_d_epp_flow_control_requests_total{outcome="Dispatched"}[1m]))
```
Under saturation with round-robin fairness, all tenants should show similar
dispatch rates.

### Latency

**TTFT p95 per tier:**
```promql
histogram_quantile(0.95, sum by(le, priority) (rate(llm_d_epp_request_ttft_seconds_bucket[1m])))
```
The primary user-facing latency metric. Compare across priorities to verify
isolation.

**TTFT p99 per tier:**
```promql
histogram_quantile(0.99, sum by(le, priority) (rate(llm_d_epp_request_ttft_seconds_bucket[1m])))
```
Tail latency. Useful for SLA verification.

**Queue wait time p95 per tier:**
```promql
histogram_quantile(0.95, sum by(le, priority) (rate(llm_d_epp_flow_control_request_queue_duration_seconds_bucket[1m])))
```
How long requests sit in the queue before dispatch. Should be near zero for
the premium tier.

**End-to-end request duration p95:**
```promql
histogram_quantile(0.95, sum by(le, priority) (rate(llm_d_epp_request_duration_seconds_bucket[1m])))
```
Total time from EPP receiving the request to completion. Includes queue wait +
model processing.

### Backend Health

**vLLM KV cache utilization (per pod):**
```promql
avg by(pod) (vllm:kv_cache_usage_perc)
```
Above 0.9 is critical. The kv-cache-utilization-scorer should steer work away.

**vLLM active vs waiting requests:**
```promql
sum(vllm:num_requests_running)
sum(vllm:num_requests_waiting)
```
With flow control, `num_requests_waiting` should be near zero because the EPP
meters dispatch.

**Total token throughput (tokens/sec):**
```promql
sum(rate(vllm:prompt_tokens_total[1m])) + sum(rate(vllm:generation_tokens_total[1m]))
```
Overall pool throughput. Should plateau during saturation and remain stable.

**Ready endpoint count:**
```promql
llm_d_epp_ready_endpoints
```
Should match your `VLLM_REPLICAS` count. A drop means a pod is unhealthy.

---

## Alerting Recommendations

These are suggested alert thresholds for a production deployment. Adapt the
values to your SLOs and traffic patterns.

| Alert | PromQL Condition | Severity | Duration | Notes |
|-------|-----------------|----------|----------|-------|
| Pool Saturated | `llm_d_epp_flow_control_pool_saturation >= 1.0` | Warning | 5m | Sustained saturation may indicate undersized pool |
| Premium Queue Depth | `llm_d_epp_flow_control_queue_size{priority="100"} > 10` | High | 1m | Premium traffic should not be backlogged |
| Premium Rejections | `rate(llm_d_epp_flow_control_requests_total{priority="100",outcome!="Dispatched"}[5m]) > 0` | Critical | 0m | Any premium rejection is a problem |
| High TTFT | `histogram_quantile(0.95, sum by(le) (rate(llm_d_epp_request_ttft_seconds_bucket{priority="100"}[5m]))) > 2` | High | 5m | Premium TTFT > 2s at p95 |
| KV Cache Critical | `avg by(pod) (vllm:kv_cache_usage_perc) > 0.9` | Warning | 2m | Cache eviction risk |
| Endpoint Down | `llm_d_epp_ready_endpoints < 2` | High | 1m | Fewer backends than expected |
| Global Queue Full | `sum(llm_d_epp_flow_control_queue_size) / 500 > 0.9` | Critical | 1m | Approaching global `maxRequests` cap |

---

## What to Read Next

- [Platform Engineer Guide](platform-engineer-guide.md) -- Configuration
  deep-dive and tuning reference.
- [Flow Control Primer](flow-control-primer.md) -- Conceptual overview of the
  3-tier dispatch hierarchy.
- [Architecture Guide](architecture.md) -- Component diagrams and request flow.
- [Live Demo Presenter Guide](../demo/PRESENTER-GUIDE.md) -- How to run and
  narrate a live flow control demo.
