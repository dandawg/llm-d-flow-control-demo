# Deployment Guide — llm-d Flow Control PoC

This guide walks through deploying a complete llm-d inference stack with
priority-based flow control on a Kubernetes cluster with GPU nodes.

## What Gets Deployed

| Step | Component | Purpose |
|------|-----------|---------|
| 00 | Gateway API CRDs, cert-manager, Istio | Cluster-scoped prerequisites for the Gateway API data-plane |
| 01 | Namespace (`llm-d-poc`) | Isolated workspace with the `llm-d.ai/gateway-route` label so Gateways can discover HTTPRoutes |
| 02 | vLLM | 2-replica GPU deployment serving NVIDIA Nemotron Nano 9B v2 via the OpenAI-compatible API |
| 03 | llm-d Router (EPP) | Endpoint Picker Plugin — the intelligent request router that implements flow control, scheduling, and fairness |
| 04 | Gateway + HTTPRoute | Istio Gateway exposing `/v1/chat/completions` and `/v1/completions`, routing to the InferencePool |
| 05 | InferenceObjectives | Three tiers: premium (`realtime`, 100), standard (`standard`, 0), low-priority (`low-priority`, -1) |
| 06 | Batch Gateway | OpenAI-compatible `/v1/batches` API for offline workloads, automatically tagged as lowest priority |
| 07 | Observability | Prometheus + Grafana with pre-built dashboards for flow control, latency, fairness, and vLLM health |

---

## Quickstart

If you just want to get everything running in one shot:

```bash
./deployment/scripts/deploy-all.sh
```

The script installs every component in order, waits for readiness at each step,
and finishes with a verification pass. Total time depends on GPU node scheduling
and image pull speed (typically 5–15 minutes).

---

## Manual Step-by-Step Walkthrough

Use this when you want to understand each piece or need to debug a specific
layer.

### Prerequisites

You need:
- A Kubernetes cluster with at least 2 GPU nodes (`nvidia.com/gpu`)
- `kubectl`, `helm` (v3+), and `istioctl` on your PATH

### Step 0 — Cluster Prerequisites

**Why:** The Gateway API Inference Extension CRDs define the `InferencePool` and
`InferenceObjective` resources that the EPP watches. Istio provides the
data-plane (Envoy sidecars + Gateway controller). cert-manager handles TLS
certificates for webhooks.

```bash
# Install Gateway API + Inference Extension + llm-d Router CRDs
./deployment/00-prerequisites/install-gateway-api-crds.sh

# Install cert-manager (needed by webhook certificates)
./deployment/00-prerequisites/install-cert-manager.sh

# Install Istio with Gateway API Inference Extension support
./deployment/00-prerequisites/install-istio.sh
```

### Step 1 — Namespace

**Why:** All workload resources live in a dedicated namespace. The label
`llm-d.ai/gateway-route: "true"` lets the Istio Gateway discover HTTPRoutes
across namespaces.

```bash
kubectl apply -f deployment/01-namespace/namespace.yaml
```

### Step 2 — vLLM Model Servers

**Why:** vLLM serves the actual LLM. The deployment runs 2 replicas for
redundancy and load distribution. Each replica requires one GPU.

```bash
# Deploy vLLM
kubectl apply -f deployment/02-vllm/vllm-deployment.yaml -n llm-d-poc

# Wait for pods (first pull of the model weights takes a few minutes)
kubectl rollout status deployment/vllm-nemotron-nano-9b -n llm-d-poc --timeout=600s
```

### Step 3 — llm-d Router (EPP)

**Why:** The EPP is the brain of the system. It sits between the Gateway and
vLLM, picks the best backend for each request, and — with flow control enabled —
enforces priority bands, queuing, fairness policies, and load shedding.

```bash
# With flow control enabled (default):
./deployment/03-llm-d-router/install-router.sh

# Without flow control (baseline comparison):
./deployment/03-llm-d-router/install-router.sh no-fc
```

### Step 4 — Gateway + HTTPRoute

**Why:** The Istio Gateway provides the external-facing LoadBalancer IP. The
HTTPRoute maps `/v1/chat/completions` and `/v1/completions` to the
InferencePool, so traffic flows through the EPP.

```bash
kubectl apply -f deployment/04-gateway/gateway.yaml
kubectl apply -f deployment/04-gateway/httproute.yaml
```

### Step 5 — InferenceObjectives

**Why:** InferenceObjectives declare the tiers that clients select via
the `x-gateway-inference-objective` HTTP header. The EPP reads these to decide
which tier handles each request.

- **premium** (priority 100, CRD name: `realtime`) — latency-sensitive, user-facing chat
- **standard** (priority 0, CRD name: `standard`) — normal API traffic
- **low-priority** (priority -1, CRD name: `low-priority`) — background/batch work, shed first

```bash
kubectl apply -f deployment/05-flow-control/inference-objectives.yaml
```

### Step 6 — Batch Gateway (optional)

**Why:** The batch gateway provides an OpenAI-compatible `/v1/batches` endpoint.
It automatically tags every downstream request with
`x-gateway-inference-objective: low-priority` so batch work uses idle
capacity without impacting real-time traffic.

```bash
./deployment/06-batch-gateway/install-batch-gateway.sh
```

### Step 7 — Observability

**Why:** Prometheus scrapes metrics from vLLM and the EPP. Grafana provides
pre-built dashboards for flow control queue depth, latency by tier, fairness
analysis, and vLLM backend health — critical for understanding how the system
behaves under load.

```bash
./deployment/07-observability/install-observability.sh
```

Access Grafana:

```bash
kubectl port-forward svc/grafana -n llm-d-monitoring 3000:3000
# → http://localhost:3000  (admin / admin)
```

---

## Verification

Run the verification script to check every component:

```bash
./deployment/scripts/verify-deployment.sh
```

It checks:
- vLLM pods are Running
- EPP deployment is ready
- Gateway is PROGRAMMED
- InferencePool has endpoints
- All InferenceObjectives exist
- Prometheus has active scrape targets
- A smoke-test HTTP request through the Gateway returns 200

---

## Toggling Flow Control

You can switch flow control on and off without redeploying the entire stack.
This is useful for A/B benchmarking.

```bash
# Enable flow control
./deployment/scripts/swap-flow-control.sh on

# Disable flow control (baseline mode)
./deployment/scripts/swap-flow-control.sh off

# Check current state
./deployment/scripts/swap-flow-control.sh
```

Under the hood this runs `helm upgrade` with either `epp-values.yaml` (flow
control enabled) or `epp-values-no-fc.yaml` (disabled), then waits for the EPP
pod to roll out.

---

## Sending Requests

Once deployed, get the Gateway IP and send requests with a tier header:

```bash
GATEWAY_IP=$(kubectl get gateway llm-d-inference-gateway -n istio-ingress \
  -o jsonpath='{.status.addresses[0].value}')

# Premium tier (highest priority)
curl http://${GATEWAY_IP}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-gateway-inference-objective: realtime" \
  -d '{"model":"nvidia/NVIDIA-Nemotron-Nano-9B-v2","messages":[{"role":"user","content":"Hello!"}],"max_tokens":64}'

# Standard tier
curl http://${GATEWAY_IP}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-gateway-inference-objective: standard" \
  -d '{"model":"nvidia/NVIDIA-Nemotron-Nano-9B-v2","messages":[{"role":"user","content":"Summarize this..."}],"max_tokens":256}'

# Low-priority tier (lowest priority — shed first under load)
curl http://${GATEWAY_IP}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-gateway-inference-objective: low-priority" \
  -d '{"model":"nvidia/NVIDIA-Nemotron-Nano-9B-v2","messages":[{"role":"user","content":"Classify..."}],"max_tokens":32}'
```

---

## Grafana Dashboards

Four dashboards are pre-loaded:

| Dashboard | Key Signals |
|-----------|-------------|
| **Flow Control Overview** | Pool saturation gauge, queue depth spikes by tier (premium/standard/low-priority), dispatch/rejection rates, queue wait p95 |
| **Latency by Tier** | TTFT and TPOT at p50/p95/p99 broken down by tier — shows whether premium traffic stays fast while low-priority traffic absorbs queuing |
| **Fairness Analysis** | Jain's fairness index, per-tenant dispatch rates, wait times, and queue depths — verifies the round-robin fairness policy is working |
| **vLLM Backend Health** | Running/waiting requests per pod, KV cache utilization, token throughput, TTFT from vLLM's perspective, ready endpoint count |

---

## Teardown

Remove everything (with confirmation prompt):

```bash
./deployment/scripts/teardown.sh
```

Skip the confirmation:

```bash
./deployment/scripts/teardown.sh --yes
```

Cluster-scoped resources (CRDs, Istio, cert-manager) are left in place. Remove
them manually if you want a fully clean cluster.
