#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/config.env"

SCRIPTS_DIR="${REPO_ROOT}/benchmarks/scripts"

echo "============================================"
echo " Scenario 04: Batch vs. Interactive"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Ensure flow-control configuration is active
# ---------------------------------------------------------------------------
echo "==> Ensuring EPP has flow-control configuration..."
"${REPO_ROOT}/deployment/03-llm-d-router/install-router.sh"

echo "==> Waiting 30s for EPP to stabilize..."
sleep 30

# ---------------------------------------------------------------------------
# 2. Resolve gateway URL
# ---------------------------------------------------------------------------
GATEWAY_IP=$(kubectl get gateway "${GATEWAY_NAME}" \
  -n "${GATEWAY_NAMESPACE}" \
  -o jsonpath='{.status.addresses[0].value}')
GATEWAY_URL="http://${GATEWAY_IP}"
echo "==> Gateway URL: ${GATEWAY_URL}"

# ---------------------------------------------------------------------------
# 3. Launch interactive traffic AND batch job in parallel
# ---------------------------------------------------------------------------
echo "==> Starting interactive traffic and batch job in parallel..."

"${SCRIPTS_DIR}/orchestrator.sh" "${SCRIPT_DIR}" &
ORCHESTRATOR_PID=$!

"${SCRIPTS_DIR}/submit-batch-job.sh" \
  --gateway-url "${GATEWAY_URL}" \
  --request-count 500 \
  --model "${MODEL_NAME}" &
BATCH_PID=$!

# ---------------------------------------------------------------------------
# 4. Wait for both to complete
# ---------------------------------------------------------------------------
FAILURES=0
wait "${ORCHESTRATOR_PID}" || ((FAILURES++))
wait "${BATCH_PID}" || ((FAILURES++))

echo ""
echo "============================================"
echo " Scenario 04 Complete"
echo "============================================"
if [[ "${FAILURES}" -gt 0 ]]; then
  echo " WARNING: ${FAILURES} process(es) exited with errors."
fi
