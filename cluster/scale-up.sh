#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.env"

GPU_GROUP="gpu-a10"
GPU_DESIRED=2
CPU_GROUP="system"
CPU_DESIRED=2

echo "==> Scaling CPU node group '${CPU_GROUP}' to ${CPU_DESIRED}..."
eksctl scale nodegroup \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --name "${CPU_GROUP}" \
  --nodes "${CPU_DESIRED}"

echo "==> Scaling GPU node group '${GPU_GROUP}' to ${GPU_DESIRED}..."
eksctl scale nodegroup \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --name "${GPU_GROUP}" \
  --nodes "${GPU_DESIRED}" \
  --nodes-min 0

echo "==> Scale-up initiated. CPU nodes ready in ~2-3 min, GPU nodes in ~5-8 min"
echo "    (node boot + NVIDIA driver init + container image pull)."
echo ""
echo "    Monitor progress:"
echo "      kubectl get nodes -w"
