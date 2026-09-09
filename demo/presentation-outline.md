# Presentation Outline: llm-d Flow Control

**Target length:** 20-25 minutes (plus optional live demo)
**Audience:** Mixed — engineering leadership, platform engineers, ops engineers, solution architects
**Goal:** Convince the audience that flow control is worth implementing, then show them how it works.

---

## Slide Sequence

### Section 1: The Problem (3-4 slides, ~5 min)

#### Slide 1 — Title
**llm-d Flow Control: Priority, Fairness, and Cost Efficiency for Shared GPU Inference**

- Subtitle: Turning expensive GPU pools into multi-workload platforms
- Your name / team / date

#### Slide 2 — The GPU Cost Problem
**GPUs are expensive. Most organizations use them poorly.**

- Key stat: average GPU utilization across isolated pools is 30-40%
- Visual: 3 separate pools (chat, API, batch), each sized for peak, mostly idle
- Callout: "You are paying for peak capacity 24/7 but using it 35% of the time"

**Speaker notes:** Open with the cost pain. Every stakeholder in the room feels this. Frame it as a solvable infrastructure problem, not a model problem.

#### Slide 3 — The Sharing Problem
**Sharing GPUs is obvious. Sharing them safely is not.**

- Without isolation: a batch burst pushes interactive chat latency from 200ms → 15 seconds
- Visual: timeline showing batch burst, TTFT spike for all traffic, user impact
- Callout: "Pool-per-workload is safe but wasteful. Shared pools are efficient but dangerous."

**Speaker notes:** This is the tension. Everyone knows consolidation saves money. The question is: can you consolidate without degrading user experience? That is the problem flow control solves.

#### Slide 4 — What We Need
**A shared pool that behaves like dedicated pools.**

- Priority: premium tier gets served first, always
- Fairness: no tenant can starve another
- Isolation: batch work cannot degrade interactive traffic
- Efficiency: batch fills spare capacity at near-zero marginal cost
- Callout: "This is what flow control delivers."

---

### Section 2: How Flow Control Works (4-5 slides, ~5 min)

#### Slide 5 — Flow Control in One Diagram
**Centralized priority queuing at the gateway layer**

- Visual: simplified request flow — Client → Gateway → EPP (queue) → vLLM
- Key point: the EPP sits between the gateway and backends, adding a policy-aware dispatch layer
- Below saturation: requests pass straight through (zero overhead)
- At saturation: requests enter priority queues

**Speaker notes:** Emphasize that flow control is invisible when the pool is healthy. It only activates under pressure — which is exactly when you need it.

#### Slide 6 — The 3-Tier Dispatch Hierarchy
**Priority → Fairness → Ordering**

- Tier 1 — Priority: scan tiers top-down (premium → standard → batch)
- Tier 2 — Fairness: round-robin across tenants within a tier
- Tier 3 — Ordering: first-come-first-served within a tenant queue
- Visual: nested hierarchy diagram

**Speaker notes:** Keep this conceptual. The audience needs to understand the dispatch order, not the implementation details. Stress that priority is strict — higher bands are always served first.

#### Slide 7 — Priority Tiers
**Declarative workload classification**

- Three tiers: premium (priority 100) / standard (priority 0) / batch (priority -1)
- Set via a single HTTP header: `x-llm-d-inference-objective`
- No application code changes — middleware injects the header
- Configurable: add tiers, change priorities, adjust capacity — all via Helm values

**Speaker notes:** This is the "how do I use it?" slide. The answer is: set a header. The EPP does the rest.

#### Slide 8 — Batch as a Pressure Relief Valve
**Low-priority work fills spare capacity and backs off under pressure**

- Low-priority band: lowest priority, smallest queue (50 slots)
- When pool is busy: batch requests are shed (HTTP 429), processor retries with backoff
- When pool has spare capacity: batch runs at full speed
- Callout: "Batch inference at near-zero marginal GPU cost"

**Speaker notes:** This is one of the most compelling value props for leadership. Batch work that used to need its own GPU cluster now runs for free on spare interactive capacity.

#### Slide 9 — What Happens at Saturation (Optional — for Technical Audiences)
**The dispatch loop in action**

- Visual: animated or step-by-step walkthrough of a saturated pool
  1. Request arrives, pool is saturated
  2. Assigned to priority band based on header
  3. Placed in tenant fairness queue
  4. Dispatch loop scans top-down, round-robin, FCFS
  5. Winner is routed to best-scoring backend

**Speaker notes:** Only include this for engineering-heavy audiences. For exec audiences, skip to the value section.

---

### Section 3: The Business Value (3-4 slides, ~5 min)

#### Slide 10 — Financial Impact
**Consolidation reduces GPU spend by 30-50%**

- Before: 3 pools × peak sizing = 9 GPUs, 35% avg utilization
- After: 1 shared pool = 5-6 GPUs, 70%+ avg utilization
- Additional: batch-on-shared-infra eliminates dedicated batch GPU cost
- Visual: side-by-side cost comparison (monthly or annual)

**Speaker notes:** Use your org's actual numbers if available. Even a rough estimate is more compelling than a generic percentage. Frame as: "Every GPU we eliminate saves $X,000/month."

#### Slide 11 — Operational Impact
**Fewer pools. Less ops burden. Faster tenant onboarding.**

- One pool to monitor, scale, patch, and troubleshoot (instead of N)
- Adding a new tenant: zero config changes (just set a header)
- Declarative policy: priority tiers are version-controlled YAML, not custom code
- Full observability: Grafana dashboards for saturation, dispatch, fairness, per-tenant metrics

**Speaker notes:** This resonates with platform and ops teams. Fewer moving parts = fewer incidents = less on-call pain.

#### Slide 12 — Risk Reduction
**Flow control protects revenue-generating traffic**

- Interactive chat latency stays low during batch bursts (proven in benchmarks)
- Multi-tenant fairness prevents noisy-neighbor starvation
- Scaling-lag bridge: queue absorbs demand while new GPUs spin up (2-5 min)
- Fail-open design: if the EPP goes down, traffic routes directly to backends — no outage

**Speaker notes:** "The question is not whether you can afford to implement flow control. The question is whether you can afford not to, when a batch burst tanks your chat latency and users leave."

#### Slide 13 — When to Use Flow Control (and When Not To)
**Right tool for the right job**

- Use when: shared GPUs, multiple workloads or tenants, batch + interactive, scaling lag
- Don't use when: hard SLA with contractual penalties (use dedicated), compliance isolation, trivially low traffic
- Callout: "Flow control is for soft QoS differentiation on shared infrastructure. Dedicated pools are for hard isolation."

**Speaker notes:** Being honest about limitations builds trust. Show that you understand the tradeoffs.

---

### Section 4: Platform and Ops Perspectives (2-3 slides, ~3 min)

#### Slide 14 — Platform Engineer View
**What you configure and how**

- Configuration lives in EPP Helm values (one file)
- Key knobs: maxConcurrency, priority bands, fairness policy, TTL
- Customization: add tiers, change priorities, adjust capacity — all declarative
- Day 2: adding tenants is zero-touch; config changes require EPP restart (~10s, fail-open)

**Speaker notes:** Platform engineers want to know: how hard is this to set up and maintain? Answer: one Helm values file, a few well-documented knobs, and it's done.

#### Slide 15 — Ops Engineer View
**What you monitor and how you respond**

- 4 Grafana dashboards: Flow Control Overview, Latency by Tier, Fairness Analysis, vLLM Health
- Key signals: saturation gauge, queue depth by tier (premium/standard/batch), dispatch/rejection rates, per-tenant fairness
- Runbook scenarios: queue not draining, premium latency high, all tiers shedding
- Alerting: suggested thresholds included (see Operator Guide)

**Speaker notes:** Ops engineers want to know: will this wake me up at 3am? Answer: flow control makes problems more visible and manageable. You get signals you did not have before, and runbooks to act on them.

#### Slide 16 — What You Still Need to Do
**Flow control is one layer, not the whole stack**

- You still own: capacity planning, scaling, GPU selection, model tuning, alerting, client behavior, security
- Flow control gives you: dispatch-time priority and fairness within a running pool
- Think of it as: the traffic management layer between "demand exceeds supply" and "new supply comes online"

**Speaker notes:** Setting expectations correctly avoids disappointment. Flow control is not magic — it is a well-scoped mechanism that does one thing very well.

---

### Section 5: Live Demo or Recorded Walkthrough (Optional, ~8 min)

#### Slide 17 — Demo Setup
**One pool. Three workload classes. Two tenants. Full observability.**

- What we will show: warm-up → saturation → priority → fairness → batch burst → recovery
- Side-by-side: terminal running the demo script + Grafana dashboards
- Runtime: ~8 minutes

**Speaker notes:** If running live, use `demo/live-demo.sh` with the Presenter Guide. If time-constrained, use screenshots from a previous run or a recording. See [PRESENTER-GUIDE.md](PRESENTER-GUIDE.md) for full narration.

*(Phases 1-6 follow the existing Presenter Guide — no separate slides needed, this is a live narration over Grafana dashboards.)*

---

### Section 6: Wrap-Up (1-2 slides, ~2 min)

#### Slide 18 — Key Takeaways

1. **Flow control lets you consolidate GPU pools safely** — 30-50% cost reduction
2. **Priority is strict and declarative** — premium tier always served first, configured in YAML
3. **Fairness is automatic** — round-robin prevents noisy-neighbor starvation
4. **Batch runs for free** on spare interactive capacity
5. **Zero overhead below saturation** — flow control is invisible when the pool is healthy
6. **Fail-open design** — no flow control failure causes an outage

#### Slide 19 — Next Steps / Call to Action

- **Try it:** Deploy this PoC in 30 minutes, run the benchmarks, see it work
- **Evaluate:** Compare your current multi-pool spend to projected single-pool spend
- **Plan:** Identify workloads to consolidate, define priority tiers, instrument headers
- **Links:** GitHub repo, docs, Flow Control Primer, Business Value Guide

---

## Appendix Slides (backup, for Q&A)

#### A1 — Overhead Measurement
- Scenario 00 (no FC) vs. Scenario 01 (FC enabled, not saturated)
- Measured overhead: single-digit milliseconds
- Visual: TTFT comparison chart

#### A2 — Saturation Detection Details
- Concurrency detector: instantaneous per-request check, not a moving average
- maxConcurrency × endpoints = pool capacity threshold
- Headroom: raises threshold to prevent queue chatter (not intelligent burst detection)

#### A3 — Fairness Deep-Dive
- Jain's Fairness Index definition and interpretation
- Round-robin vs. weighted fair queuing
- Current limitation: no historical fairness / compensation

#### A4 — Complementary Technologies
- Table: flow control + HPA/Karpenter + client-side retry + gateway rate limiting + dedicated pools + Kueue
- How each layer interacts with flow control

#### A5 — Known Limitations
- No preemption of in-flight requests
- No priority aging / starvation protection
- Static config (no time-of-day scheduling built in)
- No historical fairness tracking
- Headers are trusted (need auth layer upstream)

---

## Adapting This Outline

### For Executive Audiences (15 min)
Use slides 1-4, 10-13, 18-19. Skip technical details. Focus on cost, risk, and strategic value.

### For Engineering Audiences (25 min + demo)
Use all slides. Include slide 9. Run the live demo.

### For Ops Audiences (20 min)
Use slides 1-4, 5-8, 15-16, 18-19. Spend extra time on slide 15 (dashboards and signals). Show Grafana screenshots.

### For a Lightning Talk (5 min)
Use slides 2, 3, 5, 10, 18. One sentence per slide. End with the repo link.
