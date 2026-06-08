# Look up the Cloudflare zone for the domain — works for any domain registered on Cloudflare.
# Requires CLOUDFLARE_API_TOKEN env var with Zone:Read + Zone:Edit (DNS) permissions.
data "cloudflare_zone" "main" {
  name = var.domain_name
}

# Wildcard certificate covers all subdomains (*.domain) and the apex domain.
# apply blocks at aws_acm_certificate_validation until the cert is issued.
resource "aws_acm_certificate" "main" {
  domain_name               = "*.${var.domain_name}"
  subject_alternative_names = [var.domain_name]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

locals {
  # Wildcard (*.domain) and apex (domain) share the same validation CNAME.
  # Selecting the wildcard DVO gives one deterministic record without for_each,
  # which avoids the "unknown for_each keys" plan error on first apply.
  primary_dvo = one([
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo if dvo.domain_name == "*.${var.domain_name}"
  ])
}

resource "cloudflare_record" "cert_validation" {
  zone_id = data.cloudflare_zone.main.id
  name    = trimsuffix(trimsuffix(local.primary_dvo.resource_record_name, ".${var.domain_name}."), ".")
  content = trimsuffix(local.primary_dvo.resource_record_value, ".")
  type    = local.primary_dvo.resource_record_type
  ttl     = 60
  proxied = false
}

# Blocks until ACM transitions the certificate status to ISSUED.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [cloudflare_record.cert_validation.hostname]
}
