#!/usr/bin/env bash
# Build ARM64 Docker images for all 8 Spring Petclinic services and push to ECR.
#
# Strategy:
#   1. Maven builds the JARs (./mvnw clean install -DskipTests)
#   2. docker buildx builds linux/arm64 images per service (required for t4g Graviton nodes)
#   3. Images are pushed directly to ECR via --push (no local image stored)
#
# Usage:
#   ./scripts/build-push.sh \
#     --app-repo /path/to/spring-petclinic-microservices \
#     --env dev \
#     --tag v1.0.0
#
#   --app-repo   Path to the cloned spring-petclinic-microservices repository (required)
#   --env        Target environment: dev or prod (default: dev)
#   --tag        Image tag to use, e.g. v1.0.0 or a commit SHA (default: v1.0.0)
#   --region     AWS region for ECR (default: eu-central-1)
#   --registry   Override ECR registry URL (default: auto-detected from AWS account)
set -euo pipefail

# Clean up a created petclinic-builder on exit. No-op when using desktop-linux
# (Docker Desktop manages that builder's lifecycle).
cleanup() { [[ "${BUILDX_BUILDER:-}" == "petclinic-builder" ]] && docker buildx rm petclinic-builder 2>/dev/null || true; }
trap cleanup EXIT

APP_REPO=""
ENV="dev"
TAG="v1.0.0"
REGION="eu-central-1"
REGISTRY=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --app-repo)  APP_REPO="$2";  shift 2 ;;
    --env)       ENV="$2";       shift 2 ;;
    --tag)       TAG="$2";       shift 2 ;;
    --region)    REGION="$2";    shift 2 ;;
    --registry)  REGISTRY="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${APP_REPO}" ]]    && { echo "ERROR: --app-repo is required" >&2; exit 1; }
[[ ! -d "${APP_REPO}" ]]  && { echo "ERROR: app repo not found at ${APP_REPO}" >&2; exit 1; }
[[ "${ENV}" =~ ^(dev|prod)$ ]] || { echo "ERROR: --env must be 'dev' or 'prod'" >&2; exit 1; }

if [[ -z "${REGISTRY}" ]]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi

# Service definitions: "ecr-name:maven-module:port"
SERVICES=(
  "config-server:spring-petclinic-config-server:8888"
  "discovery-server:spring-petclinic-discovery-server:8761"
  "api-gateway:spring-petclinic-api-gateway:8080"
  "customers-service:spring-petclinic-customers-service:8081"
  "visits-service:spring-petclinic-visits-service:8082"
  "vets-service:spring-petclinic-vets-service:8083"
  "genai-service:spring-petclinic-genai-service:8084"
  "admin-server:spring-petclinic-admin-server:9090"
)

DOCKERFILE="${APP_REPO}/docker/Dockerfile"
[[ ! -f "${DOCKERFILE}" ]] && { echo "ERROR: Dockerfile not found at ${DOCKERFILE}" >&2; exit 1; }

# ── Step 1: Build JARs ────────────────────────────────────────────────────────
# Tests are skipped here because this is a manual push helper, not CI.
# The CI pipeline (E-10 / .github/workflows/build-push.yml) runs the full
# test suite before building images — do not bypass that gate in CI.
echo "=== [1/4] Building JARs with Maven (skipping tests) ==="
cd "${APP_REPO}"
./mvnw clean install -DskipTests -q
echo "Maven build complete"

# ── Step 2: Set up Docker Buildx for ARM64 ───────────────────────────────────
# On Linux/CI: create a dedicated docker-container builder (supports --push natively).
# On Docker Desktop for Windows: use the pre-existing desktop-linux builder which
# supports linux/arm64 via QEMU (docker-container driver fails from Git Bash due to
# WSL2 bind-mount path translation issues).
echo ""
echo "=== [2/4] Setting up Docker Buildx ==="
if docker buildx inspect desktop-linux &>/dev/null; then
  # Docker Desktop for Windows — use the managed builder
  BUILDX_BUILDER="desktop-linux"
  docker buildx use desktop-linux
elif docker buildx inspect petclinic-builder &>/dev/null; then
  BUILDX_BUILDER="petclinic-builder"
  docker buildx use petclinic-builder
else
  docker buildx create --name petclinic-builder --use
  BUILDX_BUILDER="petclinic-builder"
fi
echo "Buildx builder: ${BUILDX_BUILDER} (linux/arm64)"

# ── Step 3: ECR Login ─────────────────────────────────────────────────────────
echo ""
echo "=== [3/4] Authenticating to ECR: ${REGISTRY} ==="
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${REGISTRY}"
echo "Login successful"

# ── Step 4: Build and push each service ──────────────────────────────────────
echo ""
echo "=== [4/4] Building and pushing ARM64 images (tag: ${TAG}) ==="

for ENTRY in "${SERVICES[@]}"; do
  IFS=':' read -r SERVICE MODULE PORT <<< "${ENTRY}"

  ECR_IMAGE="${REGISTRY}/petclinic-${ENV}/${SERVICE}:${TAG}"

  # Locate the JAR (excludes *-sources.jar and *-javadoc.jar)
  JAR_FILE=$(find "${APP_REPO}/${MODULE}/target" \
    -maxdepth 1 -name "${MODULE}-*.jar" \
    ! -name "*-sources.jar" ! -name "*-javadoc.jar" \
    | head -1)

  if [[ -z "${JAR_FILE}" ]]; then
    echo "ERROR: JAR not found in ${APP_REPO}/${MODULE}/target/" >&2
    exit 1
  fi

  ARTIFACT_NAME=$(basename "${JAR_FILE}" .jar)

  echo ""
  echo "  Building ${SERVICE}"
  echo "    Artifact : ${ARTIFACT_NAME}"
  echo "    Port     : ${PORT}"
  echo "    Image    : ${ECR_IMAGE}"

  # Build context is target/ — Dockerfile does COPY ${ARTIFACT_NAME}.jar from context root
  docker buildx build \
    --platform linux/arm64 \
    --build-arg ARTIFACT_NAME="${ARTIFACT_NAME}" \
    --build-arg EXPOSED_PORT="${PORT}" \
    --tag "${ECR_IMAGE}" \
    --file "${DOCKERFILE}" \
    --push \
    "${APP_REPO}/${MODULE}/target"

  echo "    Pushed ✓"
done

echo ""
echo "All 8 images pushed to ECR."
echo "Registry : ${REGISTRY}"
echo "Tag      : ${TAG}"
echo ""
echo "Next: update helm-values/{service}.yaml image.tag to ${TAG}"
echo "      ArgoCD will pick up the change and deploy automatically (dev)"
