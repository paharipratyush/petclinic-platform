# ADR-0009: ECR Private Registry with Production Patterns

**Status:** Accepted
**Date:** 2026-06-08
**Epic:** E-4 (PETPLAT-18 through PETPLAT-21)

## Context

The project needs a container registry to store Docker images for the 8 Spring Boot microservices. Options include:
- **Docker Hub (public):** Free, widely used, but public images expose the app; rate limiting on pulls
- **Docker Hub (private):** $5/month per user, not integrated with AWS IAM
- **GitHub Container Registry (GHCR):** Free with GitHub Actions; would require additional auth step at EKS pull time
- **ECR Private:** AWS-native, integrates with IAM/IRSA, same-region pulls are free from EKS

As a learning project, ECR provides an opportunity to teach production-correct registry practices (private images, lifecycle policies, vulnerability scanning, tag immutability) at minimal cost.

## Decision

Use **AWS ECR private repositories** in `eu-central-1`, one repository per service, in the format `petclinic-{env}/{service}` (e.g., `petclinic-dev/api-gateway`).

Key configuration decisions:
- **Tag immutability:** Enabled in prod, configurable per environment — prevents overwriting a deployed tag
- **Scan on push:** Enabled — automatically runs Amazon Inspector CVE scanning on every pushed image
- **Lifecycle policy:** Keeps the 10 most recent images per repository, automatically expires older ones
- **`force_delete = true`:** Required to allow `terraform destroy` when images exist in the repository
- **Image format:** `linux/arm64` (built with `docker buildx` + QEMU for Graviton t4g nodes)

## Consequences

**Positive:**
- IAM-authenticated pulls — no separate registry credentials needed at EKS nodes (IRSA handles auth)
- Same-region data transfer is free — pulling images from EKS in eu-central-1 to ECR in eu-central-1 costs $0
- Lifecycle policies prevent unbounded storage growth; at ~200 MB/image × 8 services × 10 versions ≈ 16 GB peak storage (~$1.60/month)
- Scan-on-push provides CVE visibility before deployment
- Teaches production registry security patterns (private, immutable tags, scanning)

**Negative:**
- ECR authentication token expires every 12 hours — CI and local tools must re-authenticate
- Tag immutability in prod means a re-build of the same commit SHA requires a new tag or a manual force-push
- Storage cost: ~$0.10/GB/month beyond the 500 MB free tier

## Alternatives Considered

- **GHCR:** Would work but requires additional secret management for EKS image pull (either image pull secret or IRSA extension). Less integrated with the AWS ecosystem being taught.
- **Public ECR:** Free for 50 GB/month egress, but images are publicly visible — not appropriate even for a learning project.

## Related

- [PETPLAT-18](../jira-backlog.md) — Create ECR module
- [PETPLAT-19](../jira-backlog.md) — Lifecycle policy and tag immutability
- [ADR-0002](./0002-arm64-graviton-nodes.md) — ARM64 image architecture
- [ADR-0011](./0011-secrets-manager-eso.md) — Secrets management (IRSA enables registry auth)
