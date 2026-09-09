#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/config.env"

GRAFANA_URL="${GRAFANA_URL:-http://localhost:${GRAFANA_PORT}}"
GRAFANA_AUTH="admin:${GRAFANA_ADMIN_PASSWORD}"

usage() {
  echo "Usage: $0 start|end \"Description\""
  echo ""
  echo "Adds a Grafana annotation to mark benchmark run boundaries."
  echo ""
  echo "Environment:"
  echo "  GRAFANA_URL   Grafana base URL (default: http://localhost:${GRAFANA_PORT})"
  exit 1
}

[[ $# -lt 2 ]] && usage

ACTION="$1"
DESCRIPTION="$2"

EPOCH_MS=$(($(date +%s) * 1000))

case "${ACTION}" in
  start)
    TAG="benchmark-start"
    TEXT="▶ ${DESCRIPTION}"
    ;;
  end)
    TAG="benchmark-end"
    TEXT="■ ${DESCRIPTION}"
    ;;
  *)
    echo "ERROR: Unknown action '${ACTION}'. Use 'start' or 'end'." >&2
    usage
    ;;
esac

echo "==> Adding Grafana annotation: ${TEXT}"
if RESPONSE=$(curl -s --connect-timeout 5 -X POST "${GRAFANA_URL}/api/annotations" \
  -u "${GRAFANA_AUTH}" \
  -H "Content-Type: application/json" \
  -d "{
    \"time\": ${EPOCH_MS},
    \"tags\": [\"benchmark\", \"${TAG}\"],
    \"text\": \"${TEXT}\"
  }"); then
  ANNOTATION_ID=$(echo "${RESPONSE}" | jq -r '.id // empty')
  if [[ -n "${ANNOTATION_ID}" ]]; then
    echo "==> Annotation created: id=${ANNOTATION_ID}"
  else
    echo "WARN: Grafana annotation may have failed: ${RESPONSE}" >&2
  fi
else
  echo "WARN: Could not reach Grafana at ${GRAFANA_URL} — skipping annotation" >&2
  echo "      Is the port-forward running? Try:" >&2
  echo "        kubectl port-forward svc/grafana ${GRAFANA_PORT}:3000 -n ${MONITORING_NAMESPACE} &" >&2
fi
