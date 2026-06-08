# ADR-0008: ArgoCD for GitOps (CD)

**Status:** Accepted
**Date:** 2026-06-08

## Context

The project needed a continuous delivery mechanism for deploying Docker images to EKS after the CI pipeline builds and pushes them to ECR. Options evaluated:

1. **GitHub Actions deploy job** — run `helm upgrade` or `kubectl apply` from CI. Simple, but stores cluster credentials in GitHub Secrets, mixes CI (build) and CD (deploy) concerns, and provides no visibility into deployment state.
2. **ArgoCD** — dedicated GitOps controller running in-cluster. Watches the Git repo for changes and reconciles the cluster state to match.
3. **Flux CD** — alternative GitOps tool with similar architecture to ArgoCD but lighter-weight and without a UI.

The project already adopted Helm (ADR-0007), and the CI pipeline's `update-image-tags.yml` writes new image tags to `helm-values/` — a natural GitOps trigger point.

## Decision

Use **ArgoCD** as the sole CD mechanism. GitHub Actions (CI) builds images, pushes to ECR, and commits updated image tags to `helm-values/`. ArgoCD detects the Git change and syncs the Helm release to EKS.

**Dev:** auto-sync (`automated: {prune: true, selfHeal: true}`) — changes deploy within seconds of the tag commit.

**Prod:** manual sync — ArgoCD detects OutOfSync but requires explicit approval via ArgoCD UI or `argocd app sync`. No automated production deploys.

## Consequences

**Positive:**
- No AWS credentials stored in GitHub for deployments — ArgoCD runs in-cluster with its own service account
- Declarative CD: desired state is in Git; ArgoCD continuously reconciles drift
- ArgoCD UI provides deployment history, health status, diff view, and manual rollback for all 16 applications
- `selfHeal: true` in dev automatically corrects manual `kubectl` changes that diverge from Git
- `prune: true` removes K8s resources deleted from Helm charts
- Prod manual sync serves as a deployment gate without requiring GitHub Environments (which require GitHub Enterprise for private repos)

**Negative:**
- ArgoCD adds cluster complexity: ~6 additional pods in the `argocd` namespace
- Team must understand ArgoCD Application CRD structure and sync options
- ArgoCD version upgrades are a separate operational concern
- CI cross-repo `repository_dispatch` token (`PLATFORM_REPO_TOKEN`) must be maintained

## Installation

ArgoCD v3.4.3 installed via official manifests at `k8s/argocd/install/install.yaml` (downloaded from stable branch). Namespace: `argocd`. Access: `kubectl port-forward svc/argocd-server -n argocd 8080:443`.

## RBAC

Configured via `k8s/argocd/argocd-rbac-cm.yaml`:
- `role:admin` — full access (all apps, clusters, repos, settings)
- `role:developer` — view all apps, sync dev environment only
- `policy.default: role:readonly` — unauthenticated users get read-only

## References

- Jira: PETPLAT-112 (Install ArgoCD), PETPLAT-113 (Dev Applications), PETPLAT-114 (Prod Applications), PETPLAT-115 (RBAC), PETPLAT-116 (E2E test)
- Technical Spec: [GitOps with ArgoCD](../technical-spec.md#gitops-with-argocd)
- Application CRDs: `k8s/argocd/applications/{dev,prod}/`
- RBAC: `k8s/argocd/argocd-rbac-cm.yaml`
- Install: `k8s/argocd/install/`
