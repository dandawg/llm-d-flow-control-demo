#!/usr/bin/env bash
# =============================================================================
# live-demo.sh — Multi-phase live demo of llm-d flow control
# =============================================================================
#
# Runs a scripted sequence of traffic phases that progressively demonstrate
# flow control behavior: warm-up, saturation, priority differentiation,
# fairness, low-priority shedding, and recovery.
#
# Designed to be run alongside Grafana so you can narrate what is happening
# in real time. Each phase prints a banner explaining what to look for, adds
# Grafana annotations, and pauses for the presenter to talk.
#
# Usage:
#   ./demo/live-demo.sh
#
# Environment variables (all optional):
#   PHASE_1_DURATION   Warm-Up duration in seconds          (default: 30)
#   PHASE_2_DURATION   Ramp to Saturation duration           (default: 60)
#   PHASE_3_DURATION   Priority Differentiation duration     (default: 90)
#   PHASE_4_DURATION   Fairness duration                     (default: 90)
#   PHASE_5_DURATION   Batch Burst duration                  (default: 90)
#   PHASE_6_DURATION   Recovery duration                     (default: 60)
#   PAUSE_BETWEEN      Pause between phases in seconds       (default: 10)
#   SKIP_RESET          Set to "true" to skip the initial reset (default: false)
#
# Prerequisites:
#   - Full stack deployed (make deploy && make verify)
#   - Port-forwards running (make observability-port-forward)
#   - Grafana open in a browser at http://localhost:3000
#   - aiperf available on PATH (uv sync)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
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

# ---------------------------------------------------------------------------
# Phase durations (configurable via environment)
# ---------------------------------------------------------------------------
P1_DUR="${PHASE_1_DURATION:-30}"
P2_DUR="${PHASE_2_DURATION:-60}"
P3_DUR="${PHASE_3_DURATION:-90}"
P4_DUR="${PHASE_4_DURATION:-90}"
P5_DUR="${PHASE_5_DURATION:-90}"
P6_DUR="${PHASE_6_DURATION:-60}"
PAUSE="${PAUSE_BETWEEN:-10}"
SKIP_RESET="${SKIP_RESET:-false}"

TOTAL_TIME=$(( P1_DUR + P2_DUR + P3_DUR + P4_DUR + P5_DUR + P6_DUR + PAUSE * 5 ))

ANNOTATE="${REPO_ROOT}/benchmarks/scripts/annotate-run.sh"

# Active background PIDs for aiperf streams
STREAM_PIDS=()

# ---------------------------------------------------------------------------
# Helpers
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

banner() {
  local phase="$1"
  local title="$2"
  local duration="$3"
  local description="$4"

  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║  Phase ${phase}: ${title}"
  echo "║  Duration: ${duration}s"
  echo "╠════════════════════════════════════════════════════════════════╣"
  echo "║"
  # Word-wrap the description to fit the banner
  echo "${description}" | fold -s -w 60 | while IFS= read -r line; do
    echo "║  ${line}"
  done
  echo "║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
}

pause_for_presenter() {
  local seconds="$1"
  echo "  ⏸  Pausing ${seconds}s — prepare for next phase (or press Enter to skip)..."
  # Allow presenter to skip the pause by pressing Enter
  read -t "${seconds}" -r 2>/dev/null || true
  echo ""
}

kill_all_streams() {
  # Each stream was launched in its own process group (PGID == PID).
  # "kill -- -PID" sends the signal to every process in that group
  # atomically — no grandchild can escape.
  for pid in "${STREAM_PIDS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill -- -"${pid}" 2>/dev/null || true
    fi
  done
  sleep 2
  # SIGKILL anything that ignored SIGTERM
  for pid in "${STREAM_PIDS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill -9 -- -"${pid}" 2>/dev/null || true
    fi
  done
  # Belt-and-suspenders: catch anything that somehow escaped process groups
  # (e.g. if a child called setsid itself).
  local retries=0
  while pgrep -f 'aiperf' >/dev/null 2>&1 && [[ $retries -lt 5 ]]; do
    echo "  ⚠  Found orphaned aiperf processes — killing them..."
    pkill -9 -f 'aiperf' 2>/dev/null || true
    sleep 1
    retries=$((retries + 1))
  done
  for pid in "${STREAM_PIDS[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done
  STREAM_PIDS=()
}

launch_stream() {
  local name="$1"
  local concurrency="$2"
  local isl="$3"
  local osl="$4"
  shift 4
  # Remaining args are extra headers/flags

  local cmd=(
    aiperf profile
    --url "${GATEWAY_URL}"
    --model "${MODEL_NAME}"
    --concurrency "${concurrency}"
    --benchmark-duration 9999
    --streaming
    --isl "${isl}"
    --osl "${osl}"
    --output-artifact-dir "/tmp/live-demo-${name}-$$"
  )

  # Append any extra arguments (headers, etc.)
  cmd+=("$@")

  echo "  → Stream: ${name}  (concurrency=${concurrency}, ISL=${isl}, OSL=${osl})"
  # Launch in a dedicated process group. perl's setpgrp(0,0) makes this
  # process a group leader before exec-ing aiperf. All children aiperf
  # spawns (timing_manager, worker_*, dataset_manager, etc.) inherit the
  # PGID, so "kill -- -$PID" in kill_all_streams reaches the entire tree.
  (exec perl -e 'setpgrp(0,0); exec @ARGV' -- "${cmd[@]}") >/dev/null 2>&1 &
  STREAM_PIDS+=($!)
}

annotate() {
  local action="$1"
  local text="$2"
  "${ANNOTATE}" "${action}" "Demo: ${text}" 2>/dev/null || true
}

cleanup() {
  echo ""
  echo "==> Cleaning up background streams..."
  kill_all_streams
  # Restart the EPP so its in-memory queues don't retain stale requests
  # from streams we just killed (the EPP may still be processing responses
  # for requests that were in-flight when the client disconnected).
  echo "==> Restarting EPP to flush in-memory state..."
  kubectl rollout restart deployment/vllm-nemotron-nano-9b-epp \
    -n "${NAMESPACE}" 2>/dev/null || true
  kubectl rollout status deployment/vllm-nemotron-nano-9b-epp \
    -n "${NAMESPACE}" --timeout=120s 2>/dev/null || true
  annotate end "Live demo ended"
  echo "==> Demo cleanup complete."
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
echo "============================================================"
echo "  llm-d Flow Control — Live Demo"
echo "============================================================"
echo ""
echo "  Total estimated runtime: ~$((TOTAL_TIME / 60))m $((TOTAL_TIME % 60))s"
echo "  Phases: 6"
echo ""

GATEWAY_IP="$(resolve_gateway_ip)"
GATEWAY_URL="http://${GATEWAY_IP}"
echo "  Gateway:  ${GATEWAY_URL}"
echo "  Grafana:  http://localhost:${GRAFANA_PORT}"
echo ""

# Quick sanity check
echo "==> Pre-flight check: sending test request..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 30 \
  "${GATEWAY_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
  2>/dev/null || echo "000")

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "ERROR: Smoke test returned HTTP ${HTTP_CODE}. Is the deployment healthy?" >&2
  echo "       Run 'make verify' to diagnose." >&2
  exit 1
fi
echo "  ✓ Gateway responded HTTP 200"
echo ""

# Optional: reset metrics for a clean slate
if [[ "${SKIP_RESET}" != "true" ]]; then
  echo "==> Resetting metrics for a clean demo..."
  "${REPO_ROOT}/benchmarks/scripts/reset-run.sh"
  echo ""
fi

annotate start "Live demo started"

# =========================================================================
# PHASE 1: Warm-Up
# =========================================================================
banner 1 "Warm-Up" "${P1_DUR}" \
  "Low traffic, single stream at standard priority. The pool is NOT saturated. Watch the Flow Control Overview dashboard: saturation gauge should be green, queue depth should be zero. This is what a healthy, idle system looks like."

echo "==> Launching Phase 1 streams..."
annotate start "Phase 1: Warm-Up"

launch_stream "standard-light" 5 512 256 \
  -H "x-llm-d-inference-objective:standard"

echo "==> Phase 1 running for ${P1_DUR}s..."
sleep "${P1_DUR}"

annotate end "Phase 1: Warm-Up"
kill_all_streams
pause_for_presenter "${PAUSE}"

# =========================================================================
# PHASE 2: Ramp to Saturation
# =========================================================================
banner 2 "Ramp to Saturation" "${P2_DUR}" \
  "Single stream at standard priority with high concurrency. The pool will saturate. Watch the saturation gauge transition from green to red. Queue depth will start climbing. TTFT will increase. This is the moment flow control engages."

echo "==> Launching Phase 2 streams..."
annotate start "Phase 2: Ramp to Saturation"

launch_stream "standard-heavy" 25 512 256 \
  -H "x-llm-d-inference-objective:standard"

echo "==> Phase 2 running for ${P2_DUR}s..."
sleep "${P2_DUR}"

annotate end "Phase 2: Ramp to Saturation"
kill_all_streams
pause_for_presenter "${PAUSE}"

# =========================================================================
# PHASE 3: Priority Differentiation
# =========================================================================
banner 3 "Priority Differentiation" "${P3_DUR}" \
  "Two streams: premium and standard tiers. Both compete for the same saturated pool. Watch the Latency by Tier dashboard: premium TTFT should be LOWER than standard despite both streams running. This proves priority works."

echo "==> Launching Phase 3 streams..."
annotate start "Phase 3: Priority Differentiation"

launch_stream "realtime" 10 128 64 \
  -H "x-llm-d-inference-objective:realtime"

launch_stream "standard-heavy" 25 512 256 \
  -H "x-llm-d-inference-objective:standard"

echo "==> Phase 3 running for ${P3_DUR}s..."
sleep "${P3_DUR}"

annotate end "Phase 3: Priority Differentiation"
kill_all_streams
pause_for_presenter "${PAUSE}"

# =========================================================================
# PHASE 4: Fairness
# =========================================================================
banner 4 "Intra-Tier Fairness" "${P4_DUR}" \
  "Three standard-tier streams with different tenants and volumes. Tenant-A sends 5x more than Tenant-B. Watch the Fairness Analysis dashboard: despite unequal send rates, dispatch counts should be EQUAL. Jain's Fairness Index should be near 1.0."

echo "==> Launching Phase 4 streams..."
annotate start "Phase 4: Intra-Tier Fairness"

launch_stream "realtime" 10 128 64 \
  -H "x-llm-d-inference-objective:realtime"

launch_stream "tenant-a" 25 512 256 \
  -H "x-llm-d-inference-objective:standard" \
  -H "x-llm-d-inference-fairness-id:tenant-a"

launch_stream "tenant-b" 5 512 256 \
  -H "x-llm-d-inference-objective:standard" \
  -H "x-llm-d-inference-fairness-id:tenant-b"

echo "==> Phase 4 running for ${P4_DUR}s..."
sleep "${P4_DUR}"

annotate end "Phase 4: Intra-Tier Fairness"
kill_all_streams
pause_for_presenter "${PAUSE}"

# =========================================================================
# PHASE 5: Batch Burst
# =========================================================================
banner 5 "Batch Burst" "${P5_DUR}" \
  "Premium + standard + a burst of low-priority traffic. The low-priority tier has only 50 slots. Watch the Flow Control Overview: low-priority queue depth will hit its cap, rejection rate will spike for the low-priority tier. Premium remains UNTOUCHED. This is the pressure relief valve."

echo "==> Launching Phase 5 streams..."
annotate start "Phase 5: Batch Burst"

launch_stream "realtime" 10 128 64 \
  -H "x-llm-d-inference-objective:realtime"

launch_stream "standard" 15 512 256 \
  -H "x-llm-d-inference-objective:standard"

launch_stream "low-priority-burst" 30 1024 512 \
  -H "x-llm-d-inference-objective:low-priority"

echo "==> Phase 5 running for ${P5_DUR}s..."
sleep "${P5_DUR}"

annotate end "Phase 5: Batch Burst"
kill_all_streams
pause_for_presenter "${PAUSE}"

# =========================================================================
# PHASE 6: Recovery
# =========================================================================
banner 6 "Recovery" "${P6_DUR}" \
  "All heavy traffic removed. Only a light standard stream remains. Watch everything return to baseline: saturation drops to zero, queues drain, latency normalizes. The system recovers automatically — no manual intervention needed."

echo "==> Launching Phase 6 streams..."
annotate start "Phase 6: Recovery"

launch_stream "standard-light" 5 512 256 \
  -H "x-llm-d-inference-objective:standard"

echo "==> Phase 6 running for ${P6_DUR}s..."
sleep "${P6_DUR}"

annotate end "Phase 6: Recovery"
kill_all_streams

# =========================================================================
# Done
# =========================================================================
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Demo Complete!"
echo "║"
echo "║  Check Grafana for the full timeline. Grafana annotations"
echo "║  mark each phase boundary so you can correlate dashboard"
echo "║  behavior with the traffic pattern."
echo "║"
echo "║  Tip: Set Grafana's time range to the last 15-30 minutes"
echo "║  to see all phases in a single view."
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
