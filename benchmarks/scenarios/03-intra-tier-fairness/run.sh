#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/config.env"

SCRIPTS_DIR="${REPO_ROOT}/benchmarks/scripts"

echo "======================================="
echo " Scenario 03: Intra-Tier Fairness"
echo "======================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Ensure flow-control configuration is active
# ---------------------------------------------------------------------------
echo "==> Ensuring EPP has flow-control configuration..."
"${REPO_ROOT}/deployment/03-llm-d-router/install-router.sh"

echo "==> Waiting 30s for EPP to stabilize..."
sleep 30

# ---------------------------------------------------------------------------
# 2. Run the benchmark via orchestrator
# ---------------------------------------------------------------------------
"${SCRIPTS_DIR}/orchestrator.sh" "${SCRIPT_DIR}"
