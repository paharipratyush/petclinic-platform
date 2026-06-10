#!/usr/bin/env bash
# Install External Secrets Operator (ESO) on EKS and apply the ClusterSecretStore.
#
# Prerequisites:
#   - kubectl configured for the target cluster (run: aws eks update-kubeconfig --name petclinic-{env} --region eu-central-1)
#   - helm installed (>= 3.x)
#   - terraform apply completed for the target environment (ESO IRSA role must exist)
#
# Usage (from project root — works on WSL, Git Bash, Linux, macOS):
#   bash scripts/install-eso.sh --env dev
#   bash scripts/install-eso.sh --env prod

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

echo "==> Collecting Terraform outputs from $ENV environment..."
ROLE_ARN=$(tf -chdir="$TF_DIR" output -raw eso_role_arn)

[[ -z "$ROLE_ARN" ]] && { echo "ERROR: eso_role_arn output is empty — run terraform apply first"; exit 1; }

echo "  ESO role ARN: $ROLE_ARN"

echo ""
echo "==> Step 1 — Add External Secrets Helm repository..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

echo ""
echo "==> Step 2 — Install External Secrets Operator..."
# serviceAccount.name must match the ClusterSecretStore serviceAccountRef
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set serviceAccount.name=external-secrets-sa \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN" \
  --wait

echo ""
echo "==> Step 3 — Verify ESO pods are running..."
kubectl rollout status deployment/external-secrets -n external-secrets --timeout=120s
kubectl get pods -n external-secrets

echo ""
echo "==> Step 4 — Wait for ESO CRDs to be registered..."
# CRDs are installed by the Helm chart but registered asynchronously.
# kubectl wait --for=condition=Established blocks until the API server accepts them.
kubectl wait --for=condition=Established \
  crd/clustersecretstores.external-secrets.io \
  crd/externalsecrets.external-secrets.io \
  --timeout=60s
echo "    CRDs are ready."

echo ""
echo "==> Step 5 — Apply ClusterSecretStore..."
kubectl apply -f "$REPO_ROOT/k8s/base/external-secrets/cluster-secret-store.yaml"

echo ""
echo "==> Step 6 — Verify ClusterSecretStore is Ready..."
for i in $(seq 1 12); do
  STATUS=$(kubectl get clustersecretstore aws-secrets-manager \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$STATUS" == "True" ]]; then
    echo "    ClusterSecretStore is Ready."
    break
  fi
  echo "    Waiting for ClusterSecretStore... ($((i * 5))s elapsed)"
  sleep 5
done

NAMESPACE="petclinic-$ENV"

echo ""
echo "==> Step 7 — Ensure petclinic namespaces exist..."
kubectl apply -f "$REPO_ROOT/k8s/base/namespaces/namespaces.yaml"

echo ""
echo "==> Step 8 — Apply ExternalSecret manifests to $NAMESPACE..."
# Substitute both the namespace metadata AND the Secrets Manager key prefix (petclinic/dev/ → petclinic/$ENV/).
# Without the key substitution, prod ESO role (which only has petclinic/prod/* access) would fail on dev secret paths.
sed -e "s/namespace: petclinic-dev/namespace: $NAMESPACE/g" \
    -e "s|petclinic/dev/|petclinic/$ENV/|g" \
  "$REPO_ROOT/k8s/base/external-secrets/rds-credentials.yaml" | kubectl apply -f -
sed -e "s/namespace: petclinic-dev/namespace: $NAMESPACE/g" \
    -e "s|petclinic/dev/|petclinic/$ENV/|g" \
  "$REPO_ROOT/k8s/base/external-secrets/openai-api-key.yaml" | kubectl apply -f -

echo ""
echo "==> Step 9 — Verify K8s Secrets were created..."
for i in $(seq 1 12); do
  RDS_SECRET=$(kubectl get secret rds-credentials -n "$NAMESPACE" --ignore-not-found -o name 2>/dev/null || true)
  OPENAI_SECRET=$(kubectl get secret openai-api-key -n "$NAMESPACE" --ignore-not-found -o name 2>/dev/null || true)
  if [[ -n "$RDS_SECRET" && -n "$OPENAI_SECRET" ]]; then
    echo ""
    echo "==> Secrets synced successfully:"
    kubectl get secret rds-credentials openai-api-key -n "$NAMESPACE"
    echo ""
    echo "==> E-7 complete. External Secrets Operator is running and secrets are synced."
    exit 0
  fi
  echo "    Waiting for secrets to sync... ($((i * 5))s elapsed)"
  sleep 5
done

echo ""
echo "WARNING: Secrets not synced after 60 seconds. Check ESO logs:"
echo "  kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets"
echo "  kubectl describe externalsecret rds-credentials -n $NAMESPACE"
echo "  kubectl describe externalsecret openai-api-key -n $NAMESPACE"
