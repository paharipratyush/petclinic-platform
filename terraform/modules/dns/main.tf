# Cloudflare zone lookup — the zone must already exist in Cloudflare (registered via
# Cloudflare Registrar). Zone:Read permission required.
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
# Keyed by dvo.domain_name and filtered to non-wildcard entries only.
#
# Why the filter: a wildcard cert covering *.domain + domain produces TWO
# domain_validation_options entries but IDENTICAL resource_record_* values —
# AWS reuses the same CNAME for both SANs. Without the filter, two
# cloudflare_record resources manage the same DNS record. apply works
# (allow_overwrite handles the duplicate) but destroy fails: the first
# deletion removes the record, the second gets "Record does not exist (81044)".
# Filtering to !startswith("*.") creates exactly ONE record, which is
# sufficient — ACM only needs the CNAME present once to validate both SANs.
#
# domain_name (not resource_record_name) is used as the map key because
# resource_record_name is unknown until after apply, causing an
# "Invalid for_each argument" error on the first plan.
# proxied = false is required — Cloudflare proxy cannot front ACM validation CNAMEs.
resource "cloudflare_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => {
      name    = trimsuffix(trimsuffix(dvo.resource_record_name, ".${var.domain_name}."), ".")
      content = trimsuffix(dvo.resource_record_value, ".")
      type    = dvo.resource_record_type
    }
    if !startswith(dvo.domain_name, "*.")
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
