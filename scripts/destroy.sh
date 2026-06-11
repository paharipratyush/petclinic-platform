#!/usr/bin/env bash
# Cleanly destroy the petclinic platform for one environment.
#
# Order of operations:
#   1.   Pre-flight: validate required env vars (fail fast before any AWS calls)
#   2.   Delete Kubernetes Ingress to trigger ALB removal by LB Controller
#   2.5. Drain Karpenter-provisioned nodes (terminates EC2 before VPC is removed)
#   3.   Run terraform destroy with automatic VPC dependency remediation:
#          - On DependencyViolation: terminate remaining EC2 instances, wait,
#            clean up orphaned ENIs, then retry VPC destruction
#          - On ACM for_each error (cert gone, DNS records in state): remove
#            stale state entries before retrying
#
# ECR repositories are destroyed (force_delete = true). Images must be rebuilt
# after up.sh. Trigger the CI pipeline via GitHub Actions → "CI - Build and Push"
# → "Run workflow" (force_rebuild_all=true). Do NOT push an empty commit — the
# dorny/paths-filter step sees no file changes and skips all builds.
# Secrets Manager secrets are force-deleted (recovery_window_in_days = 0) and
# can be recreated immediately by terraform apply.
#
# Usage (from project root):
#   bash scripts/destroy.sh --env dev
#   bash scripts/destroy.sh --env prod
#
# Required environment variables — script exits immediately if any are unset:
#   CLOUDFLARE_API_TOKEN          — valid token with Zone:Read + DNS:Edit scope
#   TF_VAR_domain_name            — e.g. "yourdomain.com"
#   TF_VAR_openai_api_key         — any non-empty string (not used during destroy)
#   TF_VAR_grafana_admin_password — any non-empty string (not used during destroy)
#   TF_VAR_budget_alert_email     — any non-empty string (not used during destroy)

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

# ── Pre-flight: validate required environment variables ─────────────────────
# Terraform prompts interactively for missing variables, turning an automated
# destroy into an interactive session. Catch missing vars here instead.

MISSING_VARS=()
[[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]          && MISSING_VARS+=("CLOUDFLARE_API_TOKEN")
[[ -z "${TF_VAR_domain_name:-}" ]]            && MISSING_VARS+=("TF_VAR_domain_name")
[[ -z "${TF_VAR_openai_api_key:-}" ]]         && MISSING_VARS+=("TF_VAR_openai_api_key")
[[ -z "${TF_VAR_grafana_admin_password:-}" ]] && MISSING_VARS+=("TF_VAR_grafana_admin_password")
[[ -z "${TF_VAR_budget_alert_email:-}" ]]     && MISSING_VARS+=("TF_VAR_budget_alert_email")

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
  echo "ERROR: The following required environment variables are not set:"
  for v in "${MISSING_VARS[@]}"; do
    echo "  export $v=..."
  done
  echo ""
  echo "TF_VAR_* values are not used during destroy — any non-empty string works."
  echo "CLOUDFLARE_API_TOKEN must be a valid token with Zone:Read + DNS:Edit scope."
  exit 1
fi

echo "============================================================"
echo "  DESTROYING petclinic-$ENV"
echo "  This will delete: EKS, RDS, VPC, IGW, ALB, DNS records,"
echo "    ECR repos + images, Secrets Manager secrets, RDS data."
echo "  Preserved: Terraform state (S3/DynamoDB), Cloudflare zone."
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
        --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-${NAMESPACE//petclinic-/petclinic-}-')]|length(@)" \
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

# ── Step 2: Terraform destroy with automatic VPC dependency remediation ───────
#
# Root cause of VPC DependencyViolation errors: when Terraform destroys the EKS
# cluster and managed node group, AWS terminates EC2 instances asynchronously.
# Instances linger in "shutting-down" state and VPC CNI warm ENIs (aws-K8s-*)
# stay attached for 15–30 s after the instance reports terminated. Terraform
# immediately tries to delete subnets/IGW/SGs while those ENIs still exist.
#
# Recovery strategy (automatic — no manual intervention required):
#   1. Capture VPC ID from state before destroying anything.
#   2. Run full terraform destroy.
#   3. On failure: terminate remaining instances, wait for termination, sleep
#      30 s for ENI release, detach + delete all remaining ENIs, retry VPC.
#   4. Handle ACM for_each error on partial re-run: if the cert is gone but
#      cloudflare_record.cert_validation entries remain in state, remove them
#      before retrying so Terraform can plan the destroy.

echo ""
echo "==> Step 1.8 — Pre-destroy RDS preparation..."

RDS_ID="petclinic-${ENV}-mysql"
if [[ "$ENV" == "prod" ]]; then
  # Prod RDS has deletion_protection=true and skip_final_snapshot=false.
  # Deletion protection must be disabled before terraform destroy can remove it.
  # The final snapshot (${RDS_ID}-final) will be created automatically by Terraform.
  echo "  Disabling RDS deletion protection on $RDS_ID (prod requirement)..."
  aws rds modify-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --no-deletion-protection \
    --apply-immediately \
    --region "$REGION" > /dev/null 2>&1 \
    && echo "  Deletion protection disabled." \
    || echo "  Could not disable deletion protection (instance may not exist — continuing)."
  # Allow a few seconds for the modification to take effect
  sleep 10

  # If a final snapshot from a previous destroy exists, delete it so Terraform
  # can create a fresh one. Second prod destroy fails with DBSnapshotAlreadyExists
  # if the previous final snapshot is still present.
  FINAL_SNAPSHOT="${RDS_ID}-final"
  echo "  Checking for existing final snapshot ($FINAL_SNAPSHOT)..."
  SNAP_STATUS=$(aws rds describe-db-snapshots \
    --db-snapshot-identifier "$FINAL_SNAPSHOT" \
    --region "$REGION" \
    --query 'DBSnapshots[0].Status' \
    --output text 2>/dev/null || echo "")
  if [[ "$SNAP_STATUS" == "available" ]]; then
    echo "  Deleting $FINAL_SNAPSHOT (will be re-created during this destroy)..."
    aws rds delete-db-snapshot \
      --db-snapshot-identifier "$FINAL_SNAPSHOT" \
      --region "$REGION" > /dev/null \
      && echo "  Snapshot deleted." \
      || echo "  WARNING: Could not delete snapshot — destroy may fail with DBSnapshotAlreadyExists."
    echo "  Waiting 30s for snapshot deletion to complete..."
    sleep 30
  elif [[ -n "$SNAP_STATUS" && "$SNAP_STATUS" != "None" ]]; then
    echo "  WARNING: Snapshot $FINAL_SNAPSHOT exists (status: $SNAP_STATUS) — destroy may fail."
  fi
fi

echo ""
echo "==> Step 2 — Running terraform destroy..."

# Ensure backend.tf has the real account ID (replaces YOUR_ACCOUNT_ID placeholder at runtime)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [[ -n "$ACCOUNT_ID" ]]; then
  sed -i "s|petclinic-terraform-state-YOUR_ACCOUNT_ID|petclinic-terraform-state-${ACCOUNT_ID}|g" \
    "$TF_DIR/backend.tf" 2>/dev/null || true
fi

# Re-initialize if backend config changed (idempotent — safe to run even if already initialized)
if ! tf -chdir="$TF_DIR" output -raw vpc_id >/dev/null 2>&1; then
  echo "  Backend reinit required — running terraform init -reconfigure..."
  tf -chdir="$TF_DIR" init -reconfigure -input=false 2>&1 \
    || { echo "ERROR: terraform init failed. Check backend.tf and AWS credentials."; exit 1; }
fi

VPC_ID=$(tf -chdir="$TF_DIR" output -raw vpc_id 2>/dev/null || echo "")
[[ -n "$VPC_ID" ]] && echo "  VPC ID: $VPC_ID (saved for auto-remediation if needed)"

DESTROY_OK=true
tf -chdir="$TF_DIR" destroy -auto-approve || DESTROY_OK=false

if ! $DESTROY_OK; then
  echo ""
  echo "  terraform destroy failed — starting automatic VPC dependency remediation..."

  # Recover VPC ID from remaining state if it wasn't captured before destroy
  if [[ -z "$VPC_ID" ]]; then
    VPC_ID=$(tf -chdir="$TF_DIR" state show module.vpc.aws_vpc.main 2>/dev/null \
      | awk '/^\s*id\s*=\s*"/{gsub(/[" ]/, "", $3); print $3}' || echo "")
  fi

  if [[ -z "$VPC_ID" ]]; then
    echo "ERROR: terraform destroy failed and VPC ID could not be determined."
    echo "  Review the error above and check the AWS console for remaining resources."
    exit 1
  fi

  echo "  VPC: $VPC_ID"

  # ── 2a: Terminate remaining EC2 instances ─────────────────────────────────
  INSTANCE_IDS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null | tr '\t' ' ' | xargs -r echo || echo "")

  if [[ -n "$INSTANCE_IDS" ]]; then
    echo "  Terminating remaining instances: $INSTANCE_IDS"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS || true
    echo "  Waiting for instance termination..."
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS || true
  else
    echo "  No running instances found in VPC."
  fi

  # ── 2b: Wait for VPC CNI warm ENIs to be released ─────────────────────────
  # aws-K8s-* ENIs can linger 15–30 s after instance termination is reported.
  echo "  Waiting 30s for ENIs to be released after instance termination..."
  sleep 30

  # ── 2c: Detach and delete orphaned ENIs ───────────────────────────────────
  ENI_TABLE=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Attachment.AttachmentId,Description]' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$ENI_TABLE" ]]; then
    echo "  Detaching orphaned ENIs..."
    while IFS=$'\t' read -r eni_id attachment_id _desc; do
      [[ -z "$eni_id" || "$eni_id" == "None" ]] && continue
      if [[ -n "$attachment_id" && "$attachment_id" != "None" && "$attachment_id" != "null" ]]; then
        echo "    Detaching $eni_id (attachment $attachment_id)..."
        aws ec2 detach-network-interface --region "$REGION" \
          --attachment-id "$attachment_id" --force 2>/dev/null || true
      fi
    done <<< "$ENI_TABLE"

    echo "  Waiting 15s for ENI detachment..."
    sleep 15

    echo "  Deleting orphaned ENIs..."
    while IFS=$'\t' read -r eni_id _ _; do
      [[ -z "$eni_id" || "$eni_id" == "None" ]] && continue
      echo "    Deleting $eni_id..."
      aws ec2 delete-network-interface --region "$REGION" \
        --network-interface-id "$eni_id" 2>/dev/null || true
    done <<< "$ENI_TABLE"
  else
    echo "  No orphaned ENIs found."
  fi

  # ── 2d: Handle Cloudflare / ACM cert cleanup ─────────────────────────────
  # Two scenarios both leave cloudflare_record entries stranded in state:
  #
  # Case A — ACM for_each error on partial re-run: a previous partial destroy
  #   removed the ACM cert from AWS but left cert_validation records in state.
  #   Terraform cannot plan destroy because for_each keys come from the now-
  #   missing cert resource. Fix: remove stale state entries.
  #
  # Case B — Cloudflare 81044 "Record does not exist": the wildcard cert has two
  #   SANs (*.domain + domain) that share one CNAME record in Cloudflare.
  #   allow_overwrite=true handles creation; on destroy the first deletion succeeds
  #   and the second gets "Record does not exist. (81044)". The app DNS record
  #   (petclinic-{env}.domain → ALB) can also be 81044 if the ALB was already
  #   removed before destroy ran. Fix: remove all cloudflare_record entries from
  #   state, delete the ACM cert from AWS directly, clean up remaining state.
  ALL_CF_RECORDS=$(tf -chdir="$TF_DIR" state list 2>/dev/null \
    | grep "cloudflare_record" || true)
  CERT_IN_STATE=$(tf -chdir="$TF_DIR" state list 2>/dev/null \
    | grep "module.dns.aws_acm_certificate.main$" || true)

  if [[ -n "$ALL_CF_RECORDS" ]]; then
    echo "  Removing stale Cloudflare record(s) from state (81044 or cert_validation duplicate)..."
    echo "$ALL_CF_RECORDS" | while read -r resource; do
      echo "    Removing: $resource"
      tf -chdir="$TF_DIR" state rm "$resource" 2>/dev/null || true
    done
  fi

  if [[ -n "$CERT_IN_STATE" ]]; then
    # Extract cert ARN from state and delete from AWS, then remove state entry
    CERT_ARN=$(tf -chdir="$TF_DIR" state show module.dns.aws_acm_certificate.main 2>/dev/null \
      | grep '^\s*id\s*=' | head -1 | awk '{print $3}' | tr -d '"' || echo "")
    if [[ -n "$CERT_ARN" ]]; then
      echo "  Deleting orphaned ACM certificate: $CERT_ARN"
      aws acm delete-certificate --certificate-arn "$CERT_ARN" --region "$REGION" 2>/dev/null \
        && echo "    Deleted." \
        || echo "    WARNING: could not delete cert (may be in use or already deleted)."
    fi
    for _acm_res in \
      module.dns.aws_acm_certificate.main \
      module.dns.aws_acm_certificate_validation.main \
      module.dns.data.cloudflare_zone.main; do
      tf -chdir="$TF_DIR" state rm "$_acm_res" 2>/dev/null || true
    done
    echo "  ACM cert state entries removed."
  fi

  # Delete any other orphaned ACM certs for this domain (from previous partial
  # destroys) that are no longer in Terraform state but still exist in AWS.
  if [[ -n "${TF_VAR_domain_name:-}" ]]; then
    ORPHAN_CERTS=$(aws acm list-certificates --region "$REGION" \
      --query "CertificateSummaryList[?InUse==\`false\`].CertificateArn" \
      --output text 2>/dev/null || true)
    for _arn in $ORPHAN_CERTS; do
      _domain=$(aws acm describe-certificate --certificate-arn "$_arn" --region "$REGION" \
        --query "Certificate.DomainName" --output text 2>/dev/null || echo "")
      if [[ "$_domain" == "*.${TF_VAR_domain_name}" ]]; then
        echo "  Deleting additional orphaned ACM cert: $_arn"
        aws acm delete-certificate --certificate-arn "$_arn" --region "$REGION" 2>/dev/null \
          || echo "  WARNING: could not delete $_arn"
      fi
    done
  fi

  # ── 2e: Retry VPC destruction ─────────────────────────────────────────────
  echo ""
  echo "  Retrying destruction of remaining VPC resources..."
  VPC_REMAINING=$(tf -chdir="$TF_DIR" state list 2>/dev/null | grep "module.vpc" || true)
  if [[ -n "$VPC_REMAINING" ]]; then
    tf -chdir="$TF_DIR" destroy -target=module.vpc -auto-approve
  else
    echo "  No VPC resources remain in state."
  fi

  # ── Final state check ─────────────────────────────────────────────────────
  REMAINING_COUNT=$(tf -chdir="$TF_DIR" state list 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$REMAINING_COUNT" -gt 0 ]]; then
    echo ""
    echo "  WARNING: $REMAINING_COUNT resource(s) still in Terraform state:"
    tf -chdir="$TF_DIR" state list 2>/dev/null || true
    echo "  Verify these are cleaned up in the AWS console before re-running up.sh."
  fi
fi

echo ""
echo "============================================================"
echo "  petclinic-$ENV destroyed."
echo ""
echo "  Preserved (not managed by this script):"
echo "    - Terraform state in S3 (petclinic-terraform-state-*/)"
echo "    - DynamoDB lock table (petclinic-terraform-locks)"
echo "    - Cloudflare DNS zone (ACM validation + app CNAMEs removed;"
echo "      the zone itself is not managed by Terraform)"
echo ""
echo "  Destroyed (must rebuild with up.sh):"
echo "    - EKS cluster, node groups, add-ons"
if [[ "$ENV" == "prod" ]]; then
  echo "    - RDS instance (final snapshot: petclinic-prod-mysql-final created in AWS)"
else
  echo "    - RDS instance (no snapshot — skip_final_snapshot = true)"
fi
echo "    - VPC, subnets, IGW, security groups, NAT"
echo "    - ECR repos + all images — trigger CI via workflow_dispatch after up.sh"
echo "    - Secrets Manager secrets — recreated automatically by terraform apply"
echo "    - Cloudflare DNS records — recreated automatically by terraform apply"
echo ""
echo "  To rebuild: bash scripts/up.sh --env $ENV"
echo "  Then repopulate ECR: GitHub Actions → 'CI - Build and Push' → Run workflow"
echo "    (force_rebuild_all=true — do NOT push an empty commit)"
echo "============================================================"
