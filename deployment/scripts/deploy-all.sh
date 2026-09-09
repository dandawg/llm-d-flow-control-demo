#!/usr/bin/env bash
# =============================================================================
# deploy-all.sh — One-shot deployment of the entire llm-d flow-control stack
# =============================================================================
#
# Prerequisites:
#   - kubectl, helm, and istioctl available on PATH
#   - A Kubernetes cluster with GPU nodes
#
# Usage:
#   ./deployment/scripts/deploy-all.sh
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/.."
source "${SCRIPT_DIR}/../../config.env"

echo "============================================================"
echo " llm-d Flow Control — Full Stack Deploy"
echo "============================================================"
echo ""
echo "  Cluster:    ${CLUSTER_NAME}"
echo "  Namespace:  ${NAMESPACE}"
echo "  Model:      ${MODEL_NAME}"
echo "  Replicas:   ${VLLM_REPLICAS}"
echo ""

# ---------------------------------------------------------------------------
# Step 0 — Prerequisites (CRDs, Istio, cert-manager)
# ---------------------------------------------------------------------------
echo "===== Step 0: Prerequisites ====="

echo "--> Installing Gateway API & Inference Extension CRDs..."
bash "${DEPLOY_ROOT}/00-prerequisites/install-gateway-api-crds.sh"

echo "--> Installing cert-manager..."
bash "${DEPLOY_ROOT}/00-prerequisites/install-cert-manager.sh"

echo "--> Installing Istio..."
bash "${DEPLOY_ROOT}/00-prerequisites/install-istio.sh"

# ---------------------------------------------------------------------------
# Step 1 — Namespace
# ---------------------------------------------------------------------------
echo ""
echo "===== Step 1: Namespace ====="
kubectl apply -f "${DEPLOY_ROOT}/01-namespace/namespace.yaml"
echo "--> Namespace ${NAMESPACE} created."

# ---------------------------------------------------------------------------
# Step 2 — vLLM
# ---------------------------------------------------------------------------
echo ""
echo "===== Step 2: vLLM Model Servers ====="

echo "--> Deploying vLLM (${VLLM_REPLICAS} replicas)..."
kubectl apply -f "${DEPLOY_ROOT}/02-vllm/vllm-deployment.yaml" -n "${NAMESPACE}"

echo "--> Waiting for vLLM pods to be ready (this may take several minutes on first pull)..."
kubectl rollout status deployment/vllm-nemotron-nano-9b \
  -n "${NAMESPACE}" \
  --timeout=600s

# ---------------------------------------------------------------------------
# Step 3 — llm-d Router (EPP) with flow control
# ---------------------------------------------------------------------------
echo ""
echo "===== Step 3: llm-d Router (EPP) ====="
bash "${DEPLOY_ROOT}/03-llm-d-router/install-router.sh"

# ---------------------------------------------------------------------------
# Step 4 — Gateway
# ---------------------------------------------------------------------------
echo ""
echo "===== Step 4: Gateway ====="
kubectl apply -f "${DEPLOY_ROOT}/04-gateway/gateway.yaml"
kubectl apply -f "${DEPLOY_ROOT}/04-gateway/httproute.yaml"
echo "--> Gateway and HTTPRoute applied."

# ---------------------------------------------------------------------------
# Step 5 — InferenceObjectives (flow-control priority bands)
# ---------------------------------------------------------------------------
echo ""
echo "===== Step 5: InferenceObjectives ====="
kubectl apply -f "${DEPLOY_ROOT}/05-flow-control/inference-objectives.yaml"
echo "--> InferenceObjectives applied (realtime / standard / low-priority)."

# ---------------------------------------------------------------------------
# Step 6 — Batch Gateway
# ---------------------------------------------------------------------------
echo ""
echo "===== Step 6: Batch Gateway ====="
bash "${DEPLOY_ROOT}/06-batch-gateway/install-batch-gateway.sh"

# ---------------------------------------------------------------------------
# Step 7 — Observability (Prometheus + Grafana + dashboards)
# ---------------------------------------------------------------------------
echo ""
echo "===== Step 7: Observability ====="
bash "${DEPLOY_ROOT}/07-observability/install-observability.sh"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ""
echo "===== Verification ====="
bash "${SCRIPT_DIR}/verify-deployment.sh"

echo ""
echo "============================================================"
echo " Deployment complete!"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Get the gateway IP:"
echo "     kubectl get gateway ${GATEWAY_NAME} -n ${GATEWAY_NAMESPACE} -o jsonpath='{.status.addresses[0].value}'"
echo ""
echo "  2. Send a test request:"
echo "     curl http://\$GATEWAY_IP/v1/chat/completions \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -H 'x-gateway-inference-objective: standard' \\"
echo "       -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":32}'"
echo ""
echo "  3. Open Grafana dashboards:"
echo "     kubectl port-forward svc/grafana -n ${MONITORING_NAMESPACE} ${GRAFANA_PORT}:3000"
echo "     → http://localhost:${GRAFANA_PORT}  (admin / ${GRAFANA_ADMIN_PASSWORD})"
