#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/config.env"

SCRIPTS_DIR="${REPO_ROOT}/benchmarks/scripts"

echo "=============================="
echo " Scenario 00: Baseline NO FC"
echo "=============================="
echo ""

# ---------------------------------------------------------------------------
# 1. Swap EPP to no-FC configuration
# ---------------------------------------------------------------------------
echo "==> Switching EPP to no-flow-control configuration..."
"${REPO_ROOT}/deployment/03-llm-d-router/install-router.sh" no-fc

echo "==> Waiting 30s for EPP to stabilize..."
sleep 30

# ---------------------------------------------------------------------------
# 2. Run the benchmark via orchestrator
# ---------------------------------------------------------------------------
"${SCRIPTS_DIR}/orchestrator.sh" "${SCRIPT_DIR}"
