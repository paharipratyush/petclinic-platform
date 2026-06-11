#!/usr/bin/env bash
# Bootstrap Terraform remote state: S3 bucket + DynamoDB locking table
# Run once before terraform init. Safe to run multiple times (idempotent).
#
# Usage:
#   ./scripts/bootstrap-state.sh
#   ./scripts/bootstrap-state.sh --region eu-west-1
set -euo pipefail

export AWS_PAGER=""

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

echo "Fetching AWS account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="petclinic-terraform-state-${ACCOUNT_ID}"
TABLE_NAME="petclinic-terraform-locks"

echo "Account ID:      ${ACCOUNT_ID}"
echo "S3 Bucket:       ${BUCKET_NAME}"
echo "DynamoDB Table:  ${TABLE_NAME}"
echo "Region:          ${REGION}"
echo ""

# ── S3 Bucket ────────────────────────────────────────────────────────────────

if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "[S3] Bucket already exists: ${BUCKET_NAME}"
else
  echo "[S3] Creating bucket: ${BUCKET_NAME}"
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
  echo "[S3] Bucket created"
fi

echo "[S3] Enabling versioning..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "[S3] Enabling server-side encryption (AES256)..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }]
  }'

echo "[S3] Blocking all public access..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "[S3] Done"

# ── DynamoDB Table ────────────────────────────────────────────────────────────

if aws dynamodb describe-table \
    --table-name "${TABLE_NAME}" \
    --region "${REGION}" \
    --query 'Table.TableStatus' \
    --output text 2>/dev/null | grep -q "ACTIVE"; then
  echo "[DynamoDB] Table already exists: ${TABLE_NAME}"
else
  echo "[DynamoDB] Creating table: ${TABLE_NAME}"
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" \
    --tags \
      Key=Project,Value=petclinic \
      Key=ManagedBy,Value=terraform

  echo "[DynamoDB] Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists \
    --table-name "${TABLE_NAME}" \
    --region "${REGION}"
  echo "[DynamoDB] Table created"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Auto-update backend.tf files so terraform init works without manual edits
for ENV_DIR in "$REPO_ROOT/terraform/environments"/*/; do
  BACKEND_FILE="$ENV_DIR/backend.tf"
  if [[ -f "$BACKEND_FILE" ]]; then
    sed -i "s|petclinic-terraform-state-[A-Z0-9_]*\"|petclinic-terraform-state-${ACCOUNT_ID}\"|g" "$BACKEND_FILE"
    echo "[backend] Updated $BACKEND_FILE → bucket = \"${BUCKET_NAME}\""
  fi
done

echo ""
echo "Bootstrap complete!"
echo ""
echo "Backend configuration:"
echo "  bucket         = \"${BUCKET_NAME}\""
echo "  dynamodb_table = \"${TABLE_NAME}\""
echo "  region         = \"${REGION}\""
echo ""
echo "backend.tf files updated automatically. Next step:"
echo "  cd terraform/environments/{dev|prod} && terraform init"
