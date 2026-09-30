#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/config.env"

PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:${PROMETHEUS_PORT}}"

usage() {
  echo "Usage: $0 <run-name>"
  echo ""
  echo "Exports aiperf results and Prometheus metric snapshots for a given run."
  echo "Results are saved to ${BENCHMARK_OUTPUT_DIR}/<run-name>/."
  exit 1
}

[[ $# -lt 1 ]] && usage

RUN_NAME="$1"
SOURCE_DIR="${REPO_ROOT}/${BENCHMARK_OUTPUT_DIR}/${RUN_NAME}"
EXPORT_DIR="${SOURCE_DIR}/export"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "ERROR: Run directory not found: ${SOURCE_DIR}" >&2
  exit 1
fi

mkdir -p "${EXPORT_DIR}"

# ---------------------------------------------------------------------------
# 1. Copy aiperf JSON output
# ---------------------------------------------------------------------------
echo "==> Copying aiperf results..."
cp "${SOURCE_DIR}"/*.json "${EXPORT_DIR}/" 2>/dev/null || echo "    No JSON files found."

# ---------------------------------------------------------------------------
# 2. Query Prometheus for key metrics
# ---------------------------------------------------------------------------
query_prometheus() {
  local name="$1"
  local query="$2"
  local output="${EXPORT_DIR}/prometheus-${name}.json"

  echo "    Querying: ${name}"
  curl -s --fail-with-body \
    "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=${query}" \
    -o "${output}" 2>/dev/null || echo "    WARN: Query '${name}' failed"
}

echo "==> Querying Prometheus metrics..."

query_prometheus "request_rate" \
  "sum(rate(vllm:request_success_total[5m])) by (model_name)"

query_prometheus "request_latency_p50" \
  "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le, model_name))"

query_prometheus "request_latency_p99" \
  "histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le, model_name))"

query_prometheus "ttft_p50" \
  "histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le, model_name))"

query_prometheus "ttft_p99" \
  "histogram_quantile(0.99, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le, model_name))"

query_prometheus "kv_cache_utilization" \
  "avg(vllm:kv_cache_usage_perc) by (model_name)"

query_prometheus "running_requests" \
  "sum(vllm:num_requests_running) by (model_name)"

query_prometheus "waiting_requests" \
  "sum(vllm:num_requests_waiting) by (model_name)"

query_prometheus "fc_queue_depth" \
  "sum(llm_d_epp_flow_control_queue_size) by (priority)"

query_prometheus "fc_shed_total" \
  "sum(rate(llm_d_epp_flow_control_requests_total{outcome!=\"Dispatched\"}[5m])) by (priority)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==> Export complete."
echo "    aiperf results : ${EXPORT_DIR}/*.json"
echo "    Prometheus data: ${EXPORT_DIR}/prometheus-*.json"
echo ""
ls -lh "${EXPORT_DIR}/"
