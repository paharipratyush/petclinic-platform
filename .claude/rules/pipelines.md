---
paths:
  - ".github/workflows/**/*.yml"
  - ".github/workflows/**/*.yaml"
---

# GitHub Actions Workflow Rules

## Two-Repo CI/CD Architecture

The CI/CD pipeline spans two repositories:

| Workflow | Repo | File |
|----------|------|------|
| Build & Push (CI) | **Application repo fork** (`spring-petclinic-microservices`) | `.github/workflows/build-push.yml` |
| Update Image Tags (CD trigger) | **Platform repo** (this repo) | `.github/workflows/update-image-tags.yml` |

**This platform repo contains only `update-image-tags.yml`.** The `build-push.yml` lives in the application repo fork — see PETPLAT-49.

### Platform Repo Workflow Structure

```
.github/workflows/
└── update-image-tags.yml   # Triggered by repository_dispatch from app repo → commits image tags → ArgoCD deploys
```

### Application Repo Fork Workflow Structure

```
.github/workflows/
└── build-push.yml          # Builds ARM64 images, Trivy scan, pushes to ECR, fires repository_dispatch
```

## Architecture: CI (GitHub Actions) + CD (ArgoCD)

GitHub Actions handles **CI only**. ArgoCD handles **CD**. CI never runs `kubectl apply` or `helm upgrade`.

## Job Naming

- `build` — compile, test, build Docker image
- `scan` — vulnerability scanning (Trivy)
- `push` — push to ECR
- `update-tags` — commit updated image tags to `helm-values/{service}.yaml`

## Required Practices

1. **No secrets in YAML** — use GitHub Secrets and Environment variables
2. **AWS auth via OIDC** — use `aws-actions/configure-aws-credentials` with role-to-assume, never static keys
3. **No kubectl/helm in CI** — ArgoCD deploys. CI only builds, pushes, and commits image tags
4. **Image tags** — use commit SHA (`${{ github.sha }}` short form), never `latest`
5. **Reusable workflows** — common steps in `.github/workflows/reusable/` to avoid duplication
6. **Artifact retention** — scan results saved as workflow artifacts for audit
7. **ECR login** — `aws ecr get-login-password --region eu-central-1`

## Trigger Patterns

- `build-push.yml` (application repo fork): `on: push: branches: [main]` with `dorny/paths-filter` to detect changed service directories; fires `repository_dispatch` type `app-image-built` to the platform repo
- `update-image-tags.yml` (platform repo): `on: repository_dispatch: types: [app-image-built]`; receives SHA + service list in payload, updates `helm-values/` and commits

## GitHub Secrets

- **Secrets:** `AWS_ROLE_ARN`, `AWS_REGION`, `ECR_REGISTRY`
- No EKS credentials needed in CI — ArgoCD runs in-cluster

## Error Handling

- Fail workflow on any non-zero exit code
- Fail workflow on Trivy CRITICAL findings
- On failure: do NOT retry automatically, notify team
