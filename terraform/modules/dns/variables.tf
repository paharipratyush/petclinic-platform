variable "domain_name" {
  description = "Domain name for the Route 53 hosted zone (e.g., example.com). Supply your own domain — no default. Anyone with any domain from any registrar can use this module."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid domain name without trailing dot (e.g., example.com)."
  }
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
