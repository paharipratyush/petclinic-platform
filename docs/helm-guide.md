# Helm Guide — Petclinic Platform (E-16)

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
| `image.name` | ECR image name (e.g., `config-server`). Registry comes from env file. |
| `image.tag` | Image tag. CI updates this on every push. Default: `placeholder` |
| `service.port` | Container port |
| `component` | `app.kubernetes.io/component` label value |
| `replicaCount` | **Prod** replica count. dev.yaml overrides to 1. |
| `autoscaling.*` | HPA settings (enabled, min, max, CPU target). dev.yaml disables. |
| `podDisruptionBudget.*` | PDB settings. dev.yaml disables. |
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

**prod.yaml** — only sets:
- `image.registry` → ECR petclinic-prod path
- Per-service replica counts, HPA, and PDB come from the per-service values file.

## Probe Paths

| Probe | Path | Notes |
|-------|------|-------|
| Startup | `/actuator/health` | All services — disabled liveness/readiness until Spring boots |
| Readiness | `/actuator/health/readiness` | All services except config-server |
| Liveness | `/actuator/health/liveness` | All services except config-server |
| config-server | `/actuator/health` | All three probes use the same path |

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
  -f helm-values/dev.yaml \
  --set image.tag=test

# Dry-run against the cluster
helm template customers-service helm/petclinic-service/ \
  --namespace petclinic-dev \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml \
  --set image.tag=test \
  | kubectl apply --dry-run=client -f -
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
    repoURL: https://github.com/your-org/petclinic-platform
    targetRevision: HEAD
    path: helm/petclinic-service
    helm:
      valueFiles:
        - ../../helm-values/customers-service.yaml
        - ../../helm-values/dev.yaml
```

CI updates `image.tag` in `helm-values/{service}.yaml` after every push. ArgoCD detects the commit and syncs (auto in dev, manual in prod).

## Adding a New Service

1. Create `helm-values/{new-service}.yaml` — set `image.name`, `service.port`, `config`, `initContainers`, `secrets`
2. Confirm `replicaCount`, `autoscaling`, and `podDisruptionBudget` are appropriate
3. Run `bash scripts/validate-helm.sh --service {new-service}`
4. Create ArgoCD Application CRDs in `k8s/argocd/applications/{dev,prod}/`

## Security Constraints

- **No secrets in values files.** All secret-backed env vars use `secrets:` list → `secretKeyRef` in the Deployment. The actual secrets are in AWS Secrets Manager, synced by External Secrets Operator.
- **`readOnlyRootFilesystem: false`** — Spring Boot writes temp files and logs; must remain false.
- **`imagePullPolicy: Always`** — enforced in the chart template, not overridable by values.

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
