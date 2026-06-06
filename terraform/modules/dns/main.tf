resource "aws_route53_zone" "main" {
  name = var.domain_name
  tags = var.tags
}

# Wildcard certificate covers all subdomains (*.domain) and the apex domain
# apply blocks at aws_acm_certificate_validation until the cert is issued.
# Before that happens, update your domain registrar's nameservers to the values
# in the name_servers output so Route 53 can satisfy the DNS challenge.
resource "aws_acm_certificate" "main" {
  domain_name               = "*.${var.domain_name}"
  subject_alternative_names = [var.domain_name]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# Route 53 CNAME records that prove domain ownership to ACM
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

# Blocks until ACM transitions the certificate status to ISSUED.
# If NS delegation is not done, this times out after ~45 minutes.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
