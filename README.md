# llm-d Flow Control PoC

A proof-of-concept repository for deploying and benchmarking **llm-d flow control** -- priority-based scheduling, tenant fairness, and SLA enforcement for shared GPU inference on Kubernetes.

This repo is organized into three sections that are meant to be followed in order:

| Section | Directory | Purpose |
|---|---|---|
| Cluster provisioning | `cluster/` | Create and manage an EKS cluster with A10 GPU nodes |
| Stack deployment | `deployment/` | Deploy vLLM, llm-d router (EPP), Istio gateway, batch gateway, and observability |
| Benchmark scenarios | `benchmarks/` | Run structured experiments proving flow control works |

## What This Proves

1. **Priority**: Higher-priority traffic (premium) gets lower latency than lower-priority traffic (batch) under saturation.
2. **Fairness**: Tenants within the same priority tier receive equal dispatch rates regardless of how much traffic they send.
3. **Batch isolation**: Offline batch jobs submitted via `/v1/batches` do not degrade interactive traffic.
4. **Quantified overhead**: The latency cost of enabling flow control is measured and documented.

## Prerequisites

- AWS CLI configured with appropriate permissions
- [eksctl](https://eksctl.io/) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm 3](https://helm.sh/docs/intro/install/) installed
- Python 3.11+
- [uv](https://docs.astral.sh/uv/getting-started/installation/) installed (`curl -LsSf https://astral.sh/uv/install.sh | sh`)

### AWS Authentication

You must be authenticated with the AWS CLI before running any `make` commands. The cluster and deployment scripts call `aws`, `eksctl`, and `kubectl` directly and expect valid credentials in your environment.

```bash
# SSO login (typical for org accounts)
aws sso login --profile your-profile
export AWS_PROFILE=your-profile

# Or configure static credentials
aws configure
```

Verify access with `aws sts get-caller-identity` before proceeding.

## Quickstart

```bash
# 0. Install Python dependencies (creates .venv automatically)
uv sync

# 1. Create the EKS cluster (~15-20 min)
make cluster-up

# 2. Deploy everything (~10-15 min, mostly waiting for model download)
make deploy

# 3. Verify the deployment
make verify

# 4. Open Grafana dashboards
make observability-port-forward
# Visit http://localhost:3000 (admin/admin)

# 5. Run a benchmark scenario
make benchmark-02   # Priority tiers under saturation

# 6. Scale down when done (saves ~$2.20/hr)
make scale-down
```

### Verifying the Deployment

`make verify` runs a quick health check across every component in the stack:

| Check | What It Looks For |
|---|---|
| vLLM Pods | All replicas in `Running` state |
| EPP | Endpoint Picker Plugin deployment rolled out |
| Gateway | Istio gateway reports `Programmed=True` |
| InferencePool | Pool has ready endpoints |
| InferenceObjectives | All three tier objectives exist (premium, standard, batch) |
| Observability | Prometheus scraping targets, Grafana running |
| Smoke test | HTTP 200 from a chat completion through the gateway |

A fully healthy deployment passes all checks and ends with a smoke test that sends a real request through the gateway.

**Components don't all come up at once.** After `make deploy` finishes, the vLLM pods are usually first (they were already downloading the model), but the EPP, gateway, and InferencePool can each take another 1-2 minutes to become ready. If `make verify` fails on one of these, wait a minute and run it again — most early failures are just timing. If a check keeps failing after 2-3 retries, use `kubectl describe` on the failing resource for more detail.

## Cost Management

| State | Hourly Cost | What's Running |
|---|---|---|
| Full cluster | ~$2.50/hr | 2x g5.xlarge ($1.01 ea) + 2x m5.xlarge ($0.19 ea) + EKS control plane ($0.10) |
| Scaled down | ~$0.29/hr | 1x m5.xlarge + EKS control plane |
| Cluster deleted | $0/hr | Nothing |

Scale to minimum when you are not actively running benchmarks:

```bash
make scale-down    # GPU nodes -> 0, CPU nodes -> 1
make scale-up      # Restore full capacity (takes ~5-8 min)
make cluster-status  # Check what's running and current cost
```

## Repo Structure

```
cluster/           EKS cluster create/delete/scale scripts
deployment/        Kubernetes manifests and Helm values for the full stack
benchmarks/        Scenario configs, orchestrator, and results
docs/              Flow control primer, architecture, platform engineer guide, operator guide
demo/              Live demo script and presenter guide
```

## Learning Resources

Start with the conceptual foundations, then go deeper based on your role:

| Resource | Audience | What You Learn |
|----------|----------|----------------|
| [Business Value Guide](docs/business-value.md) | Leadership, stakeholders | Why flow control matters, ROI framework, cost savings, when to use it (and when not to) |
| [Flow Control Primer](docs/flow-control-primer.md) | Everyone | What flow control is, the 3-tier dispatch hierarchy (premium, standard, batch), how requests enter the system |
| [Architecture Guide](docs/architecture.md) | Everyone | Component overview, request flow diagrams, network topology |
| [Platform Engineer Guide](docs/platform-engineer-guide.md) | Platform engineers | Configuration deep-dive, tuning reference, customization checklist, troubleshooting |
| [Operator Guide](docs/operator-guide.md) | Ops engineers | Dashboard tour, what good/bad looks like, operational runbook, alerting recommendations |
| [Deployment Guide](deployment/README.md) | Platform engineers | Step-by-step deployment walkthrough |
| [Presentation Outline](demo/presentation-outline.md) | Presenters | Slide-by-slide outline for a 20-25 minute flow control talk |
| [Live Demo Presenter Guide](demo/PRESENTER-GUIDE.md) | Solution architects | How to run and narrate a live flow control demo |

### Running a Live Demo

The `demo/` directory contains a scripted multi-phase demo that progressively demonstrates flow control behavior (saturation, priority, fairness, low-priority shedding, recovery) in ~8 minutes. Run it alongside Grafana for a live visual walkthrough:

```bash
./demo/live-demo.sh
```

See the [Presenter Guide](demo/PRESENTER-GUIDE.md) for talking points, dashboard guidance, and timing options.

## Benchmark Scenarios

| Scenario | What It Proves | Key Dashboard |
|---|---|---|
| 00 - Baseline (no FC) | Raw performance floor | vLLM Health |
| 01 - Baseline (with FC) | Flow control overhead | Latency by Tier |
| 02 - Priority tiers | Premium tier gets lower latency than standard or batch at saturation | Flow Control Overview, Latency by Tier |
| 03 - Intra-tier fairness | Equal treatment regardless of volume | Fairness Analysis |
| 04 - Batch vs interactive | `/v1/batches` does not degrade interactive users | Flow Control Overview |

See [benchmarks/README.md](benchmarks/README.md) for detailed instructions on running each scenario and interpreting results.

## Key Technologies

- [llm-d](https://llm-d.ai/) -- Intelligent routing and flow control for LLM inference
- [vLLM](https://docs.vllm.ai/) -- High-throughput LLM serving engine
- [Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/) -- Kubernetes CRDs for inference-aware routing
- [Istio](https://istio.io/) -- L7 gateway with ext-proc support
- [aiperf](https://github.com/ai-dynamo/aiperf) -- LLM inference benchmarking tool
