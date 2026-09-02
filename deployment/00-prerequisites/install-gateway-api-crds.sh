#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"

echo "==> Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api/config/crd?ref=${GATEWAY_API_VERSION}"

echo "==> Installing Gateway API Inference Extension CRDs (${GAIE_VERSION})..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"

echo "==> Installing llm-d Router CRDs (${ROUTER_CHART_VERSION})..."
kubectl apply -f "https://github.com/llm-d/llm-d-router/releases/download/${ROUTER_CHART_VERSION}/manifests.yaml"

echo "==> CRDs installed. Verify:"
kubectl get crd | grep -E 'inferencepool|inferenceobjective'
