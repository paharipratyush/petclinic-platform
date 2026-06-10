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
#     (optional: openai_api_key = "sk-...")
#
# What this script does (in order):
#   1. terraform apply  — provisions EKS, RDS, VPC, ECR, ACM, Cloudflare DNS records
#   2. aws eks update-kubeconfig  — configures kubectl
#   3. Install ArgoCD  — GitOps controller
#   4. Apply ArgoCD Application CRDs + RBAC  — registers all 16 apps
#   5. Install External Secrets Operator  — syncs RDS + OpenAI secrets
#   6. Install AWS LB Controller + Ingress  — provisions ALB, updates DNS
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

echo "============================================================"
echo "  Bringing up petclinic-$ENV"
echo "============================================================"
echo ""

# ── Step 1: Terraform apply ────────────────────────────────────────────────
echo "==> Step 1 — Terraform apply (EKS, RDS, VPC, ACM, Cloudflare DNS)..."
echo "    This takes approximately 15-20 minutes on first run."
tf -chdir="$TF_DIR" init -upgrade
tf -chdir="$TF_DIR" plan -out /tmp/petclinic-$ENV.plan
tf -chdir="$TF_DIR" apply /tmp/petclinic-$ENV.plan
rm -f /tmp/petclinic-$ENV.plan

CLUSTER_NAME=$(tf -chdir="$TF_DIR" output -raw cluster_name)

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

# ── Step 4: Apply ArgoCD Application CRDs + RBAC ──────────────────────────
echo ""
echo "==> Step 4 — Applying ArgoCD Application CRDs and RBAC..."
kubectl apply -f "$REPO_ROOT/k8s/argocd/appproject-${ENV}.yaml" -n argocd
kubectl apply -f "$REPO_ROOT/k8s/argocd/applications/$ENV/" -n argocd
kubectl apply -f "$REPO_ROOT/k8s/argocd/argocd-rbac-cm.yaml" -n argocd
echo "    AppProject and Applications registered in ArgoCD."

# ── Step 5: Install External Secrets Operator ─────────────────────────────
echo ""
echo "==> Step 5 — Installing External Secrets Operator..."
bash "$SCRIPT_DIR/install-eso.sh" --env "$ENV"

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
echo "============================================================"
