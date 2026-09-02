#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.env"

GPU_GROUP="gpu-a10"
CPU_GROUP="system"

echo "==> Scaling GPU node group '${GPU_GROUP}' to 0..."
eksctl scale nodegroup \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --name "${GPU_GROUP}" \
  --nodes 0 \
  --nodes-min 0

echo "==> Scaling CPU node group '${CPU_GROUP}' to 1..."
eksctl scale nodegroup \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --name "${CPU_GROUP}" \
  --nodes 1

echo "==> Scaled down. GPU nodes: 0, CPU nodes: 1."
echo "    Estimated idle cost: ~\$0.29/hr (1x m5.xlarge + EKS control plane)."
echo "    Run 'make scale-up' to restore full capacity."
