#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.env"

echo "WARNING: This will permanently delete the EKS cluster '${CLUSTER_NAME}'"
echo "         in region ${AWS_REGION}, including all node groups and resources."
echo ""
read -r -p "Type the cluster name to confirm deletion: " confirmation

if [[ "${confirmation}" != "${CLUSTER_NAME}" ]]; then
  echo "Confirmation did not match. Aborting."
  exit 1
fi

echo "==> Deleting EKS cluster '${CLUSTER_NAME}'..."
eksctl delete cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --wait

echo "==> Cluster '${CLUSTER_NAME}' has been deleted."
