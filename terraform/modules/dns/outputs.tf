output "zone_id" {
  description = "Route 53 hosted zone ID — used when creating DNS records in this zone"
  value       = aws_route53_zone.main.zone_id
}

output "name_servers" {
  description = "Route 53 NS records — update your domain registrar to delegate DNS to these nameservers"
  value       = aws_route53_zone.main.name_servers
}

output "certificate_arn" {
  description = "ACM wildcard certificate ARN — set this in the Ingress annotation alb.ingress.kubernetes.io/certificate-arn"
  value       = aws_acm_certificate_validation.main.certificate_arn
}
