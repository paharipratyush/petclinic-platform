# Helm Guide — Petclinic Platform (E-16)

**Last Updated:** 2026-06-10
**Purpose:** Reference for using and extending the single generic Helm chart shared by all 8 Spring Petclinic services.

## Table of Contents

1. [Overview](#overview)
2. [Chart Structure](#chart-structure)
3. [Values Hierarchy](#values-hierarchy)
4. [Image Registry](#image-registry)
5. [Probe Paths](#probe-paths)
6. [Deploying a Service (Manual)](#deploying-a-service-manual)
7. [Rendering Templates (Debugging)](#rendering-templates-debugging)
8. [Validating All 16 Releases](#validating-all-16-releases)
9. [ArgoCD Integration](#argocd-integration)
10. [Adding a New Service](#adding-a-new-service)
11. [Security Constraints](#security-constraints)
12. [HPA and PDB Reference](#hpa-and-pdb-reference)

---

## Overview

A single generic Helm chart (`helm/petclinic-service/`) is shared by all 8 Spring Petclinic services. Per-service and per-environment configuration lives in `helm-values/`.

## Chart Structure

```
helm/petclinic-service/
├── Chart.yaml              # Chart metadata — name: petclinic-service, version: 0.1.0
├── values.yaml             # Default values (all keys, sensible defaults)
└── templates/
    ├── _helpers.tpl         # Reusable helpers: fullname, labels, selectorLabels, image
    ├── deployment.yaml      # Deployment: probes, resources, init containers, security context
    ├── service.yaml         # ClusterIP Service
    ├── configmap.yaml       # ConfigMap from .Values.config map
    ├── serviceaccount.yaml  # ServiceAccount with optional IRSA annotations
    ├── hpa.yaml             # HPA — only renders when autoscaling.enabled: true
    ├── pdb.yaml             # PDB — only renders when podDisruptionBudget.enabled: true
    └── NOTES.txt            # Post-install summary
```

## Values Hierarchy

ArgoCD merges values in this order (right-most wins):

```
values.yaml  ←  helm-values/{service}.yaml  ←  helm-values/{env}.yaml
```

Maps are deep-merged. Lists are replaced (last wins).

### values.yaml — chart defaults

All keys are defined here with sensible defaults. Per-service and env files override only what differs.

### helm-values/{service}.yaml — per-service config

| Key | Purpose |
|-----|---------|
| `image.name` | Image name. Currently full Docker Hub path (e.g., `springcommunity/spring-petclinic-config-server`). See [Image Registry Migration](#image-registry-migration). |
| `image.tag` | Image tag. Default: `latest`. CI updates this on every push (PETPLAT-85). |
| `service.port` | Container port |
| `component` | `app.kubernetes.io/component` label value |
| `replicaCount` | **Prod** replica count. `dev.yaml` overrides to 1. |
| `autoscaling.*` | HPA settings (enabled, min, max, CPU target). `dev.yaml` disables. |
| `podDisruptionBudget.*` | PDB settings. `dev.yaml` disables. |
| `resources.*` | CPU/memory requests and limits (override only if different from default) |
| `config` | Map of env vars injected via ConfigMap |
| `initContainers` | Init container list (wait-for-config-server, wait-for-discovery-server) |
| `secrets` | List of `{name, secretName, key}` for secretKeyRef env vars |
| `probes.readiness.path` / `probes.liveness.path` | Override for config-server (`/actuator/health`) |

### helm-values/{env}.yaml — per-environment overrides

**dev.yaml** — always overrides:
- `image.registry` → ECR petclinic-dev path
- `replicaCount: 1`
- `autoscaling.enabled: false`
- `podDisruptionBudget.enabled: false`

**prod.yaml** — always overrides:
- `image.registry` → ECR petclinic-prod path
- Per-service replica counts, HPA, and PDB come from the per-service values file.
- `config.SPRING_DATASOURCE_URL` must be updated in each MySQL service's values file after the prod RDS endpoint is known (do NOT set globally here — it causes datasource autoconfiguration on non-MySQL services).

## Image Registry

The image reference is assembled from three values:

```
{image.registry}/{image.name}:{image.tag}
```

- `image.registry` — set in the env file (`dev.yaml` / `prod.yaml`)
  - dev: `568521409121.dkr.ecr.eu-central-1.amazonaws.com/petclinic-dev`
  - prod: `568521409121.dkr.ecr.eu-central-1.amazonaws.com/petclinic-prod`
- `image.name` — short service name in the per-service file (e.g., `api-gateway`)
- `image.tag` — 7-char git SHA; CI updates this via `yq` on every push

When `image.registry` is empty the helper renders `{name}:{tag}` (useful for local dev without ECR).

## Probe Paths

| Probe | Path | Notes |
|-------|------|-------|
| Startup | `/actuator/health` | All services — gates liveness/readiness until Spring boots |
| Readiness | `/actuator/health/readiness` | All services except config-server |
| Liveness | `/actuator/health/liveness` | All services except config-server |
| config-server | `/actuator/health` | All three probes use the same path (no readiness/liveness endpoints) |

## Deploying a Service (Manual)

```bash
# dev
helm upgrade --install config-server helm/petclinic-service/ \
  --namespace petclinic-dev \
  -f helm-values/config-server.yaml \
  -f helm-values/dev.yaml \
  --set image.tag=$(git rev-parse --short HEAD)

# prod (same pattern, different env file + namespace)
helm upgrade --install api-gateway helm/petclinic-service/ \
  --namespace petclinic-prod \
  -f helm-values/api-gateway.yaml \
  -f helm-values/prod.yaml \
  --set image.tag=$(git rev-parse --short HEAD)
```

## Rendering Templates (Debugging)

```bash
# Render a specific service to stdout
helm template customers-service helm/petclinic-service/ \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml

# Dry-run against the cluster
helm template customers-service helm/petclinic-service/ \
  --namespace petclinic-dev \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml \
  | kubectl apply --dry-run=client --validate=false -f -
```

## Validating All 16 Releases

```bash
bash scripts/validate-helm.sh              # all 8 services × 2 envs
bash scripts/validate-helm.sh --env dev    # dev only
bash scripts/validate-helm.sh --service api-gateway  # one service both envs
```

## ArgoCD Integration

Each ArgoCD Application (in `k8s/argocd/applications/{env}/`) points to the chart and merges both value files:

```yaml
spec:
  source:
    repoURL: https://github.com/<YOUR_GITHUB_USERNAME>/petclinic-platform.git
    targetRevision: main
    path: helm/petclinic-service
    helm:
      releaseName: customers-service
      valueFiles:
        - ../../helm-values/customers-service.yaml
        - ../../helm-values/dev.yaml
```

`releaseName` must match the Helm release name used during initial `helm install` so that rendered resource names (e.g., `customers-service`) remain stable. ArgoCD uses the Application name (`customers-service-dev`) as the release name by default — `releaseName` overrides this.

### Image Tag Update Mechanism (PETPLAT-87)

CI updates `image.tag` in `helm-values/{service}.yaml` after every push using `yq`. The choice of `yq` over `sed` is deliberate: `yq` preserves YAML structure and comments, avoids regex escaping pitfalls with version strings, and handles nested keys cleanly.

**Flow:**
1. `build-push.yml` (app repo) builds ARM64 images and pushes to ECR with a 7-char SHA tag.
2. It fires a `repository_dispatch` event (`app-image-built`) to the platform repo carrying the SHA and list of changed services.
3. `update-image-tags.yml` (platform repo) receives the event, validates the payload, and runs:
   ```bash
   yq -i ".image.tag = \"${SHA}\"" "helm-values/${service}.yaml"
   ```
4. The commit is pushed to `main`. ArgoCD detects it within ~3 minutes and syncs (dev: auto, prod: manual).

To roll back to a previous tag, revert the `image.tag` value in the relevant `helm-values/{service}.yaml` and push — ArgoCD will deploy the older image.

## Adding a New Service

1. Create `helm-values/{new-service}.yaml` — set `image.name`, `service.port`, `config`, `initContainers`, `secrets`
2. Set `replicaCount`, `autoscaling`, and `podDisruptionBudget` for prod defaults
3. Run `bash scripts/validate-helm.sh --service {new-service}`
4. Create ArgoCD Application CRDs in `k8s/argocd/applications/{dev,prod}/`

## Security Constraints

- **No secrets in values files.** All secret-backed env vars use `secrets:` list → `secretKeyRef` in the Deployment. The actual secrets are in AWS Secrets Manager, synced by External Secrets Operator.
- **`readOnlyRootFilesystem: true`** — set in the Deployment template. A `/tmp` emptyDir volume is mounted so Spring Boot can write temp files during startup. If a service needs additional writable paths, add another emptyDir volume mount in its service values file.
- **`pullPolicy: IfNotPresent`** — default in `values.yaml`. CI always pushes new tags; the tag change triggers a pod rollout, so re-pulling the same tag is unnecessary.

## HPA and PDB Reference

| Service | HPA | PDB | Prod Replicas |
|---------|-----|-----|--------------|
| config-server | No | Yes (min=1) | 2 |
| discovery-server | No | Yes (min=1) | 2 |
| api-gateway | Yes (2–6, CPU 70%) | Yes (min=1) | 2 |
| customers-service | Yes (2–4, CPU 70%) | Yes (min=1) | 2 |
| visits-service | Yes (2–4, CPU 70%) | Yes (min=1) | 2 |
| vets-service | Yes (2–4, CPU 70%) | Yes (min=1) | 2 |
| genai-service | Yes (1–3, CPU 70%) | No | 1 |
| admin-server | No | No | 1 |
