variable "domain_name" {
  description = "Domain name for the Route 53 hosted zone (e.g., example.com)"
  type        = string
}

variable "tags" {
  description = "Additional tags to merge with default tags"
  type        = map(string)
  default     = {}
}
