variable "project" {
  type        = string
  description = "Project name used in resource naming"
  default     = "petclinic"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in owner/repo format whose main branch may assume this role (e.g., paharipratyush/spring-petclinic-microservices)"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all resources"
  default     = {}
}
