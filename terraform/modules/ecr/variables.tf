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

variable "service_names" {
  description = "List of microservice names to create ECR repositories for (lowercase alphanumeric, hyphens, underscores)"
  type        = list(string)

  validation {
    condition     = length(var.service_names) > 0 && alltrue([for n in var.service_names : can(regex("^[a-z0-9][a-z0-9_-]*$", n))])
    error_message = "service_names must be non-empty; each name must be lowercase alphanumeric and may contain hyphens or underscores."
  }
}

variable "tag_mutability" {
  description = "Image tag mutability: MUTABLE for dev (re-push same tag), IMMUTABLE for prod (tags cannot be overwritten)"
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.tag_mutability)
    error_message = "tag_mutability must be 'MUTABLE' or 'IMMUTABLE'."
  }
}

variable "tags" {
  description = "Additional tags to merge with default resource tags"
  type        = map(string)
  default     = {}
}
