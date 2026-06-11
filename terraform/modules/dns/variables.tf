variable "domain_name" {
  description = "Base domain name for the platform (e.g., yourdomain.com). Must be a domain managed via Cloudflare DNS. The Cloudflare zone is looked up by name — no zone ID needed. CLOUDFLARE_API_TOKEN must be set in the environment with Zone:Read and DNS:Edit permissions."
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
