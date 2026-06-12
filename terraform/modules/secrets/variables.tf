variable "project" {
  description = "Project name"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment (dev or prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be 'dev' or 'prod'."
  }
}

variable "openai_api_key" {
  description = "OpenAI API key for the GenAI service"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Stored in Secrets Manager at petclinic/{env}/grafana-admin."
  type        = string
  sensitive   = true
}

variable "recovery_window_in_days" {
  description = "Days Secrets Manager waits before permanently deleting a secret. Use 0 for dev (force delete — allows same-day destroy+recreate), 30 for prod (disaster recovery compliance). Valid: 0 or 7–30."
  type        = number
  default     = 30

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0 (force delete) or between 7 and 30."
  }
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
