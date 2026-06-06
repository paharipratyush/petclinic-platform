variable "domain_name" {
  description = "Domain name managed in Cloudflare DNS (e.g., example.com). The Cloudflare zone is looked up by name — the domain must already exist in your Cloudflare account. Requires CLOUDFLARE_API_TOKEN env var."
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
