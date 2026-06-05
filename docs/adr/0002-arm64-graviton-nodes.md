# ADR-0002: ARM64 (Graviton) EKS Worker Nodes

**Status:** Accepted
**Date:** 2026-06-06

## Context

EKS managed node groups support both x86_64 (`t3.small`, `t3.medium`) and ARM64 (`t4g.small`, `t4g.medium`) architectures. We need to choose one for the petclinic-platform worker nodes across both environments.

AWS offers a **Graviton free trial**: t4g instances are free for 750 hours/month until December 2026. At the time of this decision, running two t4g.small nodes costs $0/month during the trial vs ~$30/month for equivalent x86 t3.small nodes.

The trade-off is that ARM64 nodes cannot run x86-only Docker images, so **all application container images must be built for `linux/arm64`**.

## Decision

Use `t4g.small` (`AL2023_ARM_64_STANDARD`) nodes in both dev and prod.

Both environments use identical sizing (2 nodes min/desired, 4 max) — this is a cost optimization acceptable for a learning project. A real production deployment would use larger Graviton instances (e.g., `m7g.xlarge`).

## Consequences

**Positive:**
- ~$30/month savings per environment during the Graviton free trial (Dec 2026)
- ARM64 (Graviton) offers better price-performance ratio than x86 at equivalent sizes
- Encourages use of multi-arch Docker builds — an industry best practice

**Negative / Watch out for:**
- All Docker images pushed to ECR must target `linux/arm64`. Images built on standard x86 CI runners will not run on these nodes.
- CI pipelines must use `docker buildx` with QEMU emulation (or a native ARM runner) to cross-compile for ARM64. This adds ~2-3 minutes to build times on x86 runners.
- Any third-party Helm chart or operator that ships x86-only images will fail to schedule. Verify ARM64 image availability before adding new dependencies.
- After the Graviton free trial ends (December 2026), evaluate whether to continue with t4g or switch to t3/x86 based on actual workload requirements.

## Trade-offs Accepted

| Trade-off | Accepted Because |
|-----------|-----------------|
| More complex CI/CD (docker buildx + QEMU) | Cost savings justify the one-time setup effort |
| Risk of incompatible third-party images | All 8 petclinic services use standard JVM/Spring images with ARM64 variants |
| Trial ends December 2026 | Enough runway to complete the learning project; re-evaluate at trial expiry |

## When to Revisit

- **December 2026:** Graviton trial expires — compare t4g vs t3 pricing and decide based on actual cost
- **If an add-on or operator does not have ARM64 images:** Evaluate switching to x86 or using a mixed node group
- **When scaling to real production loads:** Replace t4g.small with appropriately sized instances (m7g.xlarge or similar) regardless of architecture choice

## Related

- ADR-0001: All-public subnet design (cost optimization context)
- PETPLAT-12, PETPLAT-13: EKS cluster and node group implementation
- CLAUDE.md: Docker image details section (linux/arm64 requirement)
