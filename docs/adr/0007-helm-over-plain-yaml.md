# ADR-0007: Helm over Plain K8s YAML

**Status:** Accepted
**Date:** 2026-06-08

## Context

The project initially planned raw Kubernetes YAML with Kustomize overlays (ADR-0004) to keep manifests transparent and easy to inspect. As the project scaled to 8 microservices across 2 environments, Kustomize overlays grew repetitive — each service had a near-identical Deployment/Service/ConfigMap set with only port numbers, environment variables, and resource limits differing. Managing 16 overlays (8 services × 2 environments) produced ~130 YAML files with high duplication.

Additionally, ArgoCD (E-17) integrates natively with Helm, making Helm charts the natural packaging choice for GitOps-based deployments.

## Decision

Use a **single generic Helm chart** (`helm/petclinic-service/`) shared by all 8 services. Per-service configuration is expressed in `helm-values/{service}.yaml`. Per-environment overrides are in `helm-values/{dev,prod}.yaml`. ArgoCD merges service + environment values files when deploying each Application.

## Consequences

**Positive:**
- ~130 YAML files replaced by 1 chart + 10 values files (8 service + 2 env)
- Per-service differences are explicit in values files — easy to diff and review
- ArgoCD Application CRDs reference the chart path directly; tag updates to `image.tag` in values files trigger automatic sync
- Industry-standard packaging: Helm is the dominant K8s packaging tool; students learn it directly
- `helm template` provides fast local validation without a cluster
- `helm lint` catches structural errors before commit

**Negative:**
- Helm templating (`{{ }}`, `{{ if }}`, `range`) is less transparent than raw YAML for K8s beginners
- Debugging requires understanding values merge order: defaults < service values < env values
- Chart upgrades require coordinated values file updates

## ADR Supersedes

ADR-0004 (Plain K8s YAML over Helm) — superseded by this decision. ADR-0004 is marked Superseded.

## References

- Jira: PETPLAT-107 (Create generic Helm chart), PETPLAT-108 (Per-service values), PETPLAT-109 (Per-env values)
- Technical Spec: [Helm Charts](../technical-spec.md#helm-charts)
- Chart: `helm/petclinic-service/`
- Values: `helm-values/`
