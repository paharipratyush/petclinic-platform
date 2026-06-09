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
#   - Internet access for PrometheusRule CRD download on first run
#
# Optional environment variables:
#   SMTP_PASSWORD  — Gmail App Password for Alertmanager email alerts.
#                    If set, patches alertmanager-config secret after apply.
#                    NEVER pass this on the command line; use:
#                      export SMTP_PASSWORD="$(aws secretsmanager get-secret-value --secret-id petclinic/alertmanager-smtp --query SecretString --output text | jq -r .password)"
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

SMTP_PASSWORD="${SMTP_PASSWORD:-""}"

echo "============================================================"
echo "  Installing Observability Stack (raw K8s manifests)"
echo "  Environment:  $ENV"
echo "  Namespaces:   monitoring, tracing"
[[ -n "$SMTP_PASSWORD" ]] \
  && echo "  SMTP:         configured (will patch secret after apply)" \
  || echo "  SMTP:         placeholder — set SMTP_PASSWORD to enable email alerts"
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

if [[ -n "$SMTP_PASSWORD" ]]; then
  echo "  Patching alertmanager-config secret with real SMTP password..."
  CURRENT_CONFIG="$(kubectl -n monitoring get secret alertmanager-config -o jsonpath='{.data.alertmanager\.yml}' | base64 -d)"
  NEW_CONFIG="$(printf '%s' "$CURRENT_CONFIG" | sed "s|REPLACE_WITH_GMAIL_APP_PASSWORD|$SMTP_PASSWORD|g")"
  ENCODED="$(printf '%s' "$NEW_CONFIG" | base64 | tr -d '\n')"
  kubectl -n monitoring patch secret alertmanager-config \
    --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/data/alertmanager.yml\",\"value\":\"$ENCODED\"}]"
  unset ENCODED NEW_CONFIG CURRENT_CONFIG
  echo "  SMTP password configured."
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
if [[ -z "$SMTP_PASSWORD" ]]; then
  echo "  NOTE: Email alerts are not active (placeholder password in secret)."
  echo "  To enable:"
  echo "    export SMTP_PASSWORD=<gmail-app-password>"
  echo "    bash $0 --env $ENV"
  echo ""
fi
echo "==========================================================="
