#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Remove the entire llm-d flow-control stack in reverse order
# =============================================================================
#
# Usage:
#   ./deployment/scripts/teardown.sh          # interactive confirmation
#   ./deployment/scripts/teardown.sh --yes    # skip confirmation
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/.."
source "${SCRIPT_DIR}/../../config.env"

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ "${1:-}" != "--yes" ]]; then
  echo "This will DELETE the full llm-d flow-control stack from your cluster."
  echo ""
  echo "  Namespace:      ${NAMESPACE}"
  echo "  Batch NS:       ${BATCH_NAMESPACE}"
  echo "  Monitoring NS:  ${MONITORING_NAMESPACE}"
  echo ""
  read -r -p "Continue? [y/N] " confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "============================================================"
echo " llm-d Flow Control — Teardown"
echo "============================================================"
echo ""

safe_delete() {
  echo "  → $*"
  "$@" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 7 — Observability
# ---------------------------------------------------------------------------
echo "--- Removing observability stack ---"
safe_delete kubectl delete namespace "${MONITORING_NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 6 — Batch Gateway
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing batch gateway ---"
safe_delete helm uninstall batch-gateway -n "${BATCH_NAMESPACE}"
safe_delete kubectl delete namespace "${BATCH_NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 5 — InferenceObjectives
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing InferenceObjectives ---"
safe_delete kubectl delete -f "${DEPLOY_ROOT}/05-flow-control/inference-objectives.yaml"

# ---------------------------------------------------------------------------
# Step 4 — Gateway + HTTPRoute
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing Gateway and HTTPRoute ---"
safe_delete kubectl delete -f "${DEPLOY_ROOT}/04-gateway/httproute.yaml"
safe_delete kubectl delete -f "${DEPLOY_ROOT}/04-gateway/gateway.yaml"

# ---------------------------------------------------------------------------
# Step 3 — llm-d Router (Helm release)
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing llm-d router ---"
safe_delete helm uninstall "${EPP_RELEASE}" -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 2 — vLLM
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing vLLM deployment ---"
safe_delete kubectl delete -f "${DEPLOY_ROOT}/02-vllm/vllm-deployment.yaml" -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 1 — Namespace (takes everything remaining with it)
# ---------------------------------------------------------------------------
echo ""
echo "--- Removing namespace ---"
safe_delete kubectl delete -f "${DEPLOY_ROOT}/01-namespace/namespace.yaml"

echo ""
echo "============================================================"
echo " Teardown complete."
echo "============================================================"
echo ""
echo "Note: Cluster-scoped resources (CRDs, Istio, cert-manager) were"
echo "left in place. Remove them manually if needed:"
echo "  helm uninstall istiod -n istio-system"
echo "  helm uninstall istio-base -n istio-system"
echo "  helm uninstall cert-manager -n cert-manager"
