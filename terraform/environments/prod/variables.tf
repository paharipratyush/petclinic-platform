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
  description = "Base domain name for the platform (e.g., yourdomain.com). Must be managed via Cloudflare DNS. CLOUDFLARE_API_TOKEN must be set in the environment. See ADR-0013."
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

variable "grafana_admin_password" {
  description = "Grafana admin password. Stored in Secrets Manager at petclinic/{env}/grafana-admin. Set via TF_VAR_grafana_admin_password — never hardcoded."
  type        = string
  sensitive   = true
}

variable "budget_alert_email" {
  description = "Email address for AWS Budget alerts (50%, 80%, 100% of $100/month). Set via TF_VAR_budget_alert_email."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo in owner/repo format whose main branch may push images to ECR (e.g., your-username/spring-petclinic-microservices). Scopes the OIDC trust policy — required for CI/CD."
  type        = string
}
