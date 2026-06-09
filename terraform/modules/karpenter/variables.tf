variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be 'dev' or 'prod'."
  }
}

variable "cluster_name" {
  description = "EKS cluster name (used for scoping EKS permissions and EventBridge patterns)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN from the EKS cluster (used in IRSA trust policy)"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL from the EKS cluster — without https:// prefix (used in IRSA trust policy conditions)"
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for EKS nodes. Karpenter-launched nodes assume this role via the instance profile. iam:PassRole is scoped to this ARN to prevent privilege escalation."
  type        = string
}

variable "tags" {
  description = "Additional tags to merge onto all resources"
  type        = map(string)
  default     = {}
}
