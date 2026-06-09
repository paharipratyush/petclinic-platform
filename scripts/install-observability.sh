#!/usr/bin/env bash
# Install the observability stack (raw K8s manifests — no Helm):
#   Prometheus + Alertmanager + Grafana  →  monitoring namespace
#   Loki + FluentBit DaemonSet           →  monitoring namespace
#   Zipkin                               →  tracing namespace
#   PrometheusRule CRDs (alert rules)    →  monitoring namespace
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - EKS cluster running with EBS CSI driver (for gp2 PVCs)
#   - AWS CLI authenticated (used to auto-load SMTP credentials from Secrets Manager)
#   - jq installed (for Secrets Manager JSON parsing)
#
# SMTP credentials (required for email alerts):
#   The script auto-loads from AWS Secrets Manager: petclinic/alertmanager-smtp
#   Secret format: {"email":"you@gmail.com","password":"xxxx xxxx xxxx xxxx"}
#
#   To create the secret (first-time setup):
#     aws secretsmanager create-secret \
#       --name petclinic/alertmanager-smtp \
#       --secret-string '{"email":"you@gmail.com","password":"xxxx xxxx xxxx xxxx"}'
#
#   Override via env vars (takes precedence over Secrets Manager):
#     export SMTP_EMAIL="you@gmail.com"
#     export SMTP_PASSWORD="xxxx xxxx xxxx xxxx"
#
#   NEVER hardcode credentials here or pass them on the command line.
#
# Usage:
#   bash scripts/install-observability.sh --env dev
#   bash scripts/install-observability.sh --env prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OBS_DIR="$REPO_ROOT/k8s/base/observability"

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

# ── Load SMTP credentials ─────────────────────────────────────────────────────
# Prefer explicit env vars; fall back to AWS Secrets Manager auto-load.
SMTP_EMAIL="${SMTP_EMAIL:-""}"
SMTP_PASSWORD="${SMTP_PASSWORD:-""}"

if [[ -z "$SMTP_EMAIL" || -z "$SMTP_PASSWORD" ]]; then
  echo "==> SMTP_EMAIL/SMTP_PASSWORD not set — attempting auto-load from Secrets Manager..."
  if command -v aws &>/dev/null && command -v jq &>/dev/null; then
    SECRET_JSON=$(aws secretsmanager get-secret-value \
      --secret-id "petclinic/alertmanager-smtp" \
      --query SecretString --output text 2>/dev/null || echo "")
    if [[ -n "$SECRET_JSON" ]]; then
      [[ -z "$SMTP_EMAIL" ]]    && SMTP_EMAIL="$(echo "$SECRET_JSON"    | jq -r '.email')"
      [[ -z "$SMTP_PASSWORD" ]] && SMTP_PASSWORD="$(echo "$SECRET_JSON" | jq -r '.password')"
      echo "  Loaded from Secrets Manager: petclinic/alertmanager-smtp"
    else
      echo "  WARNING: petclinic/alertmanager-smtp not found in Secrets Manager."
      echo "  Email alerts will remain disabled (placeholder in secret)."
      echo "  Create it with:"
      echo "    aws secretsmanager create-secret \\"
      echo "      --name petclinic/alertmanager-smtp \\"
      echo "      --secret-string '{\"email\":\"you@gmail.com\",\"password\":\"xxxx xxxx xxxx xxxx\"}'"
    fi
  else
    echo "  WARNING: aws or jq not found — cannot auto-load SMTP credentials."
  fi
fi

SMTP_CONFIGURED=false
if [[ -n "$SMTP_EMAIL" && -n "$SMTP_PASSWORD" && "$SMTP_PASSWORD" != "REPLACE_WITH_SMTP_PASSWORD" ]]; then
  SMTP_CONFIGURED=true
fi

echo "============================================================"
echo "  Installing Observability Stack (raw K8s manifests)"
echo "  Environment:  $ENV"
echo "  Namespaces:   monitoring, tracing"
if [[ "$SMTP_CONFIGURED" == "true" ]]; then
  echo "  SMTP:         configured for ${SMTP_EMAIL} (will patch secret after apply)"
else
  echo "  SMTP:         not configured — email alerts disabled"
fi
echo "============================================================"
echo ""

# ── Step 1: Create namespaces ─────────────────────────────────────────────────
echo "==> Step 1 — Creating monitoring and tracing namespaces..."
kubectl apply -f "$OBS_DIR/namespace.yaml"

# ── Step 2: Install PrometheusRule CRD ────────────────────────────────────────
echo ""
echo "==> Step 2 — Installing PrometheusRule CRD..."
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
echo "  CRD installed."

# ── Step 3: Deploy Prometheus ─────────────────────────────────────────────────
echo ""
echo "==> Step 3 — Deploying Prometheus..."
kubectl apply -f "$OBS_DIR/prometheus.yaml"
kubectl rollout status deployment/prometheus -n monitoring --timeout=180s
echo "  Prometheus running."

# ── Step 4: Deploy Alertmanager ───────────────────────────────────────────────
echo ""
echo "==> Step 4 — Deploying Alertmanager..."
kubectl apply -f "$OBS_DIR/alertmanager.yaml"

if [[ "$SMTP_CONFIGURED" == "true" ]]; then
  echo "  Patching alertmanager-config secret with SMTP credentials..."
  CURRENT_CONFIG="$(kubectl -n monitoring get secret alertmanager-config \
    -o jsonpath='{.data.alertmanager\.yml}' | base64 -d)"
  NEW_CONFIG="$(printf '%s' "$CURRENT_CONFIG" \
    | sed "s|REPLACE_WITH_ALERT_EMAIL|${SMTP_EMAIL}|g" \
    | sed "s|REPLACE_WITH_SMTP_PASSWORD|${SMTP_PASSWORD}|g")"
  ENCODED="$(printf '%s' "$NEW_CONFIG" | base64 | tr -d '\n')"
  kubectl -n monitoring patch secret alertmanager-config \
    --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/data/alertmanager.yml\",\"value\":\"$ENCODED\"}]"
  unset ENCODED NEW_CONFIG CURRENT_CONFIG
  echo "  SMTP credentials configured for ${SMTP_EMAIL}."
fi

kubectl rollout status deployment/alertmanager -n monitoring --timeout=120s
echo "  Alertmanager running."

# ── Step 5: Deploy Loki ───────────────────────────────────────────────────────
echo ""
echo "==> Step 5 — Deploying Loki..."
kubectl apply -f "$OBS_DIR/loki.yaml"
kubectl rollout status deployment/loki -n monitoring --timeout=120s
echo "  Loki running."

# ── Step 6: Deploy FluentBit DaemonSet ────────────────────────────────────────
echo ""
echo "==> Step 6 — Deploying FluentBit DaemonSet..."
kubectl apply -f "$OBS_DIR/fluentbit.yaml"
# DaemonSet pods are Pending on full nodes (t4g.small ENI pod limit = 11).
# At least the pod on any node with free capacity should be Running.
# Full DaemonSet coverage requires either VPC CNI prefix delegation or Karpenter (E-14).
FLUENT_RUNNING=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=fluent-bit \
  --no-headers 2>/dev/null | grep -c "Running" || true)
if [[ "$FLUENT_RUNNING" -ge 1 ]]; then
  echo "  FluentBit running on ${FLUENT_RUNNING} node(s)."
  kubectl get pods -n monitoring -l app.kubernetes.io/name=fluent-bit --no-headers 2>/dev/null \
    | grep -v Running | grep Pending | wc -l | \
    xargs -I{} echo "  NOTE: {} FluentBit pods Pending (nodes at ENI pod limit — resolved by Karpenter in E-14)."
else
  echo "  WARNING: No FluentBit pods are Running yet. Check node pod capacity."
fi

# ── Step 7: Deploy Grafana ────────────────────────────────────────────────────
echo ""
echo "==> Step 7 — Deploying Grafana..."
kubectl apply -f "$OBS_DIR/grafana.yaml"
kubectl rollout status deployment/grafana -n monitoring --timeout=120s
echo "  Grafana running."

# ── Step 8: Apply PrometheusRule alert rules ──────────────────────────────────
echo ""
echo "==> Step 8 — Applying PrometheusRule alert rules..."
kubectl apply -f "$OBS_DIR/alerting-rules.yaml"
echo "  Alert rules applied."

# ── Step 9: Deploy Zipkin ─────────────────────────────────────────────────────
echo ""
echo "==> Step 9 — Deploying Zipkin..."
kubectl apply -f "$OBS_DIR/zipkin/zipkin.yaml"
kubectl rollout status deployment/zipkin -n tracing --timeout=120s
echo "  Zipkin running."

# ── Step 10: Verify ───────────────────────────────────────────────────────────
echo ""
echo "==> Step 10 — Verifying observability stack..."
echo ""
echo "  Pods in monitoring namespace:"
kubectl get pods -n monitoring --no-headers | awk '{printf "    %-50s %s/%s\n", $1, $2, $3}'
echo ""
echo "  Pods in tracing namespace:"
kubectl get pods -n tracing --no-headers | awk '{printf "    %-50s %s/%s\n", $1, $2, $3}'

echo ""
echo "==========================================================="
echo "  Observability stack installed — petclinic ($ENV)"
echo ""
echo "  Grafana (admin / petclinic-admin):"
echo "    kubectl port-forward svc/grafana -n monitoring 3000:3000"
echo "    open: http://localhost:3000"
echo ""
echo "  Prometheus:"
echo "    kubectl port-forward svc/prometheus -n monitoring 9090:9090"
echo "    open: http://localhost:9090/targets  (5 petclinic scrape targets)"
echo ""
echo "  Alertmanager:"
echo "    kubectl port-forward svc/alertmanager -n monitoring 9093:9093"
echo "    open: http://localhost:9093"
echo ""
echo "  Zipkin:"
echo "    kubectl port-forward svc/zipkin -n tracing 9411:9411"
echo "    open: http://localhost:9411"
echo ""
if [[ "$SMTP_CONFIGURED" != "true" ]]; then
  echo "  NOTE: Email alerts are not active (SMTP credentials not configured)."
  echo "  To enable, store credentials in Secrets Manager and re-run:"
  echo "    aws secretsmanager create-secret \\"
  echo "      --name petclinic/alertmanager-smtp \\"
  echo "      --secret-string '{\"email\":\"you@gmail.com\",\"password\":\"xxxx xxxx xxxx xxxx\"}'"
  echo "    bash $0 --env $ENV"
  echo ""
fi
echo "==========================================================="
