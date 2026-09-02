# EKS Cluster Setup

This directory provisions a dedicated EKS cluster for the llm-d flow-control
proof-of-concept. We use **eksctl** because it wires up VPC networking, IAM
roles, managed node groups, and GPU AMI selection in a single declarative config
file — work that would otherwise require hundreds of lines of Terraform or
CloudFormation.

## Cost Expectations

| State | Approximate Cost |
|---|---|
| **Running** (2× system + 2× GPU nodes) | ~$2.40 /hr |
| **Scaled down** (2× system nodes, GPU group at 0) | ~$0.38 /hr |

> GPU nodes (g5.xlarge) account for ~85 % of the running cost.
> Always scale down when you're not actively using the cluster.

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| AWS CLI | 2.x | `brew install awscli` or [docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| eksctl | 0.175+ | `brew install eksctl` or [docs](https://eksctl.io/installation/) |
| kubectl | 1.29+ | `brew install kubectl` or [docs](https://kubernetes.io/docs/tasks/tools/) |

You also need an AWS account with permissions to create EKS clusters, EC2
instances, IAM roles, and VPCs. Make sure `aws sts get-caller-identity`
succeeds before continuing.

## Quickstart

```bash
# 1. Create the cluster (~15-20 min)
./cluster/create-cluster.sh

# 2. Verify GPU nodes are registered
kubectl get nodes -l nvidia.com/gpu.product=A10G

# 3. When done for the day, scale down to save money
./cluster/scale-down.sh

# 4. Resume work later
./cluster/scale-up.sh

# 5. Tear everything down when the POC is finished
./cluster/delete-cluster.sh
```

## Scale-Down / Scale-Up

Scaling the GPU node group to zero keeps the control plane and system nodes
alive (so kubectl still works, monitoring stays up, etc.) while eliminating the
bulk of the hourly spend.

```bash
# Scale GPU nodes to 0 — saves ~$2.02/hr
./cluster/scale-down.sh

# Scale GPU nodes back to 2 — takes ~5-8 min
./cluster/scale-up.sh
```

## Files

| File | Purpose |
|---|---|
| `cluster.yaml` | eksctl ClusterConfig (system + GPU node groups) |
| `create-cluster.sh` | Provisions the cluster and installs the NVIDIA device plugin |
| `delete-cluster.sh` | Tears down the cluster (with confirmation prompt) |
| `scale-down.sh` | Scales the GPU node group to 0 |
| `scale-up.sh` | Scales the GPU node group back to 2 |
