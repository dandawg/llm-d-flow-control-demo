#!/usr/bin/env bash
# =============================================================================
# swap-flow-control.sh — Toggle flow control on or off in the EPP
# =============================================================================
#
# Usage:
#   ./deployment/scripts/swap-flow-control.sh on    # enable flow control
#   ./deployment/scripts/swap-flow-control.sh off   # disable flow control
#   ./deployment/scripts/swap-flow-control.sh       # print current state
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR}/.."
source "${SCRIPT_DIR}/../../config.env"

ROUTER_DIR="${DEPLOY_ROOT}/03-llm-d-router"
ACTION="${1:-status}"

print_state() {
  local configmap
  configmap=$(kubectl get configmap -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${EPP_RELEASE}" \
    -o jsonpath='{.items[0].data.default-plugins\.yaml}' 2>/dev/null || true)

  if echo "${configmap}" | grep -q "flowControl"; then
    echo "Flow control is currently: ON"
  else
    echo "Flow control is currently: OFF"
  fi
}

case "${ACTION}" in
  on)
    echo "==> Enabling flow control..."
    helm upgrade "${EPP_RELEASE}" \
      oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
      --namespace "${NAMESPACE}" \
      --version "${ROUTER_CHART_VERSION}" \
      --values "${ROUTER_DIR}/epp-values.yaml" \
      --wait

    echo "==> Waiting for EPP rollout..."
    kubectl rollout status deployment/"${EPP_NAME}" \
      -n "${NAMESPACE}" \
      --timeout=180s

    echo ""
    print_state
    ;;

  off)
    echo "==> Disabling flow control..."
    helm upgrade "${EPP_RELEASE}" \
      oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
      --namespace "${NAMESPACE}" \
      --version "${ROUTER_CHART_VERSION}" \
      --values "${ROUTER_DIR}/epp-values-no-fc.yaml" \
      --wait

    echo "==> Waiting for EPP rollout..."
    kubectl rollout status deployment/"${EPP_NAME}" \
      -n "${NAMESPACE}" \
      --timeout=180s

    echo ""
    print_state
    ;;

  status)
    print_state
    ;;

  *)
    echo "Usage: $0 {on|off}"
    echo ""
    echo "  on   — Enable flow control (uses epp-values.yaml)"
    echo "  off  — Disable flow control (uses epp-values-no-fc.yaml)"
    echo ""
    print_state
    exit 1
    ;;
esac
