#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.env"

echo "==> Cluster: ${CLUSTER_NAME} (${AWS_REGION})"
echo ""

CLUSTER_STATUS=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query "cluster.status" \
  --output text 2>/dev/null) || {
  echo "    Cluster not found. It may have been deleted."
  exit 0
}

echo "    Control plane: ${CLUSTER_STATUS}"
echo ""

echo "==> Node groups:"
NODEGROUPS=$(aws eks list-nodegroups \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query "nodegroups[]" \
  --output text)

TOTAL_HOURLY=0
for NG in ${NODEGROUPS}; do
  INFO=$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --nodegroup-name "${NG}" \
    --query "nodegroup.{status:status, desired:scalingConfig.desiredSize, min:scalingConfig.minSize, max:scalingConfig.maxSize, instance:instanceTypes[0]}" \
    --output json)

  STATUS=$(echo "${INFO}" | jq -r '.status')
  DESIRED=$(echo "${INFO}" | jq -r '.desired')
  MIN=$(echo "${INFO}" | jq -r '.min')
  MAX=$(echo "${INFO}" | jq -r '.max')
  INSTANCE=$(echo "${INFO}" | jq -r '.instance')

  case "${INSTANCE}" in
    g5.xlarge)  RATE="1.006" ;;
    m5.xlarge)  RATE="0.192" ;;
    *)          RATE="0.000" ;;
  esac
  GROUP_COST=$(echo "${DESIRED} * ${RATE}" | bc)
  TOTAL_HOURLY=$(echo "${TOTAL_HOURLY} + ${GROUP_COST}" | bc)

  printf "    %-12s  %-8s  nodes=%s (min=%s max=%s)  %s  ~\$%s/hr\n" \
    "${NG}" "${STATUS}" "${DESIRED}" "${MIN}" "${MAX}" "${INSTANCE}" "${GROUP_COST}"
done

EKS_CONTROL_PLANE_COST="0.10"
TOTAL_HOURLY=$(echo "${TOTAL_HOURLY} + ${EKS_CONTROL_PLANE_COST}" | bc)

echo ""
echo "    EKS control plane: ~\$${EKS_CONTROL_PLANE_COST}/hr"
echo "    ─────────────────────────────"
printf "    Estimated total:   ~\$%s/hr\n" "${TOTAL_HOURLY}"
echo ""

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "==> Kubernetes nodes (${NODE_COUNT} registered):"
if [[ "${NODE_COUNT}" -gt 0 ]]; then
  kubectl get nodes -o wide --no-headers 2>/dev/null | while read -r line; do
    echo "    ${line}"
  done
else
  echo "    (no nodes registered -- kubectl may not be able to reach the cluster)"
fi
