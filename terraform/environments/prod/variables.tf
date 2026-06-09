variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "prod"
}

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "domain_name" {
  description = "Base domain name for the platform (e.g., example.com). A Route53 hosted zone is created for this domain. After first apply, set the outputted nameservers at your domain registrar to delegate DNS to Route53."
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name override — only needed if you want to bypass SSM. Normally leave empty: scripts/install-lb-controller.sh writes the ALB hostname to SSM after provisioning, and re-running terraform apply picks it up automatically."
  type        = string
  default     = ""
}

variable "openai_api_key" {
  description = "OpenAI API key for the GenAI service. Passed to Secrets Manager — never hardcoded. Set via TF_VAR_openai_api_key environment variable or a secrets-only .tfvars file that is never committed."
  type        = string
  sensitive   = true
}
