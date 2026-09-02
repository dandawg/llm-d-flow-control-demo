#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.env"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Creating EKS cluster '${CLUSTER_NAME}' in ${AWS_REGION}..."
eksctl create cluster \
  --config-file "${SCRIPT_DIR}/cluster.yaml"

echo "==> Waiting for cluster to be active..."
aws eks wait cluster-active \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

echo "==> Updating kubeconfig..."
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

echo "==> Installing NVIDIA device plugin..."
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml

echo "==> Waiting for NVIDIA device plugin pods to be ready..."
kubectl -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset --timeout=300s

echo "==> Cluster '${CLUSTER_NAME}' is ready."
kubectl get nodes -o wide
