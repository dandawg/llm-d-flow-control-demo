#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/config.env"

# Ensure aiperf is on PATH (auto-detect project venv if not activated)
if ! command -v aiperf &>/dev/null; then
  if [[ -x "${REPO_ROOT}/.venv/bin/aiperf" ]]; then
    export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
  else
    echo "ERROR: aiperf not found. Run 'uv sync' first." >&2
    exit 1
  fi
fi

usage() {
  echo "Usage: $0 <scenario-dir>"
  echo ""
  echo "Run a benchmark scenario defined by scenario.conf in <scenario-dir>."
  exit 1
}

[[ $# -lt 1 ]] && usage

SCENARIO_DIR="$(cd "$1" && pwd)"
SCENARIO_CONF="${SCENARIO_DIR}/scenario.conf"

if [[ ! -f "${SCENARIO_CONF}" ]]; then
  echo "ERROR: ${SCENARIO_CONF} not found" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${SCENARIO_CONF}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="${REPO_ROOT}/${BENCHMARK_OUTPUT_DIR}/${SCENARIO_NAME}/${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Resolve Gateway IP
# ---------------------------------------------------------------------------
resolve_gateway_ip() {
  local ip
  ip=$(kubectl get gateway "${GATEWAY_NAME}" \
    -n "${GATEWAY_NAMESPACE}" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)

  if [[ -z "${ip}" ]]; then
    echo "ERROR: Could not resolve Gateway IP for ${GATEWAY_NAME}" >&2
    exit 1
  fi
  echo "${ip}"
}

GATEWAY_IP="$(resolve_gateway_ip)"
GATEWAY_URL="http://${GATEWAY_IP}"
echo "==> Gateway IP: ${GATEWAY_IP}"
echo "==> Results dir: ${RESULTS_DIR}"
echo "==> Scenario: ${SCENARIO_NAME} (${STREAM_COUNT} stream(s), ${SCENARIO_DURATION:-${BENCHMARK_DURATION}}s)"

DURATION="${SCENARIO_DURATION:-${BENCHMARK_DURATION}}"

# ---------------------------------------------------------------------------
# Annotate run start
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/annotate-run.sh" start "${SCENARIO_NAME} — ${TIMESTAMP}"

# ---------------------------------------------------------------------------
# Launch aiperf streams
# ---------------------------------------------------------------------------
PIDS=()

for i in $(seq 1 "${STREAM_COUNT}"); do
  NAME_VAR="STREAM_${i}_NAME"
  HEADERS_VAR="STREAM_${i}_HEADERS[@]"
  CONCURRENCY_VAR="STREAM_${i}_CONCURRENCY"
  DATA_VAR="STREAM_${i}_DATA"
  REQUEST_COUNT_VAR="STREAM_${i}_REQUEST_COUNT"
  STREAMING_VAR="STREAM_${i}_STREAMING"

  STREAM_NAME="${!NAME_VAR}"
  CONCURRENCY="${!CONCURRENCY_VAR}"
  DATA="${!DATA_VAR:-prompt_tokens=512,output_tokens=256}"
  REQUEST_COUNT="${!REQUEST_COUNT_VAR:-0}"
  STREAMING="${!STREAMING_VAR:-true}"

  # Parse DATA="prompt_tokens=X,output_tokens=Y" into ISL / OSL
  ISL=""
  OSL=""
  IFS=',' read -ra DATA_PAIRS <<< "${DATA}"
  for pair in "${DATA_PAIRS[@]}"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    case "${key}" in
      prompt_tokens)  ISL="${val}" ;;
      output_tokens)  OSL="${val}" ;;
    esac
  done

  # Build header args — the array may be empty
  HEADER_ARGS=()
  _hdr_name="STREAM_${i}_HEADERS"
  if declare -p "${_hdr_name}" &>/dev/null 2>&1; then
    eval "_hdr_count=\${#${_hdr_name}[@]}"
    if (( _hdr_count > 0 )); then
      HEADER_ARGS=("${!HEADERS_VAR}")
    fi
  fi

  OUTPUT_DIR="${RESULTS_DIR}/stream-${i}-${STREAM_NAME}"

  echo "==> Launching stream ${i}/${STREAM_COUNT}: ${STREAM_NAME} (concurrency=${CONCURRENCY})"

  CMD=(
    aiperf profile
    --url "${GATEWAY_URL}"
    --model "${MODEL_NAME}"
    --concurrency "${CONCURRENCY}"
    --benchmark-duration "${DURATION}"
    --output-artifact-dir "${OUTPUT_DIR}"
  )

  [[ -n "${ISL}" ]] && CMD+=(--isl "${ISL}")
  [[ -n "${OSL}" ]] && CMD+=(--osl "${OSL}")

  if [[ "${STREAMING}" == "true" ]]; then
    CMD+=(--streaming)
  fi

  if [[ "${REQUEST_COUNT}" -gt 0 ]]; then
    CMD+=(--request-count "${REQUEST_COUNT}")
  fi

  if (( ${#HEADER_ARGS[@]} > 0 )); then
    CMD+=("${HEADER_ARGS[@]}")
  fi

  "${CMD[@]}" &
  PIDS+=($!)
done

# ---------------------------------------------------------------------------
# Wait for all streams
# ---------------------------------------------------------------------------
echo "==> Waiting for ${#PIDS[@]} stream(s) to complete..."
FAILURES=0
for pid in "${PIDS[@]}"; do
  if ! wait "${pid}"; then
    ((FAILURES++))
  fi
done

# ---------------------------------------------------------------------------
# Annotate run end
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/annotate-run.sh" end "${SCENARIO_NAME} — ${TIMESTAMP}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo " Benchmark Complete"
echo "=============================="
echo " Scenario : ${SCENARIO_NAME}"
echo " Streams  : ${STREAM_COUNT}"
echo " Duration : ${DURATION}s"
echo " Results  : ${RESULTS_DIR}"
if [[ "${FAILURES}" -gt 0 ]]; then
  echo " Failures : ${FAILURES}"
fi
echo "=============================="
echo ""
ls -lh "${RESULTS_DIR}/"
