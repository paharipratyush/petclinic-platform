#!/usr/bin/env bash
# Install AWS Load Balancer Controller on EKS and apply the Ingress manifest.
#
# Prerequisites:
#   - kubectl configured for the target cluster (run: aws eks update-kubeconfig --name petclinic-{env} --region eu-central-1)
#   - helm installed (>= 3.x)
#   - terraform apply completed for the target environment (IRSA role + cert must exist)
#   - CLOUDFLARE_API_TOKEN exported in your shell (Zone:Read + DNS:Edit permissions on praty.dev)
#
# Usage:
#   ./scripts/install-lb-controller.sh --env dev
#   ./scripts/install-lb-controller.sh --env prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
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

# On Windows, bash may not find 'terraform' even when terraform.exe is in PATH.
if command -v terraform &>/dev/null; then
  TF="terraform"
elif command -v terraform.exe &>/dev/null; then
  TF="terraform.exe"
else
  echo "ERROR: terraform not found in PATH. Install terraform and ensure it is accessible from bash."
  exit 1
fi

TF_DIR="$REPO_ROOT/terraform/environments/$ENV"

# terraform.exe is a Windows binary — it needs Windows-style paths (C:\...), not Unix paths.
# WSL uses wslpath; Git Bash/MSYS2 uses cygpath. Native Linux needs no conversion.
tf_chdir() {
  if [[ "$TF" == "terraform.exe" ]]; then
    if command -v wslpath &>/dev/null; then wslpath -w "$1"
    elif command -v cygpath &>/dev/null; then cygpath -w "$1"
    else echo "$1"
    fi
  else
    echo "$1"
  fi
}

echo "==> Collecting Terraform outputs from $ENV environment..."
ROLE_ARN=$("$TF" -chdir="$(tf_chdir "$TF_DIR")" output -raw lb_controller_role_arn)
CERT_ARN=$("$TF" -chdir="$(tf_chdir "$TF_DIR")" output -raw certificate_arn)
CLUSTER_NAME=$("$TF" -chdir="$(tf_chdir "$TF_DIR")" output -raw cluster_name)
ALB_SG_ID=$("$TF" -chdir="$(tf_chdir "$TF_DIR")" output -raw alb_sg_id)

[[ -z "$ROLE_ARN" ]]     && { echo "ERROR: lb_controller_role_arn output is empty — run terraform apply first"; exit 1; }
[[ -z "$CERT_ARN" ]]    && { echo "ERROR: certificate_arn output is empty — run terraform apply first"; exit 1; }
[[ -z "$CLUSTER_NAME" ]] && { echo "ERROR: cluster_name output is empty — run terraform apply first"; exit 1; }
[[ -z "$ALB_SG_ID" ]]   && { echo "ERROR: alb_sg_id output is empty — run terraform apply first"; exit 1; }

echo "  Cluster:      $CLUSTER_NAME"
echo "  LB role ARN:  $ROLE_ARN"
echo "  Cert ARN:     $CERT_ARN"
echo "  ALB SG ID:    $ALB_SG_ID"

NAMESPACE="petclinic-$ENV"

echo ""
echo "==> Step 1 — Add EKS Helm repository..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

echo ""
echo "==> Step 2 — Install AWS Load Balancer Controller..."
# The ServiceAccount annotation wires up IRSA so the controller can manage ALBs
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN" \
  --set region=eu-central-1 \
  --set vpcId="$("$TF" -chdir="$(tf_chdir "$TF_DIR")" output -raw vpc_id)" \
  --wait

echo ""
echo "==> Step 3 — Verify LB controller pods are running..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo ""
echo "==> Step 4 — Verify IngressClass 'alb' exists..."
kubectl get ingressclass alb

echo ""
echo "==> Step 5 — Apply Ingress manifest to $NAMESPACE with cert ARN substituted..."
sed \
  -e "s|CERTIFICATE_ARN_PLACEHOLDER|$CERT_ARN|g" \
  -e "s|ALB_SG_PLACEHOLDER|$ALB_SG_ID|g" \
  "$REPO_ROOT/k8s/base/ingress/ingress.yaml" \
  | kubectl apply -f - -n "$NAMESPACE"

echo ""
echo "==> Step 6 — Wait for ALB to be provisioned (this takes ~2 minutes)..."
echo "    Waiting for Ingress to get an ALB address..."
for i in $(seq 1 24); do
  ALB_ADDRESS=$(kubectl get ingress petclinic-ingress -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$ALB_ADDRESS" ]]; then
    echo ""
    echo "==> ALB provisioned: $ALB_ADDRESS"
    echo ""
    echo "==> NEXT STEP — Create the Cloudflare CNAME record:"
    echo "    Pass the ALB DNS name as a Terraform variable, then:"
    echo ""
    echo "    cd terraform/environments/$ENV"
    echo "    terraform plan -var=\"alb_dns_name=$ALB_ADDRESS\" -out plan.out"
    echo "    terraform apply plan.out"
    echo ""
    echo "    After apply, verify DNS resolution:"
    if [[ "$ENV" == "prod" ]]; then
      DOMAIN=$("$TF" -chdir="$(tf_chdir "$TF_DIR")" output -raw app_url | sed 's|https://||')
    else
      DOMAIN=$("$TF" -chdir="$(tf_chdir "$TF_DIR")" output -raw app_url | sed 's|https://||')
    fi
    echo "    nslookup $DOMAIN"
    echo "    curl -I https://$DOMAIN"
    exit 0
  fi
  echo "    Waiting... ($((i * 5))s elapsed)"
  sleep 5
done

echo ""
echo "WARNING: ALB address not available after 2 minutes. Check controller logs:"
echo "  kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
echo "  kubectl describe ingress petclinic-ingress -n $NAMESPACE"
