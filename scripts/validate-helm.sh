#!/usr/bin/env bash
# Lint, template, and dry-run all Helm releases (8 services × 2 envs = 16 total).
# Usage: ./scripts/validate-helm.sh [--env dev|prod] [--service <name>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART_DIR="$REPO_ROOT/helm/petclinic-service"
VALUES_DIR="$REPO_ROOT/helm-values"

ALL_SERVICES=(
  config-server
  discovery-server
  customers-service
  visits-service
  vets-service
  genai-service
  api-gateway
  admin-server
)
ALL_ENVS=(dev prod)

SERVICES=("${ALL_SERVICES[@]}")
ENVS=("${ALL_ENVS[@]}")
ERRORS=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)     ENVS=("$2");    shift 2 ;;
    --service) SERVICES=("$2"); shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Verify tooling
for cmd in helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done

echo "=== Chart lint (config-server/dev as baseline) ==="
helm lint "$CHART_DIR" \
  -f "$VALUES_DIR/config-server.yaml" \
  -f "$VALUES_DIR/dev.yaml" \
  --set "image.tag=test"
echo ""

for svc in "${SERVICES[@]}"; do
  SVC_VALUES="$VALUES_DIR/$svc.yaml"
  if [[ ! -f "$SVC_VALUES" ]]; then
    echo "ERROR: missing $SVC_VALUES"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  for env in "${ENVS[@]}"; do
    ENV_VALUES="$VALUES_DIR/$env.yaml"
    NS="petclinic-$env"
    echo "--- $svc / $env ---"

    # Build value file list; include the per-env service overlay (e.g. customers-service-prod.yaml)
    # if it exists. This file carries prod-specific overrides like RDS endpoint.
    EXTRA_VALUES=()
    if [[ "$env" == "prod" && -f "$VALUES_DIR/${svc}-prod.yaml" ]]; then
      EXTRA_VALUES=("-f" "$VALUES_DIR/${svc}-prod.yaml")
    fi

    # 1. Lint
    if ! helm lint "$CHART_DIR" \
      -f "$SVC_VALUES" \
      -f "$ENV_VALUES" \
      "${EXTRA_VALUES[@]}" \
      --set "image.tag=test" \
      --quiet; then
      echo "FAIL: helm lint $svc/$env"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # 2. Template + dry-run (--validate=false avoids OpenAPI download; struct is verified by lint)
    # Suppress kubectl stderr (deprecation warnings) so they don't clutter output.
    # Use || to capture the exit code safely under set -e.
    _dry_rc=0
    helm template "$svc" "$CHART_DIR" \
      --namespace "$NS" \
      -f "$SVC_VALUES" \
      -f "$ENV_VALUES" \
      "${EXTRA_VALUES[@]}" \
      --set "image.tag=test" \
      | kubectl apply --dry-run=client --validate=false --namespace "$NS" -f - 2>/dev/null \
      || _dry_rc=$?
    if [[ $_dry_rc -ne 0 ]]; then
      echo "FAIL: kubectl dry-run $svc/$env"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    echo "OK"
  done
done

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "FAILED: $ERRORS error(s)"
  exit 1
fi
echo "All ${#SERVICES[@]} services × ${#ENVS[@]} envs validated."
