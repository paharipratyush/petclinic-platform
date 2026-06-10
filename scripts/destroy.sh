#!/usr/bin/env bash
# Cleanly destroy the petclinic platform for one environment.
#
# Order of operations:
#   1. Delete the Kubernetes Ingress so the LB Controller removes the ALB
#   2. Wait for the ALB to be deleted (prevents VPC subnet dependency violations)
#   3. Run terraform destroy
#
# ECR repositories are destroyed (force_delete = true). Images must be rebuilt
# after up.sh by pushing a commit to the app repo to trigger CI.
# Secrets Manager secrets are force-deleted (recovery_window_in_days = 0) and
# can be recreated immediately by terraform apply.
#
# Usage (from project root):
#   bash scripts/destroy.sh --env dev
#   bash scripts/destroy.sh --env prod
#
# Required environment variables (set before running):
#   CLOUDFLARE_API_TOKEN        — Cloudflare API token (Zone:Read + DNS:Edit)
#   TF_VAR_domain_name          — e.g. praty.dev (or set in terraform.tfvars)
#   TF_VAR_openai_api_key       — any value (not used during destroy, but required by Terraform)
#   TF_VAR_grafana_admin_password — any value (not used during destroy)
#   TF_VAR_budget_alert_email   — any value (not used during destroy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=scripts/lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"

ENV=""

usage() {
  echo "Usage: $0 --env <dev|prod>"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$ENV" ]] && usage
[[ "$ENV" != "dev" && "$ENV" != "prod" ]] && { echo "ERROR: --env must be 'dev' or 'prod'"; exit 1; }

TF_DIR="$REPO_ROOT/terraform/environments/$ENV"
NAMESPACE="petclinic-$ENV"
REGION="eu-central-1"

echo "============================================================"
echo "  DESTROYING petclinic-$ENV"
echo "  This will delete: EKS, RDS, VPC, IGW, ALB, DNS records."
echo "  Preserved: ECR images, Secrets Manager secrets, SSM params."
echo "============================================================"
echo ""
echo "Press Ctrl-C within 10 seconds to abort..."
sleep 10

# ── Step 1: Delete the Kubernetes Ingress to trigger ALB deletion ──────────

echo ""
echo "==> Step 1 — Delete Kubernetes Ingress to trigger ALB removal..."

CLUSTER_REACHABLE=false
if kubectl cluster-info &>/dev/null 2>&1; then
  CLUSTER_REACHABLE=true
fi

if $CLUSTER_REACHABLE; then
  INGRESS_EXISTS=$(kubectl get ingress petclinic-ingress -n "$NAMESPACE" --ignore-not-found -o name 2>/dev/null || true)
  if [[ -n "$INGRESS_EXISTS" ]]; then
    kubectl delete ingress petclinic-ingress -n "$NAMESPACE"
    echo "  Ingress deleted. Waiting up to 3 minutes for ALB to be removed by the controller..."

    ALB_GONE=false
    for i in $(seq 1 18); do
      # Check if any ALBs tagged with the cluster name remain
      ALB_COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-${NAMESPACE//petclinic-/petclini}-')]|length(@)" \
        --output text 2>/dev/null || echo "0")
      if [[ "$ALB_COUNT" == "0" ]]; then
        echo "  ALB removed by controller."
        ALB_GONE=true
        break
      fi
      echo "    Waiting for ALB deletion... ($((i * 10))s elapsed)"
      sleep 10
    done

    if ! $ALB_GONE; then
      echo "  WARNING: ALB may still exist. Attempting manual deletion..."
      # Fall back to manual ALB deletion if controller doesn't clean up in time
      ALB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
        --output text 2>/dev/null || true)
      for arn in $ALB_ARNS; do
        echo "  Deleting ALB: $arn"
        aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" || true
      done
      echo "  Waiting 30s for ALB deletion to propagate..."
      sleep 30
    fi
  else
    echo "  No Ingress found in $NAMESPACE — checking for orphaned ALBs..."
    # If cluster is reachable but no Ingress, still clean up any orphaned ALBs
    ALB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
      --output text 2>/dev/null || true)
    for arn in $ALB_ARNS; do
      TGS=$(aws elbv2 describe-target-groups --load-balancer-arn "$arn" --region "$REGION" \
        --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || true)
      echo "  Deleting orphaned ALB: $arn"
      aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" || true
      for tg in $TGS; do
        sleep 5
        aws elbv2 delete-target-group --target-group-arn "$tg" --region "$REGION" 2>/dev/null || true
      done
    done
    [[ -n "$ALB_ARNS" ]] && sleep 30
  fi
else
  echo "  Cluster not reachable — checking for orphaned ALBs via AWS CLI..."
  ALB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
    --output text 2>/dev/null || true)
  for arn in $ALB_ARNS; do
    TGS=$(aws elbv2 describe-target-groups --load-balancer-arn "$arn" --region "$REGION" \
      --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || true)
    echo "  Deleting ALB: $arn"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" || true
    for tg in $TGS; do
      sleep 5
      aws elbv2 delete-target-group --target-group-arn "$tg" --region "$REGION" 2>/dev/null || true
    done
  done
  [[ -n "$ALB_ARNS" ]] && sleep 30
fi

# ── Step 1.5: Drain Karpenter-provisioned nodes ────────────────────────────
#
# Karpenter launches EC2 instances outside the managed node group. If those
# instances are still running when terraform destroy removes the VPC, the
# subnet/ENI dependency causes destroy to fail with "DependencyViolation".
# Deleting the NodePool tells Karpenter to cordon+drain and terminate its nodes
# before we remove the cluster.

echo ""
echo "==> Step 1.5 — Draining Karpenter-provisioned nodes..."

if $CLUSTER_REACHABLE; then
  KARPENTER_CRD=$(kubectl get crd nodepools.karpenter.sh --ignore-not-found -o name 2>/dev/null || true)
  if [[ -n "$KARPENTER_CRD" ]]; then
    NODE_POOLS=$(kubectl get nodepool --ignore-not-found -o name 2>/dev/null || true)
    if [[ -n "$NODE_POOLS" ]]; then
      echo "  Deleting all Karpenter NodePools to drain provisioned nodes..."
      kubectl delete nodepool --all --timeout=5m || true

      echo "  Waiting up to 5 minutes for Karpenter nodes to terminate..."
      for i in $(seq 1 30); do
        KARPENTER_NODES=$(kubectl get node -l karpenter.sh/nodepool --ignore-not-found \
          --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$KARPENTER_NODES" == "0" ]]; then
          echo "  All Karpenter nodes terminated."
          break
        fi
        echo "    $KARPENTER_NODES Karpenter node(s) still running... (${i}0s elapsed)"
        sleep 10
      done
    else
      echo "  No Karpenter NodePools found — skipping."
    fi
  else
    echo "  Karpenter CRD not installed — skipping."
  fi
else
  echo "  Cluster not reachable — checking for Karpenter-tagged EC2 instances via AWS CLI..."
  KARPENTER_INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
              "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || true)
  if [[ -n "$KARPENTER_INSTANCES" ]]; then
    echo "  Terminating Karpenter-launched instances: $KARPENTER_INSTANCES"
    aws ec2 terminate-instances --region "$REGION" --instance-ids $KARPENTER_INSTANCES || true
    echo "  Waiting 60s for instance termination..."
    sleep 60
  else
    echo "  No running Karpenter instances found."
  fi
fi

# ── Step 2: Terraform destroy ──────────────────────────────────────────────

echo ""
echo "==> Step 2 — Running terraform destroy..."
tf -chdir="$TF_DIR" destroy -auto-approve

echo ""
echo "============================================================"
echo "  petclinic-$ENV destroyed successfully."
echo ""
echo "  Preserved (not managed by this script):"
echo "    - Terraform state in S3 (petclinic-terraform-state-*/)"
echo "    - DynamoDB lock table (petclinic-terraform-locks)"
echo "    - Cloudflare DNS zone (ACM validation + app CNAMEs removed;"
echo "      the zone itself is not managed by Terraform)"
echo ""
echo "  Destroyed (must rebuild):"
echo "    - ECR repos and all images — trigger CI after up.sh to repopulate"
echo "    - Secrets Manager secrets — recreated automatically by terraform apply"
echo "    - RDS data — no snapshot taken (skip_final_snapshot = true)"
echo ""
echo "  To rebuild: bash scripts/up.sh --env $ENV"
echo "============================================================"
