variable "project" {
  description = "Project name"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment (dev or prod)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN from the EKS module (for IRSA)"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL from the EKS module (for IRSA trust policies)"
  type        = string
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
