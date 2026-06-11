#!/usr/bin/env bash
# Bring up the complete petclinic platform from scratch.
#
# Prerequisites:
#   - AWS CLI configured with credentials for the target account
#   - terraform, kubectl, helm installed and in PATH
#   - S3 backend and DynamoDB table exist (run scripts/bootstrap-state.sh once)
#   - CLOUDFLARE_API_TOKEN exported in your shell (Zone:Read + DNS:Edit on the domain)
#   - terraform.tfvars in terraform/environments/{env}/ with at minimum:
#       domain_name = "yourdomain.com"   # must be a Cloudflare-managed domain
#     (optional: openai_api_key = "sk-...", grafana_admin_password = "...", budget_alert_email = "...")
#
# What this script does (in order):
#   1.   terraform apply — provisions EKS, RDS, VPC, ECR, ACM, Cloudflare DNS records
#   1a.  Auto-update ECR registry URL in helm-values/{env}.yaml (account-specific, env-prefixed)
#   1b.  Auto-update RDS endpoint in helm-values/ if it changed (happens on every rebuild)
#   2.   aws eks update-kubeconfig — configures kubectl
#   3.   Install ArgoCD — GitOps controller
#   3.5. Install Karpenter autoscaler + metrics-server + NodePool
#   4.   Install External Secrets Operator — syncs RDS + OpenAI secrets before ArgoCD
#   5.   Apply ArgoCD Application CRDs + RBAC — registers all 16 apps (secrets ready)
#   6.   Install AWS LB Controller + Ingress — provisions ALB, updates DNS
#   7.   Install Observability stack (Prometheus, Grafana, Loki, FluentBit, Zipkin, Alertmanager)
#
# Usage (from project root):
#   bash scripts/up.sh --env dev
#   bash scripts/up.sh --env prod

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

# ── Pre-flight: validate CLOUDFLARE_API_TOKEN ──────────────────────────────
# This is the only required env var not storable in terraform.tfvars (it is a
# provider credential, not a Terraform variable). Catch it here rather than
# letting Terraform fail 10 minutes into a 20-minute apply.
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN is not set."
  echo "  export CLOUDFLARE_API_TOKEN=<your Cloudflare API token>"
  echo "  Required scope: Zone:Read + DNS:Edit on the domain"
  exit 1
fi

echo "============================================================"
echo "  Bringing up petclinic-$ENV"
echo "============================================================"
echo ""

# ── Step 1: Terraform apply ────────────────────────────────────────────────
echo "==> Step 1 — Terraform apply (EKS, RDS, VPC, ACM, Cloudflare DNS)..."
echo "    This takes approximately 15-20 minutes on first run."

# Clean up stale files left by a previous destroy run. These are harmless but
# confusing — terraform ignores them, but they pollute the working directory.
for _stale in "$TF_DIR/errored.tfstate" "$TF_DIR/destroy.plan" "$TF_DIR/plan.out"; do
  [[ -f "$_stale" ]] && { echo "  Removing stale $(basename "$_stale")..."; rm -f "$_stale"; }
done

tf -chdir="$TF_DIR" init -upgrade
tf -chdir="$TF_DIR" plan -out /tmp/petclinic-$ENV.plan
tf -chdir="$TF_DIR" apply /tmp/petclinic-$ENV.plan
rm -f /tmp/petclinic-$ENV.plan

CLUSTER_NAME=$(tf -chdir="$TF_DIR" output -raw cluster_name)

# ── Step 1a: Auto-update ECR registry URL in helm-values ──────────────────
# The ECR registry URL includes the AWS account ID, which differs per user.
# helm-values/{env}.yaml ships with a YOUR_ACCOUNT_ID placeholder; replace it
# with the real URL from terraform output so any fork works without manual edits.
echo ""
echo "==> Step 1a — Updating ECR registry URL in helm-values/$ENV.yaml..."
# ecr_registry_url is the base registry (account.dkr.ecr.region.amazonaws.com).
# The Helm image template renders: {registry}/{name}:{tag}, so registry must include
# the per-environment path prefix (petclinic-dev / petclinic-prod).
ECR_REGISTRY=$(tf -chdir="$TF_DIR" output -raw ecr_registry_url 2>/dev/null || echo "")
[[ -n "$ECR_REGISTRY" ]] && ECR_REGISTRY="${ECR_REGISTRY}/petclinic-${ENV}"
if [[ -n "$ECR_REGISTRY" ]]; then
  HV_ENV_FILE="$REPO_ROOT/helm-values/$ENV.yaml"
  CURRENT_REGISTRY=$(grep -m1 "registry:" "$HV_ENV_FILE" | sed "s/.*registry: *['\"]//;s/['\"].*//" | tr -d ' ')
  if [[ "$CURRENT_REGISTRY" != "$ECR_REGISTRY" ]]; then
    echo "  Updating registry: $CURRENT_REGISTRY → $ECR_REGISTRY"
    sed -i "s|registry:.*|registry: \"$ECR_REGISTRY\"|" "$HV_ENV_FILE"
    git -C "$REPO_ROOT" add "$HV_ENV_FILE"
    git -C "$REPO_ROOT" commit -m "fix($ENV): update ECR registry URL to $ECR_REGISTRY" \
      || echo "  (no change needed in git)"
    git -C "$REPO_ROOT" push origin main \
      || echo "  WARNING: git push failed — push helm-values/$ENV.yaml manually before ArgoCD syncs"
  else
    echo "  ECR registry already correct ($ECR_REGISTRY)."
  fi
fi

# ── Step 1b: Auto-update RDS endpoint in helm-values if it changed ─────────
# RDS gets a new hostname (random AWS suffix) on every destroy/rebuild.
# If the endpoint in helm-values/ doesn't match what Terraform just created,
# update it and push so ArgoCD deploys with the correct datasource URL.
echo ""
echo "==> Step 1b — Checking RDS endpoint..."
RDS_ENDPOINT=$(tf -chdir="$TF_DIR" output -raw rds_endpoint 2>/dev/null || echo "")
if [[ -n "$RDS_ENDPOINT" ]]; then
  if [[ "$ENV" == "dev" ]]; then
    HV_FILES=("helm-values/customers-service.yaml" "helm-values/visits-service.yaml" "helm-values/vets-service.yaml")
  else
    HV_FILES=("helm-values/customers-service-prod.yaml" "helm-values/visits-service-prod.yaml" "helm-values/vets-service-prod.yaml")
  fi
  CURRENT_EP=$(grep -m1 "SPRING_DATASOURCE_URL" "$REPO_ROOT/${HV_FILES[0]}" \
    | sed 's|.*jdbc:mysql://\([^:]*\):.*|\1|' | tr -d ' ' 2>/dev/null || echo "")
  if [[ -n "$CURRENT_EP" && "$CURRENT_EP" != "$RDS_ENDPOINT" ]]; then
    echo "  RDS endpoint changed: $CURRENT_EP → $RDS_ENDPOINT"
    echo "  Updating helm-values datasource URLs and pushing..."
    for f in "${HV_FILES[@]}"; do
      sed -i "s|jdbc:mysql://[^:]*:3306|jdbc:mysql://$RDS_ENDPOINT:3306|g" "$REPO_ROOT/$f"
    done
    git -C "$REPO_ROOT" add "${HV_FILES[@]}"
    git -C "$REPO_ROOT" commit -m "fix($ENV): update RDS endpoint to $RDS_ENDPOINT"
    git -C "$REPO_ROOT" push origin main \
      || echo "  WARNING: git push failed — update helm-values/ manually then push before ArgoCD syncs"
  else
    echo "  RDS endpoint unchanged ($RDS_ENDPOINT)."
  fi
fi

echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  DNS handled automatically via Cloudflare provider       │"
echo "  │                                                          │"
echo "  │  The ACM cert validation CNAME was created in            │"
echo "  │  Cloudflare by Terraform. The certificate should         │"
echo "  │  issue within 2-5 minutes. No registrar action needed.   │"
echo "  │                                                          │"
echo "  │  Prerequisites: CLOUDFLARE_API_TOKEN must be set in      │"
echo "  │  your environment with Zone:Read + DNS:Edit perms.       │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""

# ── Step 2: Configure kubectl ──────────────────────────────────────────────
echo "==> Step 2 — Configuring kubectl for cluster: $CLUSTER_NAME..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region eu-central-1
kubectl get nodes

# ── Step 3: Install ArgoCD ─────────────────────────────────────────────────
echo ""
echo "==> Step 3 — Installing ArgoCD..."
kubectl apply -f "$REPO_ROOT/k8s/argocd/install/namespace.yaml"
kubectl apply --server-side --force-conflicts --validate=false -n argocd -f "$REPO_ROOT/k8s/argocd/install/install.yaml"

echo "    Waiting for ArgoCD CRDs to be established..."
kubectl wait --for=condition=Established \
  crd/applications.argoproj.io \
  crd/applicationsets.argoproj.io \
  crd/appprojects.argoproj.io \
  --timeout=60s

echo "    Waiting for ArgoCD deployments to be available (up to 5 minutes)..."
kubectl wait deployment -n argocd \
  argocd-server argocd-repo-server argocd-applicationset-controller argocd-notifications-controller \
  --for=condition=Available --timeout=300s

# ── Step 3.5: Install Karpenter autoscaler + metrics-server + NodePool ──────
echo ""
echo "==> Step 3.5 — Installing Karpenter autoscaler..."
KARPENTER_ROLE_ARN=$(tf -chdir="$TF_DIR" output -raw karpenter_role_arn)
KARPENTER_QUEUE=$(tf -chdir="$TF_DIR" output -raw karpenter_queue_name)

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.5.0 \
  --namespace kube-system \
  --set settings.clusterName="$CLUSTER_NAME" \
  --set settings.interruptionQueue="$KARPENTER_QUEUE" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARPENTER_ROLE_ARN" \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait

echo "    Waiting for Karpenter CRDs to be established..."
kubectl wait --for=condition=Established \
  crd/nodepools.karpenter.sh \
  crd/ec2nodeclasses.karpenter.k8s.aws \
  --timeout=60s

echo "    Applying NodePool and EC2NodeClass..."
# nodepool.yaml is written for 'petclinic-dev'. Substitute env name so the
# same file works for prod (subnetSelectorTerms, securityGroupSelectorTerms,
# and instanceProfile all use the cluster/env name as the discovery tag value).
sed "s/petclinic-dev/petclinic-$ENV/g" \
  "$REPO_ROOT/k8s/base/karpenter/nodepool.yaml" | kubectl apply -f -

echo "    Installing metrics-server (required for HPA)..."
kubectl apply -f "$REPO_ROOT/k8s/base/karpenter/metrics-server.yaml"

# ── Step 4: Install External Secrets Operator ─────────────────────────────
# ESO must be ready before ArgoCD apps are registered. Dev auto-sync fires
# immediately after app registration; pods that need rds-credentials or
# openai-api-key will fail with CreateContainerConfigError until the
# SecretStore is available.
echo ""
echo "==> Step 4 — Installing External Secrets Operator..."
bash "$SCRIPT_DIR/install-eso.sh" --env "$ENV"

# ── Step 5: Apply ArgoCD Application CRDs + RBAC ──────────────────────────
echo ""
echo "==> Step 5 — Applying ArgoCD Application CRDs and RBAC..."

# Auto-detect the platform repo URL from the local git remote so that any fork
# works without manual YAML edits. ArgoCD must point to the actual fork, not the
# original author's repo, to pick up Helm chart changes pushed by CI.
PLATFORM_REPO_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
if [[ -z "$PLATFORM_REPO_URL" ]]; then
  echo "  WARNING: could not detect git remote origin. ArgoCD will use the URL already in the YAML."
  kubectl apply -f "$REPO_ROOT/k8s/argocd/appproject-${ENV}.yaml" -n argocd
  kubectl apply -f "$REPO_ROOT/k8s/argocd/applications/$ENV/" -n argocd
else
  # Normalise to https:// and ensure .git suffix (ArgoCD requires it)
  PLATFORM_REPO_URL=$(echo "$PLATFORM_REPO_URL" \
    | sed 's|git@github\.com:\(.*\)|https://github.com/\1|' \
    | sed 's|\.git$||').git
  echo "  Using platform repo: $PLATFORM_REPO_URL"

  # AppProject
  sed "s|https://github.com/[^/]*/petclinic-platform\.git|${PLATFORM_REPO_URL}|g" \
    "$REPO_ROOT/k8s/argocd/appproject-${ENV}.yaml" | kubectl apply -n argocd -f -

  # Application CRDs — pipe each file through sed to substitute the repoURL
  for _app_yaml in "$REPO_ROOT/k8s/argocd/applications/$ENV/"*.yaml; do
    sed "s|https://github.com/[^/]*/petclinic-platform\.git|${PLATFORM_REPO_URL}|g" \
      "$_app_yaml" | kubectl apply -n argocd -f -
  done
fi

kubectl apply -f "$REPO_ROOT/k8s/argocd/argocd-rbac-cm.yaml" -n argocd
echo "    AppProject and Applications registered in ArgoCD."

# ── Step 6: Install ALB Controller + Ingress + DNS ────────────────────────
echo ""
echo "==> Step 6 — Installing AWS Load Balancer Controller and provisioning ALB..."
bash "$SCRIPT_DIR/install-lb-controller.sh" --env "$ENV"

# ── Step 7: Install Observability Stack ───────────────────────────────────
echo ""
echo "==> Step 7 — Installing observability stack (Prometheus, Grafana, Loki, Zipkin)..."
echo "    Set ALERT_EMAIL, SMTP_HOST, SMTP_FROM, SMTP_USERNAME, SMTP_PASSWORD env vars to enable email alerts."
bash "$SCRIPT_DIR/install-observability.sh" --env "$ENV"

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  petclinic-$ENV is UP."
APP_URL=$(tf -chdir="$TF_DIR" output -raw app_url 2>/dev/null || echo "https://petclinic-$ENV.<your-domain>")
echo ""
echo "  App URL:    $APP_URL"
echo "  ArgoCD:     kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "              then open https://localhost:8443"
echo ""
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o go-template='{{.data.password | base64decode}}' 2>/dev/null || echo "(already changed)")
echo "  ArgoCD admin password: $ARGOCD_PASS"
echo ""
echo "  Services start within ~5 minutes after ArgoCD syncs."
echo "  Check: kubectl get pods -n $NAMESPACE"
echo ""
echo "  If this is a fresh rebuild (ECR was wiped by destroy.sh):"
echo "  Repopulate ECR → GitHub Actions → 'CI - Build and Push' → Run workflow"
echo "    force_rebuild_all=true  (do NOT push an empty commit)"
echo "============================================================"
