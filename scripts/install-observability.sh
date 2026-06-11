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
#   - External Secrets Operator (ESO) installed and ClusterSecretStore ready
#
# SMTP credentials (required for email alerts):
#   ESO pulls credentials automatically from AWS Secrets Manager.
#   Create the secret BEFORE running this script:
#     aws secretsmanager create-secret \
#       --name petclinic/alertmanager-smtp \
#       --secret-string '{"email":"you@gmail.com","password":"xxxx xxxx xxxx xxxx"}'
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

echo "============================================================"
echo "  Installing Observability Stack (raw K8s manifests)"
echo "  Environment:  $ENV"
echo "  Namespaces:   monitoring, tracing"
echo "  SMTP:         provisioned by ESO from petclinic/alertmanager-smtp"
echo "============================================================"
echo ""

# ── Step 1: Create namespaces ─────────────────────────────────────────────────
echo "==> Step 1 — Creating monitoring and tracing namespaces..."
kubectl apply -f "$OBS_DIR/namespace.yaml"

# ── Step 1b: Apply monitoring/tracing network policies ────────────────────────
echo "==> Step 1b — Applying network policies for monitoring and tracing namespaces..."
kubectl apply -f "$OBS_DIR/network-policies.yaml"
echo "  Network policies applied."

# ── Step 2: Install PrometheusRule CRD ────────────────────────────────────────
echo ""
echo "==> Step 2 — Installing PrometheusRule CRD..."
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
echo "  CRD installed."

# ── Step 3: Deploy Prometheus ─────────────────────────────────────────────────
echo ""
echo "==> Step 3 — Deploying Prometheus..."
kubectl apply -f "$OBS_DIR/prometheus.yaml"

# When running for prod, patch the prometheus ConfigMap to also scrape prod services.
# The base prometheus.yaml only includes dev targets to avoid ServiceDown alerts when prod
# has not been provisioned. Running --env prod adds prod scrape jobs to the same ConfigMap.
if [[ "$ENV" == "prod" ]]; then
  echo "  Adding prod scrape targets to Prometheus config..."
  PROD_SCRAPE_YAML=$(cat <<'YAML'
- job_name: config-server-prod
  metrics_path: /actuator/prometheus
  scrape_interval: 15s
  static_configs:
    - targets:
        - config-server.petclinic-prod:8888
- job_name: discovery-server-prod
  metrics_path: /actuator/prometheus
  scrape_interval: 15s
  static_configs:
    - targets:
        - discovery-server.petclinic-prod:8761
- job_name: api-gateway-prod
  metrics_path: /actuator/prometheus
  scrape_interval: 15s
  static_configs:
    - targets:
        - api-gateway.petclinic-prod:8080
- job_name: customers-service-prod
  metrics_path: /actuator/prometheus
  scrape_interval: 15s
  static_configs:
    - targets:
        - customers-service.petclinic-prod:8081
- job_name: visits-service-prod
  metrics_path: /actuator/prometheus
  scrape_interval: 15s
  static_configs:
    - targets:
        - visits-service.petclinic-prod:8082
- job_name: vets-service-prod
  metrics_path: /actuator/prometheus
  scrape_interval: 15s
  static_configs:
    - targets:
        - vets-service.petclinic-prod:8083
- job_name: genai-service-prod
  metrics_path: /actuator/prometheus
  scrape_interval: 15s
  static_configs:
    - targets:
        - genai-service.petclinic-prod:8084
- job_name: admin-server-prod
  metrics_path: /actuator/prometheus
  scrape_interval: 15s
  static_configs:
    - targets:
        - admin-server.petclinic-prod:9090
YAML
)
  # Read current config, append prod jobs, patch ConfigMap
  CURRENT=$(kubectl get configmap prometheus-config -n monitoring \
    -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null)
  if ! echo "$CURRENT" | grep -q "api-gateway-prod"; then
    UPDATED=$(printf '%s\n%s' "$CURRENT" "$PROD_SCRAPE_YAML")
    kubectl patch configmap prometheus-config -n monitoring \
      --type=merge \
      -p "{\"data\":{\"prometheus.yml\":$(echo "$UPDATED" | jq -Rs .)}}"
    echo "  Prod scrape targets added. Prometheus will pick up the new config on next reload."
  else
    echo "  Prod scrape targets already present in prometheus config."
  fi
fi

kubectl rollout status deployment/prometheus -n monitoring --timeout=300s \
  || echo "  WARNING: Prometheus rollout timed out — Karpenter may be provisioning a node. Check: kubectl get pods -n monitoring"
echo "  Prometheus deployed."

# ── Step 4: Deploy Alertmanager ───────────────────────────────────────────────
echo ""
echo "==> Step 4 — Deploying Alertmanager..."
# Apply the ExternalSecret — ESO creates alertmanager-config Secret from Secrets Manager.
# Prereq: petclinic/alertmanager-smtp must exist in Secrets Manager before this step.
kubectl apply -f "$REPO_ROOT/k8s/base/external-secrets/alertmanager-config.yaml"
echo "  Waiting for ESO to create alertmanager-config secret..."
kubectl wait externalsecret/alertmanager-config -n monitoring \
  --for=condition=Ready --timeout=120s || {
  echo "  WARNING: alertmanager-config ExternalSecret not Ready within 120s."
  echo "  Ensure petclinic/alertmanager-smtp exists in Secrets Manager."
}
kubectl apply -f "$OBS_DIR/alertmanager.yaml"
kubectl rollout status deployment/alertmanager -n monitoring --timeout=120s \
  || echo "  WARNING: Alertmanager rollout timed out — SMTP secret may be missing or pod is slow to start. Continuing."
echo "  Alertmanager deployed (check pod status with: kubectl get pods -n monitoring)"

# ── Step 5: Deploy Loki ───────────────────────────────────────────────────────
echo ""
echo "==> Step 5 — Deploying Loki..."
kubectl apply -f "$OBS_DIR/loki.yaml"
kubectl rollout status deployment/loki -n monitoring --timeout=300s \
  || echo "  WARNING: Loki rollout timed out — Karpenter may be provisioning a node. Check: kubectl get pods -n monitoring"
echo "  Loki deployed."

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
# Apply the ExternalSecret — ESO creates grafana-admin Secret from Secrets Manager.
# Prereq: petclinic/{env}/grafana-admin must exist in Secrets Manager (created by terraform/modules/secrets).
if [[ "$ENV" == "prod" ]]; then
  kubectl apply -f "$REPO_ROOT/k8s/base/external-secrets/grafana-admin-prod.yaml"
else
  kubectl apply -f "$REPO_ROOT/k8s/base/external-secrets/grafana-admin.yaml"
fi
echo "  Waiting for ESO to create grafana-admin secret..."
kubectl wait externalsecret/grafana-admin -n monitoring \
  --for=condition=Ready --timeout=60s || {
  echo "  WARNING: grafana-admin ExternalSecret not Ready within 60s. Grafana may fail to start."
  echo "  Check: kubectl describe externalsecret grafana-admin -n monitoring"
}
kubectl apply -f "$OBS_DIR/grafana.yaml"
kubectl rollout status deployment/grafana -n monitoring --timeout=300s \
  || echo "  WARNING: Grafana rollout timed out — Karpenter may be provisioning a node. Check: kubectl get pods -n monitoring"
echo "  Grafana deployed."

# ── Step 8: Apply PrometheusRule alert rules ──────────────────────────────────
echo ""
echo "==> Step 8 — Applying PrometheusRule alert rules..."
kubectl apply -f "$OBS_DIR/alerting-rules.yaml"
echo "  Alert rules applied."

# ── Step 9: Deploy Zipkin ─────────────────────────────────────────────────────
echo ""
echo "==> Step 9 — Deploying Zipkin..."
kubectl apply -f "$OBS_DIR/zipkin/zipkin.yaml"
if ! kubectl rollout status -n tracing deploy/zipkin --timeout=300s; then
  echo "  WARNING: Zipkin rollout timed out — Karpenter may be provisioning a node. Check: kubectl get pods -n tracing"
fi
echo "  Zipkin deployed."

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
echo "  NOTE: Email alerts require petclinic/alertmanager-smtp in Secrets Manager."
echo "  If ESO ExternalSecret shows NotReady, create it with:"
echo "    aws secretsmanager create-secret \\"
echo "      --name petclinic/alertmanager-smtp \\"
echo "      --secret-string '{\"email\":\"you@gmail.com\",\"password\":\"xxxx xxxx xxxx xxxx\"}'"
echo "  ESO refreshes every 1h — or force it with:"
echo "    kubectl annotate externalsecret alertmanager-config -n monitoring force-sync=\$(date +%s) --overwrite"
echo ""
echo "==========================================================="
