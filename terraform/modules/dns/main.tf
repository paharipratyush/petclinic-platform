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

# ACM emits one validation CNAME per unique record name. For a wildcard + apex
# cert, both domains share the same CNAME, so deduplicating by resource_record_name
# produces a single Cloudflare record that satisfies both SANs.
resource "cloudflare_record" "cert_validation" {
  # The wildcard (*.domain) and apex (domain) SANs share the same validation CNAME.
  # Using the grouping operator (...) deduplicates by resource_record_name so only
  # one Cloudflare record is created regardless of how many SANs share it.
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.resource_record_name => {
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
# Since the validation CNAMEs are created above in Cloudflare (the authoritative DNS),
# ACM detects them within minutes and this resource completes automatically.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for k in keys(cloudflare_record.cert_validation) : trimsuffix(k, ".")]
}
