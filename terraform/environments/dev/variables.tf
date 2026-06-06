variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "domain_name" {
  description = "Base domain name managed in Cloudflare DNS (e.g., example.com). Used for ACM certificate and Cloudflare CNAME records. Supply your own domain — no default."
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the ALB created by the Load Balancer Controller (e.g., k8s-petclinic-xxxx.eu-central-1.elb.amazonaws.com). Leave empty on first apply; populate after the Ingress creates the ALB and re-apply to create the Cloudflare CNAME."
  type        = string
  default     = ""
}
