output "zone_id" {
  description = "Route53 hosted zone ID — used when creating additional DNS records in the same zone"
  value       = aws_route53_zone.main.zone_id
}

output "nameservers" {
  description = "Route53 nameservers — configure these NS records at your domain registrar to delegate DNS to Route53"
  value       = aws_route53_zone.main.name_servers
}

output "certificate_arn" {
  description = "ACM wildcard certificate ARN — set this in the Ingress annotation alb.ingress.kubernetes.io/certificate-arn"
  value       = aws_acm_certificate_validation.main.certificate_arn
}
