# ADR-0004: Plain K8s YAML over Helm (Original Decision)

**Status:** Superseded by ADR-0007
**Date:** 2026-06-05

## Context

When the project first reached E-8 (Kubernetes Manifests), the team needed to choose a K8s packaging format. Options considered:

- **Plain K8s YAML** — maximum transparency; every resource is exactly what Kubernetes receives; no abstraction layer; Kustomize for environment overlays
- **Helm** — industry-standard templating; single chart parameterised per service/environment; more abstraction but less visual clarity

The initial priority was learning clarity: new team members (and students) should be able to read any manifest and understand exactly what Kubernetes will create, without knowing Helm syntax.

## Decision

Use **plain Kubernetes YAML** with Kustomize overlays for environment-specific differences (dev vs prod replica counts, resource limits, image tags). Each service gets a directory under `k8s/base/{service}/` with `deployment.yaml`, `service.yaml`, `configmap.yaml`, and `serviceaccount.yaml`. Overlays at `k8s/overlays/dev/` and `k8s/overlays/prod/` patch the base.

## Consequences

**Positive (at time of decision):**
- Zero abstraction: manifests are exactly what Kubernetes receives
- No Helm knowledge required to read or modify manifests
- Kustomize is built into `kubectl apply -k` — no additional tooling
- Easy to grep for any field across all service manifests

**Negative (led to supersession):**
- With 8 services × 2 environments, Kustomize overlays grew to ~130+ YAML files
- 90% duplication between service Deployments — only ports, env vars, and resource limits differ
- ArgoCD's Helm support is first-class; Kustomize integration is secondary
- No standard way to conditionally include HPA or PDB without duplicating the full resource
- Per-service patch files became as complex as templates, negating the "transparency" benefit

## Superseded By

**ADR-0007 (Helm over plain K8s YAML)** — adopted when E-16 was started. The generic Helm chart (`helm/petclinic-service/`) replaced all per-service manifests. Per-service differences are now expressed as `helm-values/{service}.yaml` files. ADR-0007 documents the rationale for the change in detail.

## Historical Note

The `k8s/base/` directory still exists for manifests that are NOT Helm-managed: namespaces, ingress, external-secrets CRs, and observability manifests. These remain as plain YAML because they are cluster-wide or tooling-level resources, not application services.
