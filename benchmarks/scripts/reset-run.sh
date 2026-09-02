#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/config.env"

GRAFANA_URL="${GRAFANA_URL:-http://localhost:${GRAFANA_PORT}}"
GRAFANA_AUTH="admin:${GRAFANA_ADMIN_PASSWORD}"
RESULTS_DIR="${REPO_ROOT}/${BENCHMARK_OUTPUT_DIR}"

echo "=============================="
echo " Reset Benchmark Environment"
echo "=============================="
echo ""

# ---------------------------------------------------------------------------
# 1. Archive existing results
# ---------------------------------------------------------------------------
if [[ -d "${RESULTS_DIR}" ]] && [[ "$(ls -A "${RESULTS_DIR}" 2>/dev/null)" ]]; then
  ARCHIVE_DIR="${RESULTS_DIR}/archive/$(date +%Y%m%d-%H%M%S)"
  echo "==> Archiving existing results to ${ARCHIVE_DIR}..."
  mkdir -p "${ARCHIVE_DIR}"
  for entry in "${RESULTS_DIR}"/*; do
    basename_entry="$(basename "${entry}")"
    [[ "${basename_entry}" == "archive" ]] && continue
    mv "${entry}" "${ARCHIVE_DIR}/"
  done
  echo "    Done."
else
  echo "==> No existing results to archive."
fi

# ---------------------------------------------------------------------------
# 2. Clear Grafana annotations
# ---------------------------------------------------------------------------
echo "==> Clearing Grafana benchmark annotations..."
ANNOTATIONS=$(curl -s "${GRAFANA_URL}/api/annotations?tags=benchmark&limit=1000" \
  -u "${GRAFANA_AUTH}" 2>/dev/null || echo "[]")

COUNT=$(echo "${ANNOTATIONS}" | jq 'length')
if [[ "${COUNT}" -gt 0 ]]; then
  echo "    Deleting ${COUNT} annotation(s)..."
  echo "${ANNOTATIONS}" | jq -r '.[].id' | while read -r id; do
    curl -s -X DELETE "${GRAFANA_URL}/api/annotations/${id}" \
      -u "${GRAFANA_AUTH}" > /dev/null
  done
  echo "    Done."
else
  echo "    No annotations to clear."
fi

# ---------------------------------------------------------------------------
# 3. Delete Prometheus pod (emptyDir TSDB is lost on restart)
# ---------------------------------------------------------------------------
echo "==> Deleting Prometheus pod(s) in ${MONITORING_NAMESPACE}..."
kubectl delete pod -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=prometheus --wait=false 2>/dev/null || true

echo "==> Waiting for Prometheus pod to come back..."
sleep 5
kubectl wait pod -n "${MONITORING_NAMESPACE}" \
  -l app.kubernetes.io/name=prometheus \
  --for=condition=Ready \
  --timeout=120s

echo ""
echo "==> Reset complete. Environment is clean for a new benchmark run."
