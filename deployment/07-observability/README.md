# 07 — Observability (Prometheus + Grafana)

## Why Prometheus + Grafana?

This PoC uses Prometheus for metrics collection and Grafana for visualisation.
Both are industry-standard, lightweight to deploy, and provide everything
needed to observe EPP flow-control behaviour, vLLM backend performance, and
the impact of priority-based shedding on different traffic classes.

## Key Metrics

### EPP Flow Control (`llm_d_epp_flow_control_*`)

| Metric | Description |
| ------ | ----------- |
| `llm_d_epp_flow_control_requests_total` | Requests processed per tier (premium/standard/batch), labeled by `outcome` (`Dispatched`, `Shed`, `Expired`, etc.) |
| `llm_d_epp_flow_control_queue_size` | Current queue depth per tier |
| `llm_d_epp_flow_control_pool_saturation` | Pool saturation ratio (0-1); values >= 1.0 indicate flow control is actively queuing |
| `llm_d_epp_flow_control_request_queue_duration_seconds` | Time requests spend waiting in queue before dispatch (histogram) |
| `llm_d_epp_ready_endpoints` | Number of vLLM pods the EPP considers ready |

### EPP Latency

| Metric | Description |
| ------ | ----------- |
| `llm_d_epp_request_ttft_seconds` | Time to first token (histogram) |
| `llm_d_epp_request_streaming_itl_seconds` | Inter-token latency for streaming responses (histogram) |
| `llm_d_epp_request_duration_seconds` | End-to-end request duration (histogram) |

### vLLM Backend (`vllm:*`)

| Metric | Description |
| ------ | ----------- |
| `vllm:num_requests_running` | Active requests per engine |
| `vllm:num_requests_waiting` | Queued requests per engine |
| `vllm:kv_cache_usage_perc` | KV-cache utilisation percentage |
| `vllm:prompt_tokens_total` | Total prompt tokens processed (counter; derive throughput with `rate()`) |
| `vllm:generation_tokens_total` | Total generation tokens produced (counter; derive throughput with `rate()`) |
| `vllm:time_to_first_token_seconds` | Backend-side time to first token (histogram) |

## Accessing Dashboards

```bash
# Prometheus UI
kubectl port-forward svc/prometheus -n llm-d-monitoring 9090:9090
# → http://localhost:9090

# Grafana dashboards
kubectl port-forward svc/grafana -n llm-d-monitoring 3000:3000
# → http://localhost:3000  (login: admin / admin)
```

## Annotating Benchmark Runs

Use Grafana annotations to visually mark the start/end of benchmark runs on
your dashboards. The benchmark scripts can POST annotations via the Grafana
HTTP API:

```bash
curl -s -X POST http://localhost:3000/api/annotations \
  -H "Content-Type: application/json" \
  -d "{\"text\": \"benchmark: realtime 100 QPS\", \"tags\": [\"benchmark\"]}"
```

## Tuning for Live Demos

The dashboards are configured for low-latency live demos by default:

| Setting | Value | Why |
| ------- | ----- | --- |
| Prometheus scrape interval | **5s** | Fastest safe interval for a small PoC cluster |
| Grafana auto-refresh | **2s** (default) | Keeps charts near-real-time during narration |
| `rate()` / `histogram_quantile()` windows | **30s** | Reacts to traffic changes in ~30s instead of ~60s |

The Grafana timepicker also offers **1s** refresh if you need it — just select
it from the refresh dropdown in any dashboard. Note that 1s refresh is
aggressive and may add browser load; 2s is the recommended default.

> **Tip:** If you switch back to running longer benchmarks (not live demos),
> consider widening the `rate()` windows back to `[1m]` or `[5m]` for smoother
> curves, and increasing the scrape interval to `15s` to reduce Prometheus
> resource usage.

### Tier Color Scheme

All dashboards that break down metrics by tier use a consistent color
scheme so the audience can instantly identify traffic classes:

| Tier | Color | Traffic Class | Config Priority |
| ---- | ----- | ------------- | --------------- |
| Premium | 🟢 Green | Realtime / high priority | 100 |
| Standard | 🟡 Yellow | Normal API traffic | 0 |
| Low-Priority | 🔵 Blue | Background / sheddable | -1 |

## Useful PromQL Queries

**Rejection (shed) rate by tier (per second):**
```promql
sum by(priority) (rate(llm_d_epp_flow_control_requests_total{outcome!="Dispatched"}[30s]))
```

**Dispatch rate by tier (per second):**
```promql
sum by(priority) (rate(llm_d_epp_flow_control_requests_total{outcome="Dispatched"}[30s]))
```

**P99 time-to-first-token by tier:**
```promql
histogram_quantile(0.99, sum by(le, priority) (rate(llm_d_epp_request_ttft_seconds_bucket[30s])))
```

**Pool saturation (is flow control engaged?):**
```promql
llm_d_epp_flow_control_pool_saturation
```

**Total queue depth across all bands:**
```promql
sum(llm_d_epp_flow_control_queue_size)
```

**Queue wait time p95 by tier:**
```promql
histogram_quantile(0.95, sum by(le, priority) (rate(llm_d_epp_flow_control_request_queue_duration_seconds_bucket[30s])))
```

**vLLM GPU KV-cache utilisation (average across pods):**
```promql
avg(vllm:kv_cache_usage_perc)
```

**vLLM active vs waiting requests:**
```promql
sum(vllm:num_requests_running)
sum(vllm:num_requests_waiting)
```

**Token throughput (tokens/sec):**
```promql
sum(rate(vllm:prompt_tokens_total[30s])) + sum(rate(vllm:generation_tokens_total[30s]))
```

For more detailed query examples with interpretation guidance, see the
[Operator Guide](../../docs/operator-guide.md#key-promql-queries).

## Interactive Metrics Exploration

The [Metrics Exploration notebook](../../benchmarks/notebook/05-metrics-exploration.ipynb)
lets you hit the raw EPP and vLLM `/metrics` endpoints directly, inspect every
metric and its labels, and then see how Prometheus collects and queries them.
No benchmark run required — just a running cluster with the EPP and a vLLM pod
port-forwarded.
