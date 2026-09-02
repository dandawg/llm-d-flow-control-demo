#!/usr/bin/env bash
# =============================================================================
# verify-deployment.sh — Smoke-test all llm-d flow-control components
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓  ${label}"
    ((PASS++))
  else
    echo "  ✗  ${label}"
    ((FAIL++))
  fi
}

warn() {
  local label="$1"
  echo "  ⚠  ${label}"
  ((WARN++))
}

echo "============================================================"
echo " llm-d Flow Control — Deployment Verification"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# 1. vLLM pods
# ---------------------------------------------------------------------------
echo "--- vLLM Pods ---"
READY_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=vllm-nemotron-nano-9b \
  --no-headers 2>/dev/null | grep -c "Running" || true)
if [[ "${READY_PODS}" -ge "${VLLM_REPLICAS}" ]]; then
  echo "  ✓  vLLM pods Running (${READY_PODS}/${VLLM_REPLICAS})"
  ((PASS++))
else
  echo "  ✗  vLLM pods Running (${READY_PODS}/${VLLM_REPLICAS})"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# 2. EPP pod
# ---------------------------------------------------------------------------
echo ""
echo "--- EPP (Endpoint Picker Plugin) ---"
check "EPP deployment ready" \
  kubectl rollout status deployment/"${EPP_NAME}" -n "${NAMESPACE}" --timeout=10s

# ---------------------------------------------------------------------------
# 3. Gateway programmed
# ---------------------------------------------------------------------------
echo ""
echo "--- Gateway ---"
GW_PROGRAMMED=$(kubectl get gateway "${GATEWAY_NAME}" -n "${GATEWAY_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
if [[ "${GW_PROGRAMMED}" == "True" ]]; then
  echo "  ✓  Gateway PROGRAMMED=True"
  ((PASS++))
else
  echo "  ✗  Gateway PROGRAMMED=${GW_PROGRAMMED}"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# 4. InferencePool exists and selector matches running pods
# ---------------------------------------------------------------------------
echo ""
echo "--- InferencePool ---"
POOL_SELECTOR=$(kubectl get inferencepool "${POOL_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)
if [[ -n "${POOL_SELECTOR}" ]]; then
  MATCHED_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "app=${POOL_SELECTOR}" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${MATCHED_PODS}" -gt 0 ]]; then
    echo "  ✓  InferencePool ${POOL_NAME} selects ${MATCHED_PODS} running pod(s)"
    ((PASS++))
  else
    echo "  ✗  InferencePool ${POOL_NAME} exists but selects 0 running pods"
    ((FAIL++))
  fi
else
  echo "  ✗  InferencePool ${POOL_NAME} not found"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# 5. InferenceObjectives
# ---------------------------------------------------------------------------
echo ""
echo "--- InferenceObjectives ---"
for OBJ in "${FC_REALTIME_OBJECTIVE}" "${FC_STANDARD_OBJECTIVE}" "${FC_BATCH_OBJECTIVE}"; do
  check "InferenceObjective '${OBJ}' exists" \
    kubectl get inferenceobjective "${OBJ}" -n "${NAMESPACE}"
done

# ---------------------------------------------------------------------------
# 6. Prometheus scrape targets
# ---------------------------------------------------------------------------
echo ""
echo "--- Observability ---"
PROM_POD=$(kubectl get pods -n "${MONITORING_NAMESPACE}" -l app=prometheus \
  --no-headers -o name 2>/dev/null | head -1 || true)
if [[ -n "${PROM_POD}" ]]; then
  ACTIVE_TARGETS=$(kubectl exec -n "${MONITORING_NAMESPACE}" "${PROM_POD}" -- \
    wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null \
    | grep -c '"health":"up"' || true)
  if [[ "${ACTIVE_TARGETS}" -gt 0 ]]; then
    echo "  ✓  Prometheus has ${ACTIVE_TARGETS} active scrape target(s)"
    ((PASS++))
  else
    warn "Prometheus found but 0 active targets — scrape config may need tuning"
  fi
else
  warn "Prometheus pod not found in ${MONITORING_NAMESPACE}"
fi

check "Grafana deployment ready" \
  kubectl rollout status deployment/grafana -n "${MONITORING_NAMESPACE}" --timeout=10s

# ---------------------------------------------------------------------------
# 7. Smoke-test curl through Gateway
# ---------------------------------------------------------------------------
echo ""
echo "--- Smoke Test ---"
GATEWAY_IP=$(kubectl get gateway "${GATEWAY_NAME}" -n "${GATEWAY_NAMESPACE}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)

if [[ -n "${GATEWAY_IP}" ]]; then
  echo "  Gateway IP: ${GATEWAY_IP}"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 30 \
    "http://${GATEWAY_IP}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "x-gateway-inference-objective: standard" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
    2>/dev/null || echo "000")
  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "  ✓  Smoke test returned HTTP 200"
    ((PASS++))
  else
    echo "  ✗  Smoke test returned HTTP ${HTTP_CODE} (expected 200)"
    ((FAIL++))
  fi
else
  warn "Gateway IP not yet assigned — skipping smoke test"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo "============================================================"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
