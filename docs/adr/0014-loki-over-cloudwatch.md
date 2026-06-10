# ADR-0014: In-Cluster Logging (Loki + FluentBit) over CloudWatch Logs

**Status:** Accepted
**Date:** 2026-06-09
**PETPLAT:** PETPLAT-59, E-11

---

## Context

The platform needs centralized log aggregation for all 8 Spring Petclinic services. Two main approaches exist for EKS workloads:

**AWS CloudWatch Logs:**
- AWS-native log aggregation via CloudWatch Logs Insights
- Requires FluentBit DaemonSet with CloudWatch output plugin + IRSA role (IAM permissions)
- Per-GB ingestion cost: ~$0.50/GB; per-GB storage: ~$0.03/GB/month
- UI: CloudWatch Logs Insights (SQL-like queries)
- Requires AWS Console access to view logs
- No Grafana integration without additional tooling (e.g., Grafana CloudWatch datasource)

**Loki + FluentBit (in-cluster):**
- Grafana-native log aggregation via LogQL
- No AWS IAM roles required (Loki runs inside EKS, FluentBit outputs to cluster-internal URL)
- Storage: EBS PVC within EKS cluster (included in EBS costs, ~$0.10/GB/month)
- UI: Grafana Explore with Loki datasource (same Grafana that shows metrics)
- LogQL is purpose-built for log queries (label filtering, parsing, patterns)
- Tight Grafana/Prometheus integration: correlate logs and metrics in one dashboard

---

## Decision

Use **Loki + FluentBit** for log aggregation, deployed in-cluster.

- **Loki** (`grafana/loki:2.9.8`) deployed to the `monitoring` namespace with a 10Gi EBS PVC, 7-day retention, and boltdb-shipper storage.
- **FluentBit DaemonSet** collects container logs from `/var/log/containers/*.log` on every node and forwards to `http://loki.monitoring:3100`.
- **No IRSA role needed**: FluentBit uses HTTP to push to Loki (no AWS API calls).
- **Log alerting**: Loki ruler evaluates LogQL alert rules (error spike, OOM) and routes to Alertmanager.

---

## Consequences

### Positive

- **$0 incremental cost**: Log storage is included in EBS PVC cost, which is already needed for Prometheus. No per-GB CloudWatch ingestion charges.
- **Single pane of glass**: Engineers use the same Grafana instance for both metrics and logs, with correlation features (click a metric spike → see logs at that time).
- **No IAM complexity**: No IRSA role, no CloudWatch-specific permissions, no IAM policy boundaries to manage.
- **LogQL is expressive**: Filter by labels, parse JSON fields, aggregate counts — more log-aware than CloudWatch Logs Insights.
- **Simpler FluentBit config**: HTTP output to an in-cluster endpoint, no AWS credentials.

### Negative / Watch out for

- **Pod density constraint (dev)**: Loki runs as a pod. On t4g.small with 11-pod ENI limit, the observability stack (6 components) requires a dedicated node. Resolved by scaling to 4 nodes or enabling VPC CNI prefix delegation.
- **No cross-region or cross-account**: CloudWatch Logs can aggregate from multiple accounts; Loki is cluster-local.
- **Manual backup**: EBS PVC data is not replicated. In the event of EBS volume failure, logs for the current 7-day window may be lost. Prometheus/Loki data is operational telemetry (not business-critical), so this is acceptable.
- **Loki scalability**: Single-binary Loki mode (`-target=all`) is appropriate for dev/small clusters. For prod with high log volume, Loki should be deployed in microservices mode or replaced with Loki Distributed.

### When to revisit

- If log volume exceeds ~5GB/day: evaluate Loki Distributed or S3-backed storage
- If compliance requires immutable audit logs with retention > 90 days: supplement with CloudWatch Logs Insights or S3 archival
- If multi-cluster or multi-account visibility is needed: consider a centralized Grafana + Loki aggregator

---

## Related

- ADR-0011: Secrets Manager + ESO (no CloudWatch dependency for secrets)
- PETPLAT-59: Loki + FluentBit deployment story
- `k8s/base/observability/loki.yaml` — Loki deployment
- `k8s/base/observability/fluentbit.yaml` — FluentBit DaemonSet
