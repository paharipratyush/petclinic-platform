# ADR-0010: AWS Secrets Manager with External Secrets Operator

**Status:** Accepted
**Date:** 2026-06-08
**Epic:** E-7 (PETPLAT-33 through PETPLAT-37)

## Context

Kubernetes applications need access to secrets (database credentials, API keys). Several approaches exist:

- **Kubernetes Secrets in Git (Sealed Secrets):** Encrypted YAML checked into Git; requires cluster key for decryption. Adds complexity for rotation; still stores secret material in Git history.
- **HashiCorp Vault:** Industry standard, but heavy operational overhead (cluster to manage, HA, unsealing). Overkill for a learning project.
- **AWS SSM Parameter Store:** Simpler, cheaper ($0.05/10,000 API calls), but no automatic rotation and limited secret types.
- **AWS Secrets Manager + External Secrets Operator (ESO):** Secrets live in AWS (never in Git), ESO syncs them to K8s Secrets on a configurable interval. Integrates with IRSA for authentication.
- **In-cluster K8s Secrets (plain YAML):** Convenient but insecure — base64-encoded values in Git, no rotation, no audit trail.

The core requirement is: **secrets must never appear in Git**, rotation must be possible without redeploying pods, and the solution must teach industry-standard AWS practices.

## Decision

Use **AWS Secrets Manager** for secret storage with **External Secrets Operator (ESO) v2.x** for syncing secrets into Kubernetes.

Architecture:
1. Secrets are created in AWS Secrets Manager under the path `petclinic/{env}/{secret-name}`
2. ESO `ClusterSecretStore` authenticates to Secrets Manager via IRSA (no stored credentials)
3. ESO `ExternalSecret` CRs define which secret keys to sync into which K8s Secrets
4. Pods reference the K8s Secret via `secretKeyRef` — they never see the Secrets Manager path

Specific secrets managed:
- `petclinic/{env}/rds-credentials` — JSON with `username`/`password`, created by RDS Terraform module
- `petclinic/{env}/openai-api-key` — Plaintext API key, created by Secrets module

**ESO API version:** `external-secrets.io/v1` (stable, ESO v2.x — `v1beta1` was removed in ESO v2.0)

**Sync interval:** 1 hour (balances freshness with API call costs)

## Consequences

**Positive:**
- Zero secrets in Git — manifests only reference K8s Secret names, not values
- Rotation without pod restart — ESO re-syncs on the configured interval; Secrets Manager can rotate independently
- IRSA authentication — no long-lived AWS credentials needed inside the cluster
- Fine-grained IAM — ESO SA role has `secretsmanager:GetSecretValue` only on specific ARN patterns
- Audit trail — every secret access logged in CloudTrail
- Cost: $0.40/secret/month × 3 secrets = $1.20/month

**Negative:**
- ESO must be installed and healthy before pods that need secrets can start (init containers on ESO would be overkill; instead install ESO before applying workloads)
- API version `v1` (stable) is only available from ESO v0.9+/v2.x — `v1beta1` manifests must be updated when upgrading from older ESO
- 1-hour sync lag means newly rotated secrets take up to 1 hour to propagate to pods without a manual `kubectl delete secret` + ESO re-sync

## Alternatives Considered

- **Sealed Secrets:** Simpler to set up, but secrets are still in Git (encrypted). Key rotation requires manual re-encryption of all secrets. Less integration with AWS IAM auditing.
- **Vault:** Production-grade but requires its own HA cluster, unsealing ceremony, and significantly more operational overhead than this project warrants.
- **SSM Parameter Store:** Cheaper but lacks automatic rotation, and ESO integration requires the same setup complexity. Secrets Manager is purpose-built for secrets vs. config parameters.

## Implementation Notes

- ESO installed via Helm chart v2.5.0 (chart v2.6.0 had CDN 504 issues; pinned to v2.5.0)
- `ClusterSecretStore` configured with `auth.jwt.serviceAccountRef` pointing to `external-secrets-sa` in the `external-secrets` namespace
- CRD establishment must be verified (`kubectl wait --for=condition=Established`) before applying `ClusterSecretStore` and `ExternalSecret` manifests

## Related

- [PETPLAT-33](../jira-backlog.md) — Secrets Manager Terraform resources
- [PETPLAT-34](../jira-backlog.md) — Install ESO on EKS
- [PETPLAT-35](../jira-backlog.md) — ExternalSecret for RDS credentials
- [PETPLAT-36](../jira-backlog.md) — ExternalSecret for OpenAI API key
- [PETPLAT-37](../jira-backlog.md) — IRSA role for ESO
- [ADR-0001](./0001-public-subnets.md) — All-public design (context for why IRSA is important: no NAT, IRSA is the only auth path out)
