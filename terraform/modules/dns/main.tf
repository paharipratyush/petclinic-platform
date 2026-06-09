# Cloudflare zone lookup — the zone must already exist in Cloudflare (it does because
# praty.dev is registered via Cloudflare Registrar). Zone:Read permission required.
data "cloudflare_zone" "main" {
  name = var.domain_name
}

# ACM wildcard certificate — covers *.domain and the apex domain.
resource "aws_acm_certificate" "main" {
  domain_name               = "*.${var.domain_name}"
  subject_alternative_names = [var.domain_name]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# ACM validation CNAMEs in Cloudflare.
# ACM emits the same resource_record_name for both *.domain and domain SANs.
# The grouping operator (...) deduplicates them so only one Cloudflare record is created.
# proxied = false is required — Cloudflare proxy cannot front ACM validation CNAMEs.
resource "cloudflare_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
      dvo.resource_record_name => {
        name    = trimsuffix(trimsuffix(dvo.resource_record_name, ".${var.domain_name}."), ".")
        content = trimsuffix(dvo.resource_record_value, ".")
        type    = dvo.resource_record_type
      }...
  }

  zone_id = data.cloudflare_zone.main.id
  name    = each.value[0].name
  content = each.value[0].content
  type    = each.value[0].type
  ttl     = 60
  proxied = false
}

# Blocks until ACM transitions the certificate status to ISSUED.
# Completes within 2-5 minutes because Cloudflare is the authoritative DNS.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in cloudflare_record.cert_validation : r.hostname]
}
