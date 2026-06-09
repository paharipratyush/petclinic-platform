variable "domain_name" {
  description = "Base domain name for the platform (e.g., example.com). A Route53 hosted zone is created for this domain. After apply, configure the outputted nameservers at your domain registrar to delegate DNS to Route53."
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
