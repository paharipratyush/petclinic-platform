#!/usr/bin/env bash
# Cleanly destroy the petclinic platform for one environment.
#
# Order of operations:
#   1. Delete the Kubernetes Ingress so the LB Controller removes the ALB
#   2. Wait for the ALB to be deleted (prevents VPC subnet dependency violations)
#   3. Run terraform destroy
#
# ECR repositories and Secrets Manager secrets are preserved by default so
# images and credentials survive the destroy/rebuild cycle.
#
# Usage (from project root):
#   bash scripts/destroy.sh --env dev
#   bash scripts/destroy.sh --env prod
#
# IMPORTANT: For prod, set TF_VAR_openai_api_key before running to avoid
# the Secrets Manager secret version being overwritten with "demo".

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

# ── Step 2: Terraform destroy ──────────────────────────────────────────────

echo ""
echo "==> Step 2 — Running terraform destroy..."
tf -chdir="$TF_DIR" destroy -auto-approve

echo ""
echo "============================================================"
echo "  petclinic-$ENV destroyed successfully."
echo ""
echo "  Preserved (cost-free, ready to re-use):"
echo "    - ECR images in eu-central-1"
echo "    - Secrets Manager secrets (rds-credentials, openai-api-key)"
echo "    - SSM parameter /petclinic/$ENV/alb-dns-name"
echo "    - Terraform state in S3"
echo "    - Route53 hosted zone (DNS records deleted with VPC but zone remains)"
echo ""
echo "  To rebuild: bash scripts/up.sh --env $ENV"
echo "============================================================"
