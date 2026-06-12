variable "project" {
  type        = string
  description = "Project name used in resource naming"
  default     = "petclinic"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in owner/repo format whose main branch may assume this role (e.g., your-username/spring-petclinic-microservices)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must be in owner/repo format (e.g., your-username/spring-petclinic-microservices)."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all resources"
  default     = {}
}
