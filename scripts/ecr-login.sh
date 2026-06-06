#!/usr/bin/env bash
# Authenticate Docker to the ECR private registry.
# Run this before any docker pull/push targeting ECR.
#
# Usage:
#   ./scripts/ecr-login.sh
#   ./scripts/ecr-login.sh --region eu-west-1
set -euo pipefail

REGION="eu-central-1"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)
      REGION="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--region REGION]" >&2
      exit 1
      ;;
  esac
done

docker info > /dev/null 2>&1 || { echo "ERROR: Docker daemon is not running. Start Docker and retry." >&2; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Authenticating Docker to ECR registry: ${REGISTRY}"
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${REGISTRY}"
echo "Login successful"
