variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "prod"
}

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "domain_name" {
  description = "Base domain name for Route 53 hosted zone and ACM certificate (e.g., example.com). Supply your own domain — no default."
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the ALB created by the Load Balancer Controller (e.g., k8s-petclini-xxxx.eu-central-1.elb.amazonaws.com). Leave empty on first apply; populate after the Ingress creates the ALB and then re-apply to create the Route 53 A record."
  type        = string
  default     = ""
}
