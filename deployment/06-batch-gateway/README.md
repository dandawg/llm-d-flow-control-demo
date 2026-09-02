# 06 — Batch Gateway

## Why Batch Gateway?

The **batch gateway** exposes an OpenAI-compatible `/v1/batches` API that lets
you submit offline inference jobs (bulk summarisation, evaluation runs, dataset
annotation, etc.) without impacting latency-sensitive real-time traffic.

Instead of sending thousands of individual requests through the real-time
gateway, you upload a JSONL file, create a batch, and the system processes it
in the background — automatically adjusting throughput based on available
cluster capacity.

## How It Integrates with Flow Control

The batch gateway's **processor** component dequeues jobs and fans them out as
individual inference requests through an internal (cluster-only) Gateway API
gateway. Every downstream request is tagged with the header:

```
x-gateway-inference-objective: batch-sheddable
```

This maps to the `batch-sheddable` InferenceObjective (priority **-1**), the
lowest priority band configured in the EPP's flow-control pipeline.

**At saturation** the EPP will shed batch requests first, preserving capacity
for `standard` (priority 0) and `realtime` (priority 100) traffic. When the
processor receives 429 / 503 rejections it retries with an **AIMD-style
backoff** (additive-increase, multiplicative-decrease), automatically ramping
throughput back up as headroom returns.

The net effect: batch work fills idle capacity without degrading interactive
users.

## Components

| Component      | Description                                              |
| -------------- | -------------------------------------------------------- |
| **API server** | REST front-end for `/v1/batches`, `/v1/files`, etc.      |
| **Processor**  | Dequeues batch jobs, sends inference requests, retries    |
| **Redis**      | Job queue between API server and processor                |
| **PostgreSQL** | Metadata store (batches, files, status)                   |
| **MinIO**      | S3-compatible object storage for input/output JSONL files |

## Quick Start

```bash
./install-batch-gateway.sh
```

The script creates the `batch-api` namespace, deploys the backing stores
(Redis, PostgreSQL, MinIO), provisions secrets, sets up the internal gateway
and HTTPRoute, and Helm-installs the batch-gateway chart.
