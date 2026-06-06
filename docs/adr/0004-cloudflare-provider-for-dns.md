# ADR-0004: Cloudflare Terraform Provider for DNS (Instead of Route 53)

**Status:** Accepted
**Date:** 2026-06-07
**PETPLAT:** PETPLAT-28, PETPLAT-31, PETPLAT-32

---

## Context

The original E-6 design used AWS Route 53 as the authoritative DNS for `praty.dev`:

1. Terraform creates a Route 53 hosted zone.
2. ACM requests a wildcard certificate with DNS validation; Route 53 creates the CNAME validation record.
3. The operator updates the domain registrar's nameservers to the four Route 53 NS values.
4. Once Route 53 is authoritative, ACM validates and issues the certificate.
5. A Route 53 alias A record points `petclinic-dev.praty.dev` → ALB.

This approach breaks when the domain is registered through **Cloudflare Registrar**. Cloudflare Registrar does not support custom nameservers — the domain is permanently locked to Cloudflare's nameservers and cannot be delegated to Route 53. The Route 53 hosted zone can be created but it never becomes authoritative, so:

- ACM's DNS validation CNAME is never found by Amazon's validation service.
- `aws_acm_certificate_validation` blocks indefinitely.
- `terraform apply` never completes.

There is no workaround within the Route 53 approach for a Cloudflare-registered domain.

---

## Decision

Replace Route 53 with the **Cloudflare Terraform provider** (`cloudflare/cloudflare ~> 4.0`) for all DNS record management.

The DNS module (`terraform/modules/dns/`) now:

1. Looks up the Cloudflare zone ID with `data "cloudflare_zone"` using the domain name.
2. Requests an ACM wildcard certificate with DNS validation (unchanged).
3. Creates the ACM validation CNAME(s) in Cloudflare via `cloudflare_record`, using the grouping operator (`...`) to deduplicate the shared record that satisfies both the `*.domain` and `domain` SANs.
4. `aws_acm_certificate_validation` blocks until the cert is ISSUED — which now completes automatically within minutes because Cloudflare is the authoritative DNS.

The environment root modules (`terraform/environments/{dev,prod}/main.tf`) create the application DNS record:

```hcl
resource "cloudflare_record" "app" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = module.dns.cloudflare_zone_id
  name    = "petclinic-dev"   # or "petclinic" for prod
  content = var.alb_dns_name
  type    = "CNAME"
  proxied = false             # DNS-only; Cloudflare proxy cannot front AWS ALBs
}
```

A two-stage apply pattern is used:

- **First apply** (`alb_dns_name = ""`): creates the ACM cert + IRSA role; validation CNAME goes live in Cloudflare; cert issues.
- **Second apply** (after `install-lb-controller.sh` provisions the ALB): passes the ALB hostname to `alb_dns_name`; creates the `petclinic-dev.praty.dev` CNAME.

Authentication uses `CLOUDFLARE_API_TOKEN` from the operator's environment — never stored in code or state.

---

## Consequences

### Positive

- **Zero manual steps:** Both the ACM validation CNAME and the app CNAME are created by Terraform. No registrar console interaction required.
- **Fast cert issuance:** ACM validates within 2–5 minutes because Cloudflare is authoritative and the CNAME is live immediately after `terraform apply`.
- **No state-blocking:** Previous approach required a separate terminal, manual registrar steps, and up to 48 hours of propagation. Now `terraform apply` completes uninterrupted.
- **Domain-agnostic:** The module uses `data "cloudflare_zone"` (name lookup) — no hardcoded zone IDs. Works for any Cloudflare-managed domain.

### Negative / Watch out for

- **CLOUDFLARE_API_TOKEN required:** Every `terraform plan` and `terraform apply` needs `CLOUDFLARE_API_TOKEN` set in the environment. The token needs `Zone:Read` and `DNS:Edit` permissions scoped to the domain's zone. Store it in a password manager; rotate it after any exposure.
- **Cloudflare-only:** This approach only works for domains managed on Cloudflare. For Route 53–registered domains or other registrars, the original Route 53 approach is still valid.
- **`proxied = false` required:** ACM validation CNAMEs and ALB CNAMEs must be DNS-only (gray cloud). Enabling Cloudflare proxy would intercept traffic before it reaches the ALB, breaking TLS termination.
- **Duplicate SAN dedup pattern:** ACM emits identical `resource_record_name` for `*.domain` and `domain` validation. The `for` expression uses Terraform's grouping operator (`...`) and accesses `each.value[0]`. This is intentional — do not simplify it.
- **Provider version pinned at `~> 4.0`:** Cloudflare provider v5 has breaking changes. Update `.terraform.lock.hcl` and test before upgrading.

### Outputs changed

| Old (Route 53) | New (Cloudflare) | Downstream impact |
|----------------|------------------|-------------------|
| `zone_id` (Route 53 hosted zone ID) | removed | No downstream consumers |
| `zone_name_servers` | removed | No downstream consumers |
| `certificate_arn` | `certificate_arn` (unchanged) | `install-lb-controller.sh`, Ingress annotation |
| — | `cloudflare_zone_id` added | `cloudflare_record.app` in env root modules |

### When to revisit

- If the domain is ever moved away from Cloudflare Registrar to a registrar that supports custom nameservers, the Route 53 approach becomes viable again.
- If the project needs a second domain not on Cloudflare, add a second provider alias or a separate module invocation.

---

## Related

- ADR-0001: All-public subnet design (cost optimization context)
- PETPLAT-28: DNS module implementation
- PETPLAT-31: DNS record pointing to ALB
- `terraform/modules/dns/main.tf` — Cloudflare provider implementation
- `terraform/environments/{dev,prod}/providers.tf` — Cloudflare provider block
