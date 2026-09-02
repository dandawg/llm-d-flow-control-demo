#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"

# =============================================================================
# Install Prometheus + Grafana into the monitoring namespace
# =============================================================================

echo "==> Creating ${MONITORING_NAMESPACE} namespace..."
kubectl create namespace "${MONITORING_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f -

# ---- Deploy Prometheus ------------------------------------------------------

echo "==> Deploying Prometheus..."
kubectl apply -f "${SCRIPT_DIR}/prometheus.yaml"

# ---- Deploy Grafana ---------------------------------------------------------

echo "==> Deploying Grafana..."
kubectl apply -f "${SCRIPT_DIR}/grafana.yaml"

# ---- Load dashboard JSON files as ConfigMaps --------------------------------

DASHBOARD_DIR="${SCRIPT_DIR}/dashboards"
if [[ -d "${DASHBOARD_DIR}" ]]; then
  echo "==> Loading dashboard JSON files from ${DASHBOARD_DIR}..."
  dashboard_args=()
  for f in "${DASHBOARD_DIR}"/*.json; do
    [[ -f "${f}" ]] || continue
    dashboard_args+=(--from-file="${f}")
  done
  if [[ ${#dashboard_args[@]} -gt 0 ]]; then
    kubectl create configmap grafana-dashboards \
      -n "${MONITORING_NAMESPACE}" \
      "${dashboard_args[@]}" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    echo "    (no .json files found — skipping)"
  fi
else
  echo "    (no dashboards/ directory found — skipping dashboard ConfigMap)"
fi

# ---- Wait for deployments ---------------------------------------------------

echo "==> Waiting for Prometheus..."
kubectl rollout status deployment/prometheus -n "${MONITORING_NAMESPACE}" --timeout=120s

echo "==> Waiting for Grafana..."
kubectl rollout status deployment/grafana -n "${MONITORING_NAMESPACE}" --timeout=120s

echo "==> Observability stack installed successfully."
echo ""
echo "Access Prometheus:"
echo "  kubectl port-forward svc/prometheus -n ${MONITORING_NAMESPACE} ${PROMETHEUS_PORT}:9090"
echo "  → http://localhost:${PROMETHEUS_PORT}"
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward svc/grafana -n ${MONITORING_NAMESPACE} ${GRAFANA_PORT}:3000"
echo "  → http://localhost:${GRAFANA_PORT}  (admin / ${GRAFANA_ADMIN_PASSWORD})"
