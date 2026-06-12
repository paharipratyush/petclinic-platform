#!/usr/bin/env bash
# Smoke test: validates all 8 petclinic services are running and healthy.
#
# Uses one shared curl pod per namespace (kubectl exec) instead of spinning up
# a new pod per check. This is faster (~3 pod startups total vs 15+) and
# avoids kubectl run exit-code propagation issues on non-interactive shells.
#
# Usage:
#   bash scripts/smoke-test.sh --env dev
#   bash scripts/smoke-test.sh --env prod
#
# Exit 0 = all checks passed; exit 1 = one or more checks failed.

set -euo pipefail

ENV="dev"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    dev|prod) ENV="$1"; shift ;;
    *) echo "Usage: $0 [--env] <dev|prod>"; exit 1 ;;
  esac
done
NS="petclinic-${ENV}"
PASS=0
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); }
info() { echo -e "  ${YELLOW}→${NC} $*"; }

# ── Shared runner pods ────────────────────────────────────────────────────────
# One long-lived curl pod per namespace. All HTTP checks use kubectl exec into
# these pods rather than spinning up a new pod for each check.
APP_POD="smoke-app-runner"
OBS_POD="smoke-obs-runner"
TRACING_POD="smoke-tracing-runner"

cleanup() {
  kubectl delete pod "$APP_POD"     -n "$NS"      --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete pod "$OBS_POD"     -n monitoring --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete pod "$TRACING_POD" -n tracing    --ignore-not-found --wait=false 2>/dev/null || true
}
trap cleanup EXIT

start_runner() {
  local pod="$1" ns="$2"
  kubectl delete pod "$pod" -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
  kubectl run "$pod" -n "$ns" --image=curlimages/curl:8.6.0 \
    --restart=Never -- sleep 300 > /dev/null 2>&1
  kubectl wait pod/"$pod" -n "$ns" --for=condition=Ready --timeout=60s > /dev/null 2>&1
}

echo ""
echo "============================================================"
echo "  Petclinic Smoke Test"
echo "  Environment: ${ENV}"
echo "  Namespace:   ${NS}"
echo "============================================================"
echo ""
TRACING_AVAILABLE=false
info "Starting shared curl runners (one per namespace)..."
start_runner "$APP_POD"  "$NS"
start_runner "$OBS_POD"  monitoring
# Tracing namespace is optional — only present when install-observability.sh has run.
if kubectl get namespace tracing &>/dev/null 2>&1; then
  start_runner "$TRACING_POD" tracing
  TRACING_AVAILABLE=true
else
  info "Namespace 'tracing' not found — Zipkin check will be skipped."
fi
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────

check_pod_running() {
  local svc="$1"
  local pod
  pod=$(kubectl get pods -n "$NS" -l "app.kubernetes.io/name=${svc}" \
        --no-headers -o custom-columns="NAME:.metadata.name,READY:.status.containerStatuses[0].ready" 2>/dev/null | head -1)
  if echo "$pod" | grep -q "true"; then
    ok "Pod running: ${svc}"
  else
    fail "Pod not running or not ready: ${svc} (got: '${pod}')"
  fi
}

# HTTP check from within the app namespace
check_http() {
  local label="$1" url="$2"
  if kubectl exec -n "$NS" "$APP_POD" -- \
      curl -sf --max-time 10 "$url" > /dev/null 2>&1; then
    ok "HTTP OK: ${label} (${url})"
  else
    fail "HTTP FAIL: ${label} (${url})"
  fi
}

# HTTP check from within the monitoring namespace
check_http_obs() {
  local label="$1" url="$2"
  if kubectl exec -n monitoring "$OBS_POD" -- \
      curl -sf --max-time 10 "$url" > /dev/null 2>&1; then
    ok "Observability: ${label}"
  else
    fail "Observability: ${label} — unreachable (${url})"
  fi
}

# ── 1. All 8 pods Running ─────────────────────────────────────────────────────
echo "[ 1/6 ] Pod health"
for svc in config-server discovery-server api-gateway \
           customers-service visits-service vets-service \
           genai-service admin-server; do
  check_pod_running "$svc"
done

# ── 2. Config Server actuator ─────────────────────────────────────────────────
echo ""
echo "[ 2/6 ] Config Server actuator"
check_http "config-server/health" "http://config-server.${NS}:8888/actuator/health"

# ── 3. Eureka registration ────────────────────────────────────────────────────
echo ""
echo "[ 3/6 ] Eureka registration"
eureka_apps=$(kubectl exec -n "$NS" "$APP_POD" -- \
  curl -sf --max-time 10 "http://discovery-server.${NS}:8761/eureka/apps" 2>/dev/null || true)
for svc in API-GATEWAY CUSTOMERS-SERVICE VISITS-SERVICE VETS-SERVICE \
           GENAI-SERVICE ADMIN-SERVER; do
  if echo "$eureka_apps" | grep -qi "<name>${svc}</name>"; then
    ok "Eureka: ${svc} registered"
  else
    fail "Eureka: ${svc} not found in registry"
  fi
done

# ── 4. API Gateway routing ────────────────────────────────────────────────────
echo ""
echo "[ 4/6 ] API Gateway routing"
check_http "api-gateway /actuator/health" \
  "http://api-gateway.${NS}:8080/actuator/health"
check_http "api-gateway /api/customer/owners" \
  "http://api-gateway.${NS}:8080/api/customer/owners"
check_http "api-gateway /api/vet/vets" \
  "http://api-gateway.${NS}:8080/api/vet/vets"

# ── 5. RDS connectivity — health + write/read test ────────────────────────────
echo ""
echo "[ 5/6 ] RDS connectivity"
declare -A SVC_PORT=([customers-service]=8081 [visits-service]=8082 [vets-service]=8083)
for svc in customers-service visits-service vets-service; do
  port="${SVC_PORT[$svc]}"
  if kubectl exec -n "$NS" "$APP_POD" -- \
      curl -sf --max-time 10 "http://${svc}.${NS}:${port}/actuator/health" \
      > /dev/null 2>&1; then
    ok "DB-backed service healthy: ${svc}"
  else
    fail "DB-backed service unhealthy: ${svc}"
  fi
done

# PETPLAT-86 AC: verify DB writes work — create an owner record and read it back
echo "  DB write verification (create owner → read back)..."
CREATE_RESPONSE=$(kubectl exec -n "$NS" "$APP_POD" -- \
  curl -sf --max-time 15 -X POST \
    -H "Content-Type: application/json" \
    -d '{"firstName":"SmokeTest","lastName":"User","address":"1 Test St","city":"TestCity","telephone":"0123456789"}' \
    "http://customers-service.${NS}:8081/owners" \
  2>/dev/null || echo "")
if echo "$CREATE_RESPONSE" | grep -q '"id"'; then
  ok "RDS write: create owner succeeded"
  OWNER_ID=$(echo "$CREATE_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
  if kubectl exec -n "$NS" "$APP_POD" -- \
      curl -sf --max-time 10 "http://customers-service.${NS}:8081/owners/${OWNER_ID}" \
      > /dev/null 2>&1; then
    ok "RDS read: owner read back succeeded (id=${OWNER_ID})"
  else
    fail "RDS read: could not read back owner id=${OWNER_ID}"
  fi
else
  fail "RDS write: create owner failed (response: ${CREATE_RESPONSE:0:100})"
fi

# ── 6. Observability stack ────────────────────────────────────────────────────
echo ""
echo "[ 6/6 ] Observability stack"
check_http_obs "prometheus"   "http://prometheus:9090/-/ready"
check_http_obs "alertmanager" "http://alertmanager:9093/-/ready"
check_http_obs "loki"         "http://loki:3100/ready"
check_http_obs "grafana"      "http://grafana:3000/api/health"

if $TRACING_AVAILABLE; then
  if kubectl exec -n tracing "$TRACING_POD" -- \
      curl -sf --max-time 10 http://zipkin:9411/health > /dev/null 2>&1; then
    ok "Observability: zipkin"
  else
    fail "Observability: zipkin"
  fi
else
  info "Zipkin skipped (tracing namespace not installed)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
