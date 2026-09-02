#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"

# =============================================================================
# Install the batch gateway and its backing stores
# =============================================================================

echo "==> Creating ${BATCH_NAMESPACE} namespace..."
kubectl create namespace "${BATCH_NAMESPACE}" --dry-run=client -o yaml \
  | kubectl label --local -f - --dry-run=client -o yaml \
      llm-d.ai/gateway-route=true \
  | kubectl apply -f -

# ---- Backing stores --------------------------------------------------------

echo "==> Deploying Redis..."
kubectl apply -f "${SCRIPT_DIR}/redis.yaml"

echo "==> Deploying PostgreSQL..."
kubectl apply -f "${SCRIPT_DIR}/postgresql.yaml"

echo "==> Deploying MinIO..."
kubectl apply -f "${SCRIPT_DIR}/minio.yaml"

echo "==> Waiting for backing stores to be ready..."
kubectl rollout status deployment/redis   -n "${BATCH_NAMESPACE}" --timeout=120s
kubectl rollout status deployment/minio   -n "${BATCH_NAMESPACE}" --timeout=120s
kubectl rollout status deployment/postgresql -n "${BATCH_NAMESPACE}" --timeout=120s

# ---- Secrets ----------------------------------------------------------------

echo "==> Creating batch-gateway-secrets..."
kubectl create secret generic batch-gateway-secrets \
  -n "${BATCH_NAMESPACE}" \
  --from-literal=redis-url=redis://redis.batch-api.svc.cluster.local:6379/0 \
  --from-literal=postgresql-url=postgresql://postgres:poc-password@postgresql.batch-api.svc.cluster.local:5432/batch \
  --from-literal=s3-secret-access-key=minioadmin \
  --dry-run=client -o yaml | kubectl apply -f -

# ---- Internal Gateway -------------------------------------------------------

echo "==> Creating internal gateway (${BATCH_INTERNAL_GATEWAY_NAME})..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${BATCH_INTERNAL_GATEWAY_NAME}
  namespace: ${BATCH_NAMESPACE}
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            llm-d.ai/gateway-route: "true"
EOF

# ---- HTTPRoute ---------------------------------------------------------------

echo "==> Creating batch-llm-route HTTPRoute..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: batch-llm-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
  - name: ${BATCH_INTERNAL_GATEWAY_NAME}
    namespace: ${BATCH_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: ${POOL_NAME}
      port: 8000
  - matches:
    - path:
        type: PathPrefix
        value: /v1/completions
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: ${POOL_NAME}
      port: 8000
EOF

# ---- InferenceObjective (idempotent) ----------------------------------------

echo "==> Ensuring batch InferenceObjective exists..."
kubectl apply -f - <<EOF
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata:
  name: ${FC_BATCH_OBJECTIVE}
  namespace: ${NAMESPACE}
spec:
  poolRef:
    name: ${POOL_NAME}
  priority: -1
EOF

# ---- Batch Gateway Helm install ---------------------------------------------

echo "==> Installing batch-gateway chart..."
helm upgrade --install batch-gateway \
  oci://ghcr.io/llm-d/charts/batch-gateway \
  --namespace "${BATCH_NAMESPACE}" \
  --version "${BATCH_GATEWAY_VERSION}" \
  --values "${SCRIPT_DIR}/batch-gateway-values.yaml" \
  --wait

echo "==> Waiting for batch-gateway deployments..."
kubectl rollout status deployment/batch-gateway-apiserver  -n "${BATCH_NAMESPACE}" --timeout=180s
kubectl rollout status deployment/batch-gateway-processor  -n "${BATCH_NAMESPACE}" --timeout=180s

echo "==> Batch gateway installed successfully."
echo ""
echo "Submit batches via the main inference gateway or port-forward the API server:"
echo "  kubectl port-forward svc/batch-gateway-apiserver -n ${BATCH_NAMESPACE} 8080:8080"
