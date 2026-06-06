output "cloudflare_zone_id" {
  description = "Cloudflare zone ID — used when creating additional DNS records in the same zone"
  value       = data.cloudflare_zone.main.id
}

output "certificate_arn" {
  description = "ACM wildcard certificate ARN — set this in the Ingress annotation alb.ingress.kubernetes.io/certificate-arn"
  value       = aws_acm_certificate_validation.main.certificate_arn
}
