#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"

VALUES_FILE="${SCRIPT_DIR}/epp-values.yaml"
if [[ "${1:-}" == "no-fc" ]]; then
  VALUES_FILE="${SCRIPT_DIR}/epp-values-no-fc.yaml"
  echo "==> Flow control DISABLED — using baseline values"
else
  echo "==> Flow control ENABLED"
fi

echo "==> Installing llm-d-router-gateway (${ROUTER_CHART_VERSION})..."
helm upgrade --install "${EPP_RELEASE}" \
  oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
  --namespace "${NAMESPACE}" \
  --version "${ROUTER_CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --wait

echo "==> Waiting for EPP deployment rollout..."
kubectl rollout status deployment/"${EPP_NAME}" \
  -n "${NAMESPACE}" \
  --timeout=180s

echo "==> llm-d router installed successfully."
