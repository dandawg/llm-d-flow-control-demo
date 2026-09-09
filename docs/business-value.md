# The Business Case for Flow Control

This document is for the person who needs to answer: **"Why should we invest
in deploying flow control on our inference platform?"** It covers the
financial case, the operational case, the risk case, and the honest
limitations — so you can make an informed decision and sell it internally.

For technical details, see the [Flow Control Primer](flow-control-primer.md).
For deployment and configuration, see the
[Platform Engineer Guide](platform-engineer-guide.md).

---

## The Problem: GPUs Are Expensive and Shared Poorly

GPU inference is one of the most expensive line items in any AI platform
budget. A single A100 node costs $10-30/hr in the cloud. An H100 node can
exceed $40/hr. Most organizations run multiple models across multiple
environments, and the costs compound quickly.

The standard approach to managing this is **pool-per-workload**: give
interactive chat its own GPU cluster, give the API tier its own cluster, give
batch processing its own cluster. This is simple to reason about but
financially brutal:

- **Low utilization.** Each pool is sized for peak load, but peaks rarely
  align. The chat pool sits 80% idle at night. The batch pool sits idle
  during the day. You are paying for all of them all the time.
- **No burst absorption.** When one workload spikes, it cannot borrow
  capacity from an idle neighbor. You either over-provision (expensive) or
  accept degradation.
- **Operational sprawl.** Every pool is a separate deployment to monitor,
  patch, scale, and troubleshoot. The ops burden scales linearly with pool
  count.

Flow control solves this by letting you **consolidate workloads onto shared
GPU infrastructure** while still guaranteeing that high-priority traffic
gets served first. One pool. Multiple workload classes. Declarative
priority enforcement.

---

## The Value Proposition

### 1. Reduce GPU Spend Through Higher Utilization

The single biggest financial win from flow control is **GPU consolidation**.
Instead of running separate pools for each workload class, you run one pool
and let flow control manage contention.

**Example scenario:**

| Without Flow Control | With Flow Control |
|---------------------|-------------------|
| 3 separate pools (chat, API, batch) | 1 shared pool |
| Each sized for peak: 4 + 3 + 2 = 9 GPUs | Sized for combined peak: 5-6 GPUs |
| Average utilization: ~35% | Average utilization: ~70%+ |
| Monthly GPU cost: ~$15,000 | Monthly GPU cost: ~$9,000 |

The savings come from the fact that workload peaks rarely coincide. Chat peaks
during business hours. Batch runs overnight. API traffic is steady but
moderate. A shared pool exploits these natural complementary patterns.

**Conservative estimate:** Organizations can realistically see **30-50% reduction in
GPU spend** when consolidating from dedicated pools to a shared pool with
flow control, depending on workload mix and burst patterns.

### 2. Protect User Experience Under Pressure

Without flow control, a batch job burst can push interactive chat response
times from milliseconds to tens of seconds. Users see the application hang.
Support tickets spike. Trust erodes.

Flow control guarantees that **high-priority traffic is served first**,
regardless of what else is happening in the pool. During a batch burst:

- Interactive chat TTFT (time-to-first-token) stays low and stable
- API call latency remains within SLA bounds
- Batch absorbs all the pressure — it slows down, not the user-facing traffic

This is not a "best effort" mechanism. It is a strict dispatch hierarchy
enforced on every request. The premium tier is always served before standard,
which is always served before batch.

### 3. Enable Multi-Tenant Fairness

When multiple teams or customers share an inference pool, fairness is a
business requirement. Without it, a single noisy tenant can starve everyone
else.

Flow control's round-robin fairness policy ensures that **within a priority
tier, every tenant gets equal dispatch rate** regardless of how much traffic
they send. Tenant A sending 10x more requests than Tenant B does not mean
Tenant A gets 10x more service — they get equal turns.

This matters for:

- **Internal platforms** where multiple product teams share GPU resources
- **SaaS providers** serving multiple customers from the same model
- **Cost allocation** — fair dispatch makes chargeback accounting meaningful

### 4. Reduce Operational Complexity

**Fewer pools = fewer things to manage.** Consolidation reduces:

- Deployment configurations to maintain
- Monitoring dashboards to watch
- Scaling policies to tune
- Incident surfaces to triage

Flow control also provides **declarative policy** — priority tiers, fairness
rules, and capacity limits are expressed as Kubernetes CRDs and Helm values.
Changes are version-controlled, reviewable, and auditable. No custom code.
No application-level changes. Clients just set an HTTP header.

**Adding a new tenant requires no flow-control config changes.** The new
tenant's upstream service sets a fairness ID header, and the round-robin
policy automatically includes them. No CRDs to create, no deployments to
update. However, your upstream authentication/gateway layer must be
configured to assign the correct headers — clients should not be trusted
to set their own priority tier (see [Security](#security) below).

### 5. Bridge the Scaling Gap

Auto-scaling (HPA, Karpenter) takes 2-5 minutes to add GPU capacity. During
that window, what happens to your traffic?

Without flow control: everything degrades equally. Chat and batch compete
for the same overloaded backends.

With flow control: the queue absorbs the burst. High-priority traffic
continues to be served. Low-priority traffic waits (or is shed). When new
capacity comes online, the queue drains automatically.

Flow control does not replace scaling — it **buys you time** while scaling
acts, and ensures the right traffic is prioritized during the gap.

### 6. Unlock Batch-on-Shared-Infrastructure

Many organizations run batch inference on dedicated, always-on GPU clusters.
This is the most expensive way to process batch work because GPUs sit idle
between batch runs.

With flow control, batch processing can run on the same pool as interactive
traffic. Batch is configured as the lowest priority with a small queue limit.
It fills in around interactive traffic, consuming spare GPU capacity that
would otherwise go to waste. When interactive load increases, batch
automatically backs off.

**The result:** batch inference runs at near-zero marginal GPU cost, because
it uses capacity that is already paid for.

---

## When to Use Flow Control

Flow control is the right choice when:

| Condition | Why Flow Control Helps |
|-----------|----------------------|
| Multiple workload types share GPUs | Priority enforcement prevents low-value work from degrading high-value work |
| Multiple tenants share a pool | Fairness prevents noisy-neighbor starvation |
| You have interactive + batch workloads | Batch fills spare capacity without impacting interactive latency |
| GPU utilization is below 50% across isolated pools | Consolidation onto a shared pool raises utilization dramatically |
| You need SLA differentiation without physical isolation | Priority tiers provide soft SLA guarantees at lower cost than dedicated pools |
| Scaling lag causes user-facing degradation | Queue management bridges the gap while new capacity comes online |

---

## When to Use Something Else

Flow control is not always the answer. Here is when alternatives are better:

| Situation | Better Alternative | Why |
|-----------|--------------------|-----|
| **Hard SLA with contractual penalties** | Dedicated pool | Flow control provides best-effort priority, not guaranteed latency SLAs. If your contract says "p99 < 200ms or we pay a penalty," use dedicated infrastructure. |
| **Workloads need different models** | Multiple pools (one per model) | Flow control operates within a single InferencePool serving one model. Different models need different pools. |
| **Compliance/isolation requirements** | Dedicated pool or namespace isolation | If regulatory requirements mandate that tenant A's data never touches tenant B's GPU, flow control's shared pool does not satisfy that. |
| **Trivially low traffic** | Single pool, no flow control | If your pool never saturates, flow control adds zero value. It only engages under saturation. |
| **All traffic is identical priority** | No flow control needed | If there is no differentiation to enforce, flow control is overhead without benefit. |

---

## What Flow Control Does Not Replace

Flow control is one layer in your inference platform — here is what it does NOT
handle and what you still need:

### Capacity Planning and Scaling

Flow control manages dispatch within a fixed pool. It does not add GPUs.
You still need:

- Right-sized GPU nodes for your model (A10 vs. A100 vs. H100)
- Horizontal pod autoscaling for demand-driven scaling
- Cost monitoring and scale-down automation for off-peak hours

### QoS Tier Design

Flow control enforces your priority tiers, but **you** must decide:

- How many tiers and what they are called
- Which customers or workloads go in which tier
- What the capacity allocations (maxRequests) should be per tier

This is a business and product decision, not a technical one. Flow control
gives you the mechanism; you supply the policy.

### Alerting and Incident Response

Flow control produces rich metrics (queue depth, dispatch rate, rejection
rate, saturation, per-tenant fairness). But you must:

- Build alerts on these metrics (see the [Operator Guide](operator-guide.md)
  for recommendations)
- Write runbooks for when alerts fire
- Staff on-call for inference platform issues

### Client Behavior

Flow control relies on clients to:

- Set the correct HTTP headers (or have an upstream gateway do it)
- Handle HTTP 429 responses gracefully (retry with backoff)
- Respect reasonable prompt length and output token limits

Poorly-behaved clients can still cause problems. Flow control manages the
queue, not the clients feeding it.

### Security

Flow control headers are trusted. You need an authentication and
authorization layer upstream of the inference gateway. Without it, any
client can claim any priority tier.

---

## The ROI Framework

### Cost to Implement

| Item | Estimate |
|------|----------|
| Platform engineer time to deploy and tune | 2-5 days (using this PoC as a starting point) |
| Ongoing operational overhead | Minimal — config is declarative; new tenants require no flow-control config changes, but your upstream auth/gateway layer must be updated to assign correct headers |
| Additional infrastructure cost | None — flow control runs in the EPP, which is already required for llm-d routing |

### Cost Savings

| Source | How to Estimate |
|--------|----------------|
| GPU consolidation | Count your current separate pools. Estimate combined peak. The difference in GPU-hours is your savings. |
| Reduced over-provisioning | Measure current average utilization per pool. The gap between peak-provisioned and average-used is waste. |
| Batch-on-shared-infrastructure | If batch currently runs on dedicated GPUs, the entire batch GPU cost becomes savings (batch now runs on spare capacity). |

### Risk Reduction

| Risk Mitigated | Value |
|----------------|-------|
| User-facing degradation from batch bursts | Reduced support tickets, preserved user trust |
| Noisy-neighbor starvation in multi-tenant platforms | Fair access prevents churn and escalations |
| Scaling-lag degradation | Priority queuing bridges the gap, reducing P1 incidents |

### Strategic Value

| Benefit | Impact |
|---------|--------|
| Faster tenant onboarding | No flow-control config changes needed per tenant; gateway/auth layer handles identity and header assignment |
| Declarative policy | Auditable, version-controlled QoS decisions |
| Foundation for SLA tiers | Enables pricing differentiation (premium tier = highest priority) |

---

## Frequently Asked Questions from Stakeholders

### "How much money will this save us?"

The primary savings come from GPU consolidation. If you currently run N
separate pools and can consolidate to fewer shared pools, the savings are
roughly proportional to the utilization improvement. A typical org running
3 pools at 35% average utilization can consolidate to 1 pool at 70%+
utilization — roughly halving GPU spend for those workloads.

Batch-on-shared-infrastructure is the second lever: if batch currently has
dedicated GPUs, that entire cost goes away (batch runs on spare interactive
capacity).

### "What is the risk of deploying this?"

Flow control is:
- **Fail-open** — if the EPP goes down, the gateway routes directly to
  backends. You lose priority ordering but do not lose traffic.
- **Zero overhead below saturation** — when the pool is not saturated,
  requests bypass the queue entirely. There is no added latency.
- **Configurable via feature gate** — the entire mechanism can be disabled
  by removing a single line from the Helm values. Rollback takes seconds.

### "What if it breaks?"

The InferencePool is configured with `failureMode: FailOpen`. If the EPP
crashes or becomes unavailable, the Envoy gateway bypasses it and routes
requests directly to vLLM backends. You lose flow control (no priority,
no fairness, no queuing) but traffic keeps flowing. This degrades
gracefully to the "no flow control" state, which is what you have today.

### "Can we try it without committing?"

Yes. This PoC repository is designed for exactly this:

1. Deploy the full stack (30 minutes)
2. Run the benchmark scenarios to see flow control in action
3. Run the live demo to visualize the behavior
4. Compare "flow control on" vs "flow control off" using the toggle scripts

Total cost for a proof-of-concept: ~$2.50/hr for the EKS cluster, for
as long as you want to experiment. Scale to zero when done.

### "How long until we see value?"

- **Day 1:** Flow control is deployed and enforcing priorities.
- **Week 1:** Operators have dashboards showing priority differentiation,
  fairness metrics, and low-priority shedding behavior.
- **Month 1:** GPU consolidation savings are measurable (compare current
  multi-pool spend to projected single-pool spend).
- **Ongoing:** Every new workload or tenant added to the shared pool
  increases utilization and amortizes the fixed GPU cost further.

### "Does this work with our existing infrastructure?"

Flow control runs within the llm-d Endpoint Picker Plugin on Kubernetes.
If you are already running inference on Kubernetes with llm-d, adding flow
control is a configuration change. If you are on a different serving stack,
the concepts transfer but the implementation may differ.

---

## What to Read Next

- [Flow Control Primer](flow-control-primer.md) — Technical deep-dive into
  how the 3-tier dispatch hierarchy works.
- [Architecture Guide](architecture.md) — Component overview and request
  flow diagrams.
- [Platform Engineer Guide](platform-engineer-guide.md) — How to configure,
  tune, and customize flow control.
- [Operator Guide](operator-guide.md) — Dashboard tour, signal reading, and
  operational runbooks.
