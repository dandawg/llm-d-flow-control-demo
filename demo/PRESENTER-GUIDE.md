# Live Demo Presenter Guide

This guide is your companion while running `demo/live-demo.sh`. It tells you
exactly what to say, what to show, and what to point out at each phase.

---

## Before You Start

### Setup Checklist

- [ ] Cluster is running: `make cluster-status`
- [ ] Full stack deployed: `make verify` (all checks pass)
- [ ] Port-forwards running: `make observability-port-forward`
- [ ] Grafana open in a browser: [http://localhost:3000](http://localhost:3000)
- [ ] Logged into Grafana (admin / admin)
- [ ] **Flow Control Overview** dashboard loaded and visible
- [ ] Grafana time range set to **Last 30 minutes** with **10s auto-refresh**
- [ ] Terminal visible alongside Grafana (split screen or second monitor)
- [ ] `aiperf` available: `which aiperf` (install with `uv sync`)

### Recommended Screen Layout

```
┌──────────────────────┬──────────────────────┐
│                      │                      │
│   Terminal           │   Grafana            │
│   (running the       │   (Flow Control      │
│    demo script)      │    Overview)         │
│                      │                      │
└──────────────────────┴──────────────────────┘
```

If you have a second monitor, put Grafana full-screen on the audience-facing
display and keep the terminal on your laptop.

### Quick Pre-Demo Dry Run

If this is your first time, do a quick test run with shortened durations:

```bash
PHASE_1_DURATION=10 PHASE_2_DURATION=15 PHASE_3_DURATION=20 \
PHASE_4_DURATION=20 PHASE_5_DURATION=20 PHASE_6_DURATION=10 \
PAUSE_BETWEEN=5 ./demo/live-demo.sh
```

This runs the full sequence in about 2 minutes so you can verify everything
works before the real presentation.

---

## Running the Demo

```bash
./demo/live-demo.sh
```

The script will:
1. Verify the deployment is healthy (smoke test).
2. Reset Prometheus and Grafana annotations for a clean slate.
3. Run through 6 phases, printing banners and pausing between each.

**Total runtime:** ~8 minutes with default durations. Adjust with environment
variables (see the script header for all options).

---

## Phase-by-Phase Guide

### Phase 1: Warm-Up (30 seconds)

**Traffic:** Single stream, standard priority, concurrency 5.

**Dashboard:** Flow Control Overview

**What to say:**

> "This is a healthy inference pool with no pressure. We are sending a light
> trickle of standard-tier requests. Look at the saturation gauge -- it is
> green, near zero. Queue depth across all tiers is flat at zero.
> TTFT is low and stable. Requests are flowing straight through to the model
> servers without any queuing."
>
> "This is what the system looks like when demand is well within capacity.
> Flow control exists but is invisible -- it only engages when the pool is
> saturated."

**What to point out on screen:**
- Saturation gauge: green, near 0
- Queue depth: all bands at 0
- vLLM running requests: low single digits

<!-- SCREENSHOT: Flow Control Overview during Phase 1.
     Saturation gauge green, all queue depths at zero.
     Save as: docs/images/demo-phase1-idle.png -->

---

### Phase 2: Ramp to Saturation (60 seconds)

**Traffic:** Single stream, standard priority, concurrency 25.

**Dashboard:** Flow Control Overview

**What to say:**

> "Now we are ramping up. Same tier, but much more traffic -- 25
> concurrent requests against a pool sized for about 30. Watch the saturation
> gauge..."
>
> *(wait for the gauge to turn red)*
>
> "There it is. The pool just hit saturation. The saturation gauge crossed 1.0
> and turned red. Now look at the Queue Depth by Tier panel -- the standard
> tier queue is climbing. Flow control just engaged."
>
> "This is the key transition. Before saturation, requests went straight to
> backends. Now they enter a priority queue. Every request is evaluated --
> what priority band does it belong to? Which tenant is it from? -- before
> being dispatched."

**What to point out on screen:**
- Saturation gauge transitions from green to red
- Queue depth for standard tier starts climbing
- TTFT increases (switch briefly to Latency by Tier if you want to show this)

**Timing tip:** The transition usually happens within the first 15-20 seconds.
If it has not appeared after 30 seconds, say "The pool is warming up -- with a
real model, saturation depends on prompt complexity and output length."

<!-- SCREENSHOT: Flow Control Overview as saturation transitions from green to red.
     Capture the moment the gauge crosses the threshold.
     Save as: docs/images/demo-phase2-saturation-transition.png -->

---

### Phase 3: Priority Differentiation (90 seconds)

**Traffic:** Realtime (concurrency 10) + Standard (concurrency 25).

**Dashboard:** Latency by Tier (switch to this at the start of the phase)

**What to say:**

> "Now we add a second traffic class. Premium-tier traffic is entering
> alongside the existing standard traffic. Both are competing for the same
> two GPU backends."
>
> "Switch to the Latency by Tier dashboard. Watch the TTFT panels..."
>
> *(wait for separation to appear, usually 20-30 seconds)*
>
> "See the separation? The premium line is consistently LOWER than the
> standard line. Both tiers are hitting a saturated pool, but premium
> requests are dispatched first. Standard requests wait in the queue until
> there is capacity left over."
>
> "This is priority in action. The dispatch loop scans from highest priority
> to lowest. Premium requests at the front of the line, standard requests
> wait their turn."

**What to point out on screen:**
- TTFT p50 and p95 panels: premium line below standard line
- Queue depth: premium queue should be minimal; standard queue deeper
- Switch briefly to Flow Control Overview to show Queue Depth by Tier

**Key talking point:** "Notice that the premium TTFT is not just 'a little'
lower -- it is substantially lower. That gap is the queue wait time that
standard requests absorb so that premium requests do not have to."

<!-- SCREENSHOT: Latency by Tier TTFT p95 panel showing clear separation.
     Premium line should be visibly below the standard line.
     Annotate the gap between the two lines.
     Save as: docs/images/demo-phase3-ttft-separation.png -->

<!-- SCREENSHOT: Flow Control Overview Queue Depth by Tier panel during Phase 3.
     Premium queue near zero, standard queue elevated.
     Save as: docs/images/demo-phase3-queue-depth.png -->

---

### Phase 4: Intra-Tier Fairness (90 seconds)

**Traffic:** Realtime (10) + Tenant-A standard (25) + Tenant-B standard (5).

**Dashboard:** Fairness Analysis (switch to this — it filters out `default-flow`
to show only explicitly labeled tenants)

> **Note:** The realtime stream continues running to keep the pool saturated.
> It has no explicit tenant header, so the EPP assigns it to `default-flow`.
> Earlier demo phases also create `default-flow` entries in the standard band
> (Phases 1, 2, 3, 5, 6 send standard traffic without a fairness header).
> The Fairness Analysis dashboard excludes `default-flow` so these background
> entries do not contaminate the Jain's Fairness Index calculation. You will
> only see explicitly labeled tenants (`tenant-a`, `tenant-b`).

**What to say:**

> "Now let us look at fairness within a tier. We still have premium
> traffic running to keep the pool saturated, but now the standard tier has
> two tenants. Tenant A is sending five times more traffic than Tenant B."
>
> "Without fairness, Tenant A would dominate. Their requests would fill the
> queue and crowd out Tenant B. Switch to the Fairness Analysis dashboard..."
>
> *(wait for data to populate, 20-30 seconds)*
>
> "Look at the Dispatch Count by Tenant panel. Despite Tenant A sending 5x
> more requests, both tenants are getting dispatched at approximately the
> SAME rate. That is the round-robin fairness policy at work."
>
> "The dispatch loop alternates: one from Tenant A, one from Tenant B, one
> from A, one from B. Tenant A's excess requests simply wait in their queue
> longer."
>
> "Now look at Jain's Fairness Index -- it should be near 1.0, which means
> perfectly fair. This is what multi-tenant equity looks like."

**What to point out on screen:**
- Dispatch Count by Tenant: lines converging to similar values
- Jain's Fairness Index: value near 1.0 (green)
- Queue Depth by Tenant: Tenant A's queue is deeper (more requests waiting)
  while Tenant B's is shallow

**Key talking point:** "This matters because in a shared inference pool, you
do not want one noisy tenant to starve everyone else. Round-robin ensures
every tenant gets fair access to the capacity they are entitled to within
their priority band."

<!-- SCREENSHOT: Fairness Analysis Dispatch Count panel showing equal dispatch.
     Both tenant lines at similar heights.
     Save as: docs/images/demo-phase4-fairness-dispatch.png -->

<!-- SCREENSHOT: Jain's Fairness Index stat panel showing >= 0.95.
     Save as: docs/images/demo-phase4-jains-index.png -->

---

### Phase 5: Batch Burst (90 seconds)

**Traffic:** Realtime (10) + Standard (15) + Low-Priority (30).

**Dashboard:** Flow Control Overview (switch back)

**What to say:**

> "Final stress test. We are keeping premium and standard traffic, and now
> dumping a large batch workload -- 30 concurrent low-priority requests. Remember,
> the low-priority tier only has 50 queue slots."
>
> *(wait for batch metrics to appear, 15-20 seconds)*
>
> "Look at the Queue Depth by Tier panel. The low-priority tier just hit its cap
> at 50 queued requests. Now look at the Rejection Rate by Tier panel..."
>
> "Low-priority rejections are spiking. The 51st low-priority request gets an immediate
> HTTP 429. This is the pressure relief valve. The low-priority tier is
> deliberately small because low-priority work is expendable under pressure."
>
> "Now -- this is the critical part -- look at the premium and standard
> lines on the rejection panel. They are at ZERO. No premium or standard
> requests are being rejected. The batch traffic is absorbing all the pain."
>
> "Switch to Latency by Tier. See the premium TTFT? Still low. It does not
> care about the low-priority burst. Priority insulation is working."

**What to point out on screen:**
- Queue depth: low-priority tier at 50 (its maxRequests limit)
- Rejection rate: low-priority tier spiking, premium and standard at zero
- Latency by Tier: premium TTFT unchanged by the low-priority burst
- Dispatch rate: premium and standard steady; low-priority gets whatever is left

**Key talking point:** "In a real deployment, the batch processor retries
rejected requests with exponential backoff. Batch work fills in around
interactive traffic -- it consumes spare capacity and backs off when none is
available. No work is lost, it just takes longer."

<!-- SCREENSHOT: Flow Control Overview during Phase 5.
     Low-priority queue depth at cap, rejection rate spiking for low-priority,
     premium/standard rejection at zero.
     Save as: docs/images/demo-phase5-batch-shedding.png -->

<!-- SCREENSHOT: Latency by Tier TTFT during Phase 5.
     Premium TTFT should be similar to Phase 3 -- unaffected by low-priority burst.
     Save as: docs/images/demo-phase5-premium-insulated.png -->

---

### Phase 6: Recovery (60 seconds)

**Traffic:** Single stream, standard priority, concurrency 5.

**Dashboard:** Flow Control Overview

**What to say:**

> "Now we remove all the pressure. Just a light trickle of standard traffic
> remains. Watch the recovery..."
>
> *(wait for metrics to drop, 15-30 seconds)*
>
> "The saturation gauge drops back to green. Queue depths fall to zero across
> all bands. Rejection rate goes back to zero. TTFT returns to baseline."
>
> "The system recovers automatically. There is nothing to do operationally --
> no caches to clear, no queues to flush, no restart needed. When load
> decreases, flow control steps aside and requests flow straight through
> to backends again."

**What to point out on screen:**
- Saturation gauge: transitions back to green
- Queue depth: all bands drain to zero
- Rejection rate: returns to zero
- Compare the current TTFT to Phase 1 -- should be nearly identical

<!-- SCREENSHOT: Flow Control Overview after recovery.
     Everything back to green/zero, similar to Phase 1.
     Save as: docs/images/demo-phase6-recovery.png -->

---

## After the Demo

### Wrapping Up

> "So what did we just see? A single inference pool, shared by multiple traffic
> classes and multiple tenants, handling everything from real-time chat to bulk
> batch processing. Flow control gave us three things:
>
> 1. **Priority** -- Premium traffic was always served first, even under
>    extreme pressure.
> 2. **Fairness** -- Tenants within the same tier got equal access regardless
>    of how much traffic they sent.
> 3. **Isolation** -- A massive low-priority burst had zero impact on premium
>    traffic.
>
> And all of this is configured declaratively. Three InferenceObjective CRDs
> and a few YAML settings in the EPP Helm values. No application code changes.
> Clients just set an HTTP header."

### Common Audience Questions

**"What happens without flow control?"**
> "Without flow control, all requests compete equally. A low-priority burst would push
> premium chat into per-pod queues and latency would spike for everyone. We
> have a baseline scenario (Scenario 00 vs 01) that quantifies the overhead --
> it is typically single-digit millisecond."

**"Can I add more priority tiers?"**
> "Yes. Just add more InferenceObjective CRDs and matching priority bands.
> The dispatch loop scans from highest to lowest. We used 3 tiers for
> simplicity, but you could have 5 or 6 for different SLA levels."

**"What if a pod goes down during saturation?"**
> "The EPP detects it immediately via the Ready Endpoints metric. Pool capacity
> drops, saturation intensifies, and the queue absorbs the shock. Batch gets
> shed first. When the pod comes back, capacity increases and queues drain."

**"How much latency does flow control add?"**
> "Below saturation: effectively zero -- requests skip the queue entirely.
> Under saturation: it depends on priority. Realtime requests see minimal
> added latency because they are dispatched first. Lower-priority requests
> absorb proportionally more."

---

## Timing Reference

| Phase | Default Duration | Purpose |
|-------|-----------------|---------|
| 1: Warm-Up | 30s | Establish baseline |
| Pause | 10s | Transition |
| 2: Ramp to Saturation | 60s | Show saturation engaging |
| Pause | 10s | Transition |
| 3: Priority | 90s | Show tier differentiation |
| Pause | 10s | Transition |
| 4: Fairness | 90s | Show tenant equity |
| Pause | 10s | Transition |
| 5: Batch Burst | 90s | Show shedding and isolation |
| Pause | 10s | Transition |
| 6: Recovery | 60s | Show automatic recovery |
| **Total** | **~7m 50s** | |

### Shortening the Demo

For a 5-minute version, use:
```bash
PHASE_1_DURATION=20 PHASE_2_DURATION=40 PHASE_3_DURATION=60 \
PHASE_4_DURATION=60 PHASE_5_DURATION=60 PHASE_6_DURATION=30 \
PAUSE_BETWEEN=5 ./demo/live-demo.sh
```

For a 3-minute lightning version (skip fairness):
```bash
PHASE_1_DURATION=15 PHASE_2_DURATION=30 PHASE_3_DURATION=45 \
PHASE_4_DURATION=0 PHASE_5_DURATION=45 PHASE_6_DURATION=20 \
PAUSE_BETWEEN=3 ./demo/live-demo.sh
```

Note: Setting a phase duration to 0 effectively skips it (streams launch and
immediately terminate).

### Extending the Demo

For a longer presentation with more narration time:
```bash
PHASE_1_DURATION=45 PHASE_2_DURATION=90 PHASE_3_DURATION=120 \
PHASE_4_DURATION=120 PHASE_5_DURATION=120 PHASE_6_DURATION=90 \
PAUSE_BETWEEN=20 ./demo/live-demo.sh
```

---

## Contingencies

### Pool does not saturate in Phase 2

**Cause:** `maxConcurrency` may be set too high, or the model is faster than
expected on your hardware.

**Quick fix:** Increase the stream concurrency by restarting the demo:
```bash
# Edit the concurrency in the script or just re-run the appropriate benchmark
# to generate enough load
```

Alternatively, lower `maxConcurrency` in the EPP values and redeploy:
```bash
# In epp-values.yaml, change maxConcurrency from 15 to 10
./deployment/03-llm-d-router/install-router.sh
sleep 30
# Restart the demo
```

### aiperf errors or crashes

**Cause:** Usually a connection issue or the gateway is not ready.

**Quick fix:**
```bash
# Verify gateway is accessible
curl http://${GATEWAY_IP}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"nvidia/NVIDIA-Nemotron-Nano-9B-v2","messages":[{"role":"user","content":"test"}],"max_tokens":1}'

# If it fails, check the gateway and EPP
make verify
```

### Grafana shows no data

**Cause:** Port-forward may have died, or Prometheus was reset and has not
scraped enough data yet.

**Quick fix:**
```bash
# Restart port-forwards
make observability-port-forward

# Verify Prometheus is scraping
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
```

### Demo interrupted mid-phase

The script traps `Ctrl+C` and cleans up background processes. If you need to
restart, just run `./demo/live-demo.sh` again. It resets metrics automatically
unless you set `SKIP_RESET=true`.
