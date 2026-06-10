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
# Keyed by dvo.domain_name ("praty.dev" / "*.praty.dev") because dvo.resource_record_name
# is only known after the ACM cert is created — using it as a for_each key causes
# "Invalid for_each argument" on the first apply. domain_name is known at plan time.
# allow_overwrite = true handles the case where *.domain and domain SANs produce the
# same validation CNAME (AWS emits two domain_validation_options entries with identical
# resource_record_* values); the second record resource overwrites the first harmlessly.
# proxied = false is required — Cloudflare proxy cannot front ACM validation CNAMEs.
resource "cloudflare_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
      dvo.domain_name => {
        name    = trimsuffix(trimsuffix(dvo.resource_record_name, ".${var.domain_name}."), ".")
        content = trimsuffix(dvo.resource_record_value, ".")
        type    = dvo.resource_record_type
      }
  }

  zone_id         = data.cloudflare_zone.main.id
  name            = each.value.name
  content         = each.value.content
  type            = each.value.type
  ttl             = 60
  proxied         = false
  allow_overwrite = true
}

# Blocks until ACM transitions the certificate status to ISSUED.
# Completes within 2-5 minutes because Cloudflare is the authoritative DNS.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in cloudflare_record.cert_validation : r.hostname]
}
