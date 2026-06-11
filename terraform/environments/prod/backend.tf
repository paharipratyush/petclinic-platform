# IMPORTANT: Replace the bucket name with the one created by scripts/bootstrap-state.sh
# for your AWS account. The bucket name includes your account ID for global uniqueness.
# Run: aws sts get-caller-identity --query Account --output text
# then: bucket = "petclinic-terraform-state-{YOUR_ACCOUNT_ID}"
terraform {
  backend "s3" {
    bucket         = "petclinic-terraform-state-YOUR_ACCOUNT_ID"
    key            = "petclinic/prod/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "petclinic-terraform-locks"
    encrypt        = true
  }
}
