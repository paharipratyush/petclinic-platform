#!/usr/bin/env bash
# Install the observability stack on EKS:
#   Prometheus + Grafana + Alertmanager (kube-prometheus-stack)
#   Loki (log aggregation) + FluentBit (log collection)
#   Zipkin (distributed tracing)
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - helm installed (>= 3.x)
#   - terraform apply completed for the target env (EKS + EBS CSI driver must exist)
#
# Optional environment variables:
#   ALERT_EMAIL      — email address to receive alert notifications (default: skips SMTP config)
#   SMTP_HOST        — SMTP smarthost, e.g. smtp.gmail.com:587 (default: localhost:587)
#   SMTP_FROM        — sender address (default: alertmanager@petclinic.local)
#   SMTP_USERNAME    — SMTP auth username (default: empty)
#   SMTP_PASSWORD    — SMTP auth password (default: empty, never commit this)
#
# Usage (from project root):
#   bash scripts/install-observability.sh --env dev
#   bash scripts/install-observability.sh --env prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OBS_DIR="$REPO_ROOT/k8s/base/observability"

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

PETCLINIC_NAMESPACE="petclinic-$ENV"

# Size and retention per environment
if [[ "$ENV" == "dev" ]]; then
  PROMETHEUS_STORAGE_SIZE="10Gi"
  PROMETHEUS_RETENTION="7d"
  LOKI_STORAGE_SIZE="10Gi"
  LOKI_RETENTION="168h"
else
  PROMETHEUS_STORAGE_SIZE="50Gi"
  PROMETHEUS_RETENTION="15d"
  LOKI_STORAGE_SIZE="50Gi"
  LOKI_RETENTION="720h"
fi

# Alert email / SMTP settings
ALERT_EMAIL="${ALERT_EMAIL:-""}"
SMTP_HOST="${SMTP_HOST:-"localhost:587"}"
SMTP_FROM="${SMTP_FROM:-"alertmanager@petclinic.local"}"
SMTP_USERNAME="${SMTP_USERNAME:-""}"
SMTP_PASSWORD="${SMTP_PASSWORD:-""}"

echo "============================================================"
echo "  Installing Observability Stack — petclinic-$ENV"
echo "  Namespace:          monitoring (observability) + tracing"
echo "  Prometheus storage: $PROMETHEUS_STORAGE_SIZE, retention: $PROMETHEUS_RETENTION"
echo "  Loki storage:       $LOKI_STORAGE_SIZE, retention: $LOKI_RETENTION"
[[ -n "$ALERT_EMAIL" ]] && echo "  Alert email:        $ALERT_EMAIL" || echo "  Alert email:        (not configured — set ALERT_EMAIL to enable)"
echo "============================================================"
echo ""

# ── Step 1: Create namespaces ─────────────────────────────────────────────────
echo "==> Step 1 — Creating monitoring and tracing namespaces..."
kubectl apply -f "$OBS_DIR/namespace.yaml"

# ── Step 2: Add Helm repositories ─────────────────────────────────────────────
echo ""
echo "==> Step 2 — Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add fluent https://fluent.github.io/helm-charts 2>/dev/null || true
helm repo update

# ── Step 3: Create Grafana dashboard ConfigMap ────────────────────────────────
echo ""
echo "==> Step 3 — Creating Grafana dashboard ConfigMap..."
kubectl create configmap petclinic-dashboards \
  --namespace monitoring \
  --from-file="service-overview.json=$OBS_DIR/grafana-dashboards/service-overview.json" \
  --from-file="per-service.json=$OBS_DIR/grafana-dashboards/per-service.json" \
  --from-file="jvm-metrics.json=$OBS_DIR/grafana-dashboards/jvm-metrics.json" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label configmap petclinic-dashboards -n monitoring \
  grafana_dashboard=1 \
  grafana_folder=Petclinic \
  "app.kubernetes.io/managed-by=kubectl" \
  "app.kubernetes.io/part-of=petclinic" \
  --overwrite

# ── Step 4: Install kube-prometheus-stack ────────────────────────────────────
echo ""
echo "==> Step 4 — Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
echo "    This takes 2-3 minutes..."

GRAFANA_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || openssl rand -hex 8)"

TMPFILE_PROM="$(mktemp /tmp/kube-prom-stack-values-XXXXX.yaml)"
trap 'rm -f "$TMPFILE_PROM"' EXIT

sed \
  -e "s|PETCLINIC_NAMESPACE|$PETCLINIC_NAMESPACE|g" \
  -e "s|PROMETHEUS_STORAGE_SIZE|$PROMETHEUS_STORAGE_SIZE|g" \
  -e "s|PROMETHEUS_RETENTION|$PROMETHEUS_RETENTION|g" \
  -e "s|ALERT_EMAIL|$ALERT_EMAIL|g" \
  -e "s|SMTP_HOST|$SMTP_HOST|g" \
  -e "s|SMTP_FROM|$SMTP_FROM|g" \
  -e "s|SMTP_USERNAME|$SMTP_USERNAME|g" \
  -e "s|SMTP_PASSWORD|$SMTP_PASSWORD|g" \
  "$OBS_DIR/prometheus/kube-prometheus-stack-values.yaml" \
  > "$TMPFILE_PROM"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword="$GRAFANA_PASSWORD" \
  --version ">=60.0.0" \
  -f "$TMPFILE_PROM" \
  --wait \
  --timeout 10m

echo "  kube-prometheus-stack installed."

# ── Step 5: Install Loki ──────────────────────────────────────────────────────
echo ""
echo "==> Step 5 — Installing Loki (log aggregation)..."

TMPFILE_LOKI="$(mktemp /tmp/loki-values-XXXXX.yaml)"
trap 'rm -f "$TMPFILE_LOKI"' EXIT

sed \
  -e "s|LOKI_STORAGE_SIZE|$LOKI_STORAGE_SIZE|g" \
  -e "s|LOKI_RETENTION|$LOKI_RETENTION|g" \
  "$OBS_DIR/loki/loki-values.yaml" \
  > "$TMPFILE_LOKI"

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --version ">=6.0.0" \
  -f "$TMPFILE_LOKI" \
  --wait \
  --timeout 5m

echo "  Loki installed."

# ── Step 6: Install FluentBit ─────────────────────────────────────────────────
echo ""
echo "==> Step 6 — Installing FluentBit (log collection DaemonSet)..."
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace monitoring \
  -f "$OBS_DIR/fluentbit/fluentbit-values.yaml" \
  --wait \
  --timeout 3m

echo "  FluentBit DaemonSet installed."

# ── Step 7: Deploy Zipkin ─────────────────────────────────────────────────────
echo ""
echo "==> Step 7 — Deploying Zipkin (distributed tracing)..."
kubectl apply -f "$OBS_DIR/zipkin/zipkin.yaml"
kubectl rollout status deployment/zipkin -n tracing --timeout=120s

echo "  Zipkin deployed."

# ── Step 8: Verify ────────────────────────────────────────────────────────────
echo ""
echo "==> Step 8 — Verifying observability stack..."
echo ""
echo "  Pods in monitoring namespace:"
kubectl get pods -n monitoring --no-headers | awk '{printf "    %-50s %s/%s\n", $1, $2, $3}'
echo ""
echo "  Pods in tracing namespace:"
kubectl get pods -n tracing --no-headers | awk '{printf "    %-50s %s/%s\n", $1, $2, $3}'

echo ""
echo "==========================================================="
echo "  Observability stack installed for petclinic-$ENV"
echo ""
echo "  Grafana admin password: $GRAFANA_PASSWORD"
echo "  (change this via: kubectl -n monitoring get secret kube-prometheus-stack-grafana -o yaml)"
echo ""
echo "  Access Grafana UI:"
echo "    kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
echo "    then open: http://localhost:3000  (admin / $GRAFANA_PASSWORD)"
echo ""
echo "  Access Prometheus UI:"
echo "    kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090"
echo "    then open: http://localhost:9090"
echo ""
echo "  Access Alertmanager UI:"
echo "    kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093"
echo "    then open: http://localhost:9093"
echo ""
echo "  Access Zipkin UI:"
echo "    kubectl port-forward svc/zipkin -n tracing 9411:9411"
echo "    then open: http://localhost:9411"
echo ""
if [[ -z "$ALERT_EMAIL" ]]; then
  echo "  NOTE: ALERT_EMAIL was not set — Alertmanager has no notification channel."
  echo "  To enable email alerts, re-run with: ALERT_EMAIL=you@example.com bash $0 --env $ENV"
  echo ""
fi
echo "  Check scrape targets (should show all 8 petclinic services):"
echo "    http://localhost:9090/targets  (after port-forwarding Prometheus)"
echo "==========================================================="
