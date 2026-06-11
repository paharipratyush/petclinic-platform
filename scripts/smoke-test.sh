#!/usr/bin/env bash
# Smoke test: validates all 8 petclinic services are running and healthy.
# Usage: ./scripts/smoke-test.sh [dev|prod]
#        ./scripts/smoke-test.sh --env dev
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

_HTTP_COUNTER=0
check_http() {
  local label="$1"
  local url="$2"
  _HTTP_COUNTER=$((_HTTP_COUNTER + 1))
  local pod_name="smoke-http-${_HTTP_COUNTER}"
  if kubectl run -n "$NS" "$pod_name" --rm --image=curlimages/curl:8.6.0 \
      --restart=Never --quiet -- \
      curl -sf --max-time 10 "$url" > /dev/null 2>&1; then
    ok "HTTP OK: ${label} (${url})"
  else
    fail "HTTP FAIL: ${label} (${url})"
  fi
}

echo ""
echo "============================================================"
echo "  Petclinic Smoke Test"
echo "  Environment: ${ENV}"
echo "  Namespace:   ${NS}"
echo "============================================================"
echo ""

# ── 1. All 8 pods Running ─────────────────────────────────────
echo "[ 1/6 ] Pod health"
for svc in config-server discovery-server api-gateway \
           customers-service visits-service vets-service \
           genai-service admin-server; do
  check_pod_running "$svc"
done

# ── 2. Config Server health ───────────────────────────────────
echo ""
echo "[ 2/6 ] Config Server actuator"
check_http "config-server/health" "http://config-server.${NS}:8888/actuator/health"

# ── 3. Eureka registration ────────────────────────────────────
echo ""
echo "[ 3/6 ] Eureka registration"
eureka_apps=$(kubectl run -n "$NS" smoke-eureka --rm -it \
  --image=curlimages/curl:8.6.0 --restart=Never --quiet -- \
  curl -sf "http://discovery-server.${NS}:8761/eureka/apps" 2>/dev/null || true)
for svc in API-GATEWAY CUSTOMERS-SERVICE VISITS-SERVICE VETS-SERVICE \
           GENAI-SERVICE ADMIN-SERVER; do
  if echo "$eureka_apps" | grep -qi "<name>${svc}</name>"; then
    ok "Eureka: ${svc} registered"
  else
    fail "Eureka: ${svc} not found in registry"
  fi
done

# ── 4. API Gateway routing ────────────────────────────────────
echo ""
echo "[ 4/6 ] API Gateway routing"
check_http "api-gateway /actuator/health" \
  "http://api-gateway.${NS}:8080/actuator/health"
check_http "api-gateway /api/customer/owners" \
  "http://api-gateway.${NS}:8080/api/customer/owners"
check_http "api-gateway /api/vet/vets" \
  "http://api-gateway.${NS}:8080/api/vet/vets"

# ── 5. RDS connectivity — health + create/read write test ────────────────
echo ""
echo "[ 5/6 ] RDS connectivity"
declare -A SVC_PORT=([customers-service]=8081 [visits-service]=8082 [vets-service]=8083)
for svc in customers-service visits-service vets-service; do
  port="${SVC_PORT[$svc]}"
  if kubectl run -n "$NS" smoke-db-"$svc" --rm -it \
      --image=curlimages/curl:8.6.0 --restart=Never --quiet -- \
      curl -sf --max-time 10 "http://${svc}.${NS}:${port}/actuator/health" \
      > /dev/null 2>&1; then
    ok "DB-backed service healthy: ${svc}"
  else
    fail "DB-backed service unhealthy: ${svc}"
  fi
done

# PETPLAT-86 AC: verify DB writes work — create an owner record and read it back
echo "  DB write verification (create owner → read back)..."
CREATE_RESPONSE=$(kubectl run -n "$NS" smoke-db-write --rm -it \
  --image=curlimages/curl:8.6.0 --restart=Never --quiet -- \
  curl -sf --max-time 15 -X POST \
    -H "Content-Type: application/json" \
    -d '{"firstName":"SmokeTest","lastName":"User","address":"1 Test St","city":"TestCity","telephone":"0123456789"}' \
    "http://customers-service.${NS}:8081/owners" \
  2>/dev/null || echo "")
if echo "$CREATE_RESPONSE" | grep -q '"id"'; then
  ok "RDS write: create owner succeeded"
  # Read it back
  OWNER_ID=$(echo "$CREATE_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
  if kubectl run -n "$NS" smoke-db-read --rm -it \
      --image=curlimages/curl:8.6.0 --restart=Never --quiet -- \
      curl -sf --max-time 10 "http://customers-service.${NS}:8081/owners/${OWNER_ID}" \
      > /dev/null 2>&1; then
    ok "RDS read: owner read back succeeded (id=${OWNER_ID})"
  else
    fail "RDS read: could not read back owner id=${OWNER_ID}"
  fi
else
  fail "RDS write: create owner failed (response: ${CREATE_RESPONSE:0:100})"
fi

# ── 6. Observability stack ────────────────────────────────────
echo ""
echo "[ 6/6 ] Observability stack"
while read -r result; do
    svc="${result%%:*}"
    status="${result##*:}"
    if [[ "$status" == "ready" ]]; then
      ok "Observability: ${svc}"
    else
      fail "Observability: ${svc}"
    fi
done < <(kubectl run -n monitoring smoke-obs --rm --image=curlimages/curl:8.6.0 \
  --restart=Never --quiet -- sh -c '
    curl -sf http://prometheus:9090/-/ready > /dev/null && echo "prometheus:ready" || echo "prometheus:fail"
    curl -sf http://alertmanager:9093/-/ready > /dev/null && echo "alertmanager:ready" || echo "alertmanager:fail"
    curl -sf http://loki:3100/ready > /dev/null && echo "loki:ready" || echo "loki:fail"
    curl -sf http://grafana:3000/api/health > /dev/null && echo "grafana:ready" || echo "grafana:fail"
' 2>/dev/null)

kubectl run -n tracing smoke-zipkin --rm -it \
  --image=curlimages/curl:8.6.0 --restart=Never --quiet -- \
  curl -sf http://zipkin:9411/health > /dev/null 2>&1 && ok "Observability: zipkin" || fail "Observability: zipkin"

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
