#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"

echo "==> Adding Istio Helm repository..."
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update istio

echo "==> Installing istio-base (${ISTIO_VERSION})..."
helm upgrade --install istio-base istio/base \
  --namespace istio-system \
  --create-namespace \
  --version "${ISTIO_VERSION}" \
  --wait

echo "==> Installing istiod (${ISTIO_VERSION}) with Gateway API Inference Extension support..."
helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --version "${ISTIO_VERSION}" \
  --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
  --wait

echo "==> Waiting for istiod rollout..."
kubectl rollout status deployment/istiod -n istio-system --timeout=120s

echo "==> Creating ${GATEWAY_NAMESPACE} namespace..."
kubectl create namespace "${GATEWAY_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Istio ${ISTIO_VERSION} installed successfully."
