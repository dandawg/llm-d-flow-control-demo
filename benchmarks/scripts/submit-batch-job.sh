#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/config.env"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
GATEWAY_URL=""
REQUEST_COUNT=500
MODEL="${MODEL_NAME}"
POLL_INTERVAL=10

usage() {
  echo "Usage: $0 --gateway-url <url> [--request-count N] [--model <model>]"
  echo ""
  echo "Options:"
  echo "  --gateway-url    Base URL of the inference gateway (required)"
  echo "  --request-count  Number of requests in the batch (default: 500)"
  echo "  --model          Model name (default: ${MODEL_NAME})"
  exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-url)  GATEWAY_URL="$2"; shift 2 ;;
    --request-count) REQUEST_COUNT="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    *)              usage ;;
  esac
done

[[ -z "${GATEWAY_URL}" ]] && { echo "ERROR: --gateway-url is required" >&2; usage; }

# ---------------------------------------------------------------------------
# Generate JSONL input file
# ---------------------------------------------------------------------------
TMPDIR_BATCH="$(mktemp -d)"
INPUT_FILE="${TMPDIR_BATCH}/batch-input.jsonl"

echo "==> Generating ${REQUEST_COUNT} batch requests..."
for i in $(seq 1 "${REQUEST_COUNT}"); do
  cat <<EOJSON
{"custom_id":"req-${i}","method":"POST","url":"/v1/chat/completions","body":{"model":"${MODEL}","messages":[{"role":"user","content":"Write a short summary of request number ${i}."}],"max_tokens":256}}
EOJSON
done > "${INPUT_FILE}"

echo "==> Input file: ${INPUT_FILE} ($(wc -l < "${INPUT_FILE}") lines)"

# ---------------------------------------------------------------------------
# Upload the file
# ---------------------------------------------------------------------------
echo "==> Uploading batch input file..."
UPLOAD_RESPONSE=$(curl -s -X POST "${GATEWAY_URL}/v1/files" \
  -F "purpose=batch" \
  -F "file=@${INPUT_FILE}")

FILE_ID=$(echo "${UPLOAD_RESPONSE}" | jq -r '.id')
if [[ -z "${FILE_ID}" || "${FILE_ID}" == "null" ]]; then
  echo "ERROR: File upload failed" >&2
  echo "${UPLOAD_RESPONSE}" >&2
  exit 1
fi
echo "==> Uploaded file: ${FILE_ID}"

# ---------------------------------------------------------------------------
# Create the batch
# ---------------------------------------------------------------------------
echo "==> Creating batch job..."
BATCH_RESPONSE=$(curl -s -X POST "${GATEWAY_URL}/v1/batches" \
  -H "Content-Type: application/json" \
  -d "{
    \"input_file_id\": \"${FILE_ID}\",
    \"endpoint\": \"/v1/chat/completions\",
    \"completion_window\": \"24h\"
  }")

BATCH_ID=$(echo "${BATCH_RESPONSE}" | jq -r '.id')
if [[ -z "${BATCH_ID}" || "${BATCH_ID}" == "null" ]]; then
  echo "ERROR: Batch creation failed" >&2
  echo "${BATCH_RESPONSE}" >&2
  exit 1
fi
echo "==> Batch created: ${BATCH_ID}"

# ---------------------------------------------------------------------------
# Poll until completion
# ---------------------------------------------------------------------------
echo "==> Polling batch status every ${POLL_INTERVAL}s..."
while true; do
  STATUS_RESPONSE=$(curl -s "${GATEWAY_URL}/v1/batches/${BATCH_ID}")
  STATUS=$(echo "${STATUS_RESPONSE}" | jq -r '.status')

  case "${STATUS}" in
    completed)
      echo "==> Batch ${BATCH_ID} completed successfully."
      echo "${STATUS_RESPONSE}" | jq .
      break
      ;;
    failed|cancelled|expired)
      echo "==> Batch ${BATCH_ID} terminated with status: ${STATUS}" >&2
      echo "${STATUS_RESPONSE}" | jq . >&2
      exit 1
      ;;
    *)
      COMPLETED=$(echo "${STATUS_RESPONSE}" | jq -r '.request_counts.completed // 0')
      TOTAL=$(echo "${STATUS_RESPONSE}" | jq -r '.request_counts.total // 0')
      echo "    status=${STATUS}  progress=${COMPLETED}/${TOTAL}"
      sleep "${POLL_INTERVAL}"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "${TMPDIR_BATCH}"
echo "==> Done."
