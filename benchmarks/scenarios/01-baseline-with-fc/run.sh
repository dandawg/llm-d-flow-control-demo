#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/config.env"

SCRIPTS_DIR="${REPO_ROOT}/benchmarks/scripts"

echo "=============================="
echo " Scenario 01: Baseline WITH FC"
echo "=============================="
echo ""

# ---------------------------------------------------------------------------
# 1. Swap EPP to flow-control-enabled configuration
# ---------------------------------------------------------------------------
echo "==> Switching EPP to flow-control configuration..."
"${REPO_ROOT}/deployment/03-llm-d-router/install-router.sh"

echo "==> Waiting 30s for EPP to stabilize..."
sleep 30

# ---------------------------------------------------------------------------
# 2. Run the benchmark via orchestrator
# ---------------------------------------------------------------------------
"${SCRIPTS_DIR}/orchestrator.sh" "${SCRIPT_DIR}"
