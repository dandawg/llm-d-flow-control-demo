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
| `llm_d_epp_flow_control_requests_admitted_total` | Requests admitted per priority band |
| `llm_d_epp_flow_control_requests_shed_total` | Requests shed (rejected) per priority band |
| `llm_d_epp_flow_control_queue_depth` | Current queue depth per priority band |
| `llm_d_epp_flow_control_in_flight_requests` | In-flight requests per priority band |

### EPP Latency

| Metric | Description |
| ------ | ----------- |
| `llm_d_epp_request_ttft_seconds` | Time to first token (histogram) |
| `llm_d_epp_request_tpot_seconds` | Time per output token (histogram) |
| `llm_d_epp_request_e2e_latency_seconds` | End-to-end request latency (histogram) |

### vLLM Backend (`vllm:*`)

| Metric | Description |
| ------ | ----------- |
| `vllm:num_requests_running` | Active requests per engine |
| `vllm:num_requests_waiting` | Queued requests per engine |
| `vllm:gpu_cache_usage_perc` | KV-cache utilisation percentage |
| `vllm:avg_generation_throughput_toks_per_s` | Token generation throughput |

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

## Useful PromQL Queries

**Shed rate by priority band (per second):**
```promql
rate(llm_d_epp_flow_control_requests_shed_total[1m])
```

**Admission rate by priority band (per second):**
```promql
rate(llm_d_epp_flow_control_requests_admitted_total[1m])
```

**P99 time-to-first-token:**
```promql
histogram_quantile(0.99, rate(llm_d_epp_request_ttft_seconds_bucket[1m]))
```

**Total in-flight requests across all bands:**
```promql
sum(llm_d_epp_flow_control_in_flight_requests)
```

**vLLM GPU KV-cache utilisation (average across pods):**
```promql
avg(vllm:gpu_cache_usage_perc)
```

**vLLM active vs waiting requests:**
```promql
sum(vllm:num_requests_running)
sum(vllm:num_requests_waiting)
```
