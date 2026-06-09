# Petclinic Platform — Monitoring & Observability Guide

**Last Updated:** 2026-06-09
**Purpose:** How to use the observability stack to monitor the Petclinic microservices: what to look at, how to query, and how to interpret what you see.

## Table of Contents

1. [Stack Overview](#stack-overview)
2. [Accessing the Tools (Port-Forwards)](#accessing-the-tools-port-forwards)
3. [Prometheus — Metrics](#prometheus--metrics)
4. [Grafana — Dashboards & Log Exploration](#grafana--dashboards--log-exploration)
5. [Loki — Log Aggregation](#loki--log-aggregation)
6. [FluentBit — Log Shipping](#fluentbit--log-shipping)
7. [Alertmanager — Alert Routing](#alertmanager--alert-routing)
8. [Zipkin — Distributed Tracing](#zipkin--distributed-tracing)
9. [Alert Rules Reference](#alert-rules-reference)
10. [Verifying the Stack End-to-End](#verifying-the-stack-end-to-end)
11. [Silencing and Managing Alerts](#silencing-and-managing-alerts)
12. [Adding or Modifying Alert Rules](#adding-or-modifying-alert-rules)
13. [Enabling Email Alerts](#enabling-email-alerts)

---

## Stack Overview

| Component | Namespace | Port | Purpose |
|-----------|-----------|------|---------|
| Prometheus | `monitoring` | 9090 | Scrapes metrics from 5 services every 15s |
| Grafana | `monitoring` | 3000 | Dashboards + log exploration (Prometheus + Loki datasources) |
| Loki | `monitoring` | 3100 | Log aggregation backend |
| FluentBit | `monitoring` | 2020 | DaemonSet: reads container logs, forwards to Loki |
| Alertmanager | `monitoring` | 9093 | Routes Prometheus + Loki alerts to email |
| Zipkin | `tracing` | 9411 | Distributed tracing UI |

**What is NOT scraped by Prometheus:** `config-server`, `discovery-server`, and `admin-server` do not include `micrometer-registry-prometheus` in their pom.xml, so they do not expose `/actuator/prometheus`. Only the 5 application services (api-gateway, customers-service, visits-service, vets-service, genai-service) export Prometheus metrics.

**Tracing:** Services send traces automatically to `http://zipkin.tracing:9411/api/v2/spans` via the `MANAGEMENT_ZIPKIN_TRACING_ENDPOINT` env var (set in `helm-values/dev.yaml`). Sampling is 100% (`MANAGEMENT_TRACING_SAMPLING_PROBABILITY=1.0`).

---

## Accessing the Tools (Port-Forwards)

Run these in separate terminals while working with the cluster:

```bash
# Grafana — main UI (dashboards + logs)
kubectl port-forward svc/grafana -n monitoring 3000:3000
# http://localhost:3000  (admin / petclinic-admin)

# Prometheus — metrics + alert status
kubectl port-forward svc/prometheus -n monitoring 9090:9090
# http://localhost:9090/targets  ← scrape status
# http://localhost:9090/alerts   ← alert rules and firing alerts

# Alertmanager — active alerts + silences
kubectl port-forward svc/alertmanager -n monitoring 9093:9093
# http://localhost:9093

# Zipkin — distributed traces
kubectl port-forward svc/zipkin -n tracing 9411:9411
# http://localhost:9411
```

---

## Prometheus — Metrics

### Check Scrape Status

```bash
kubectl port-forward svc/prometheus -n monitoring 9090:9090
# http://localhost:9090/targets
```

**Expected:** 5 targets, all `UP`:
- `api-gateway.petclinic-dev:8080`
- `customers-service.petclinic-dev:8081`
- `visits-service.petclinic-dev:8082`
- `vets-service.petclinic-dev:8083`
- `genai-service.petclinic-dev:8084`

**If a target shows DOWN:** The service pod is not running or the `/actuator/prometheus` endpoint is unreachable.
```bash
kubectl get pods -n petclinic-dev
kubectl logs <pod-name> -n petclinic-dev --tail=50
```

### Useful Prometheus Queries

```promql
# Is service up?
up{job="api-gateway"}

# Request rate (req/s over last 5 min)
rate(http_server_requests_seconds_count{job="customers-service"}[5m])

# 5xx error rate
rate(http_server_requests_seconds_count{job="api-gateway",status=~"5.."}[5m])
/ rate(http_server_requests_seconds_count{job="api-gateway"}[5m])

# p95 latency
histogram_quantile(0.95, rate(http_server_requests_seconds_bucket{job="vets-service"}[5m]))

# JVM heap usage
jvm_memory_used_bytes{job="customers-service", area="heap"}

# Pod restart count (requires kube-state-metrics — not installed by default)
increase(kube_pod_container_status_restarts_total[15m])
```

---

## Grafana — Dashboards & Log Exploration

**Login:** http://localhost:3000 → username: `admin` / password: `petclinic-admin`

> **Change the password** on first login: Profile → Change Password.

### Dashboards

Navigate to **Dashboards → Petclinic** folder. Three dashboards are provisioned automatically:

| Dashboard | What it shows |
|-----------|---------------|
| **Petclinic — Service Overview** | Up/Down status for all 5 monitored services; request rate, error rate, p95 latency across all services |
| **Petclinic — Per-Service Metrics** | Select a service from the top dropdown; request rate by endpoint, error rate, p50/p90/p95/p99 latency |
| **Petclinic — JVM Metrics** | Select a service; heap/non-heap memory, GC pause duration, thread count, CPU usage |

### Exploring Logs in Grafana (Loki)

1. Left sidebar → **Explore** (compass icon)
2. Select datasource **Loki** (top-left dropdown)
3. Use the **Log Browser** or type a LogQL query

```logql
# All logs from petclinic-dev namespace
{namespace="petclinic-dev"}

# Logs from a specific service
{namespace="petclinic-dev", container="customers-service"}

# ERROR logs only
{namespace="petclinic-dev"} |= "ERROR"

# Filter by pod name
{pod=~"api-gateway.*"}

# Stack traces (multi-line)
{namespace="petclinic-dev"} |= "Exception"

# Error rate over time
rate({namespace="petclinic-dev"} |= "ERROR" [5m])
```

4. Set the time range (top right) — last 15m is a good default for live debugging.

---

## Loki — Log Aggregation

Loki receives logs from FluentBit and stores them with labels:
- `namespace` — Kubernetes namespace (`petclinic-dev`, `monitoring`, etc.)
- `pod` — Pod name
- `container` — Container name

**Health check:**
```bash
kubectl port-forward svc/loki -n monitoring 3100:3100
curl http://localhost:3100/ready
# Expected: "ready"
```

**Loki alert rules** are mounted from `loki-alert-rules` ConfigMap at `/loki/rules/fake/`. They are evaluated by the Loki ruler and routed to Alertmanager:

| Alert | Condition |
|-------|-----------|
| `LogErrorSpike` | ERROR log rate > 0.5/s for 5 minutes |
| `JVMOutOfMemory` | Any `OutOfMemoryError` in logs |

---

## FluentBit — Log Shipping

FluentBit runs as a **DaemonSet** (one pod per node). It reads container logs from `/var/log/containers/*.log`, enriches them with Kubernetes metadata, and forwards them to Loki.

**Check FluentBit is running:**
```bash
kubectl get daemonset fluent-bit -n monitoring
# Expected: DESIRED = CURRENT = READY (one per node)

kubectl logs -l app.kubernetes.io/name=fluent-bit -n monitoring --tail=30
# Look for: "flush successfully" and "Loki" output entries
```

**Verify logs are arriving in Loki:**
```bash
# In Grafana Explore → Loki
{namespace="petclinic-dev"}
# If any petclinic pods are running, logs should appear here
```

---

## Alertmanager — Alert Routing

Alertmanager receives alerts from both Prometheus (metric alerts) and Loki (log-based alerts) and routes them by severity.

**Access:** http://localhost:9093

### Routing Logic

```
All alerts → email-default (warning/default)
              └─ severity=critical → email-critical (immediate, 1h repeat)
```

**Critical alerts:** `ServiceDown`, `PodRestartLoop`, `JVMOutOfMemory` — sent immediately, repeated every 1h.
**Warning alerts:** `HighErrorRate`, `HighLatency`, `HighMemoryUsage`, `LogErrorSpike` — grouped, sent every 5m.

### Check Alert Status

```bash
kubectl port-forward svc/alertmanager -n monitoring 9093:9093
# http://localhost:9093 → shows currently firing alerts
```

Or check via Prometheus:
```bash
# http://localhost:9090/alerts
# Shows: alert rules, their state (inactive / pending / firing)
```

### Test an Alert (fire manually)

```bash
# Send a test alert directly to Alertmanager
curl -X POST http://localhost:9093/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[{
    "labels": {"alertname":"TestAlert","severity":"warning","job":"test"},
    "annotations": {"summary":"Manual test alert"},
    "startsAt": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
  }]'
```

---

## Zipkin — Distributed Tracing

Zipkin captures trace data from services instrumented with Spring Cloud Sleuth / OpenTelemetry. Each incoming request to the API Gateway creates a trace that propagates through all downstream services.

**Access:** http://localhost:9411

### Finding Traces

1. Open http://localhost:9411
2. **Find a trace:** Select service from the dropdown (e.g., `spring-petclinic-api-gateway`)
3. Click **Run Query** — shows recent traces
4. Click a trace to see the waterfall view: which services were called, in what order, and how long each took

### What to look for

| Signal | What it means |
|--------|---------------|
| Long root span | API Gateway overhead (routing, circuit breaker) |
| Long child span | A specific backend service is slow |
| Error span (red) | Service returned an error on this request |
| Missing child spans | Downstream service wasn't called — may indicate circuit breaker tripped |

### Verify traces are being sent

If traces don't appear in Zipkin, check:
```bash
# Confirm the env var is set in a running pod
kubectl exec -n petclinic-dev deployment/api-gateway -- env | grep ZIPKIN
# Expected: MANAGEMENT_ZIPKIN_TRACING_ENDPOINT=http://zipkin.tracing:9411/api/v2/spans

# Check Zipkin service is reachable from petclinic-dev namespace
kubectl run -it --rm debug --image=curlimages/curl:8.7.1 -n petclinic-dev \
  -- curl -s http://zipkin.tracing:9411/health
# Expected: {"status":"UP"}
```

---

## Alert Rules Reference

### Prometheus Rules

| Alert | Expression | Duration | Severity |
|-------|-----------|----------|----------|
| `ServiceDown` | `up == 0` | 1m | critical |
| `HighErrorRate` | 5xx rate > 5% | 5m | warning |
| `HighLatency` | p95 latency > 500ms | 5m | warning |
| `PodRestartLoop` | > 3 restarts in 15m | immediate | critical |
| `HighMemoryUsage` | memory > 80% of limit | 5m | warning |

> **Note:** `PodRestartLoop` and `HighMemoryUsage` require `kube-state-metrics` and `cAdvisor` metrics respectively. If these don't fire as expected, install kube-state-metrics via Helm: `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm install kube-state-metrics prometheus-community/kube-state-metrics -n monitoring`.

### Loki Rules

| Alert | LogQL Expression | Duration | Severity |
|-------|----------------|----------|----------|
| `LogErrorSpike` | ERROR rate > 0.5/s in `petclinic-.*` | 5m | warning |
| `JVMOutOfMemory` | Any `OutOfMemoryError` in `petclinic-.*` | immediate | critical |

---

## Verifying the Stack End-to-End

Run this quick health check after deploying or after any cluster changes:

```bash
# 1. All monitoring pods running
kubectl get pods -n monitoring
kubectl get pods -n tracing
kubectl get daemonset fluent-bit -n monitoring

# 2. Prometheus scraping (5 targets should be UP)
kubectl port-forward svc/prometheus -n monitoring 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/targets' \
  | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
kill %1

# 3. Loki ready
kubectl port-forward svc/loki -n monitoring 3100:3100 &
sleep 2
curl -s http://localhost:3100/ready
kill %1

# 4. FluentBit logs flowing to Loki
kubectl logs -l app.kubernetes.io/name=fluent-bit -n monitoring --tail=5 2>/dev/null \
  | grep -c "loki" || echo "Check FluentBit logs manually"

# 5. Zipkin healthy
kubectl port-forward svc/zipkin -n tracing 9411:9411 &
sleep 2
curl -s http://localhost:9411/health | jq .status
kill %1
```

Expected output for a healthy stack:
- All pods `1/1 Running`
- 5 Prometheus targets, all `"health": "up"`
- Loki: `"ready"`
- Zipkin: `"UP"`

---

## Silencing and Managing Alerts

### Silence an Alert in Alertmanager

Silences suppress notifications for a matching alert without deleting the rule. Use during maintenance windows or while investigating a known issue.

```bash
# Open Alertmanager UI
kubectl port-forward svc/alertmanager -n monitoring 9093:9093
# http://localhost:9093 → Silences → + New Silence
# Set: Matchers (e.g., alertname=HighLatency), Start/End time, Comment
```

To create a silence via API (2-hour window for HighLatency):
```bash
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u -d "+2 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
     || date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)  # Linux / macOS

curl -X POST http://localhost:9093/api/v2/silences \
  -H 'Content-Type: application/json' \
  -d "{
    \"matchers\": [{\"name\":\"alertname\",\"value\":\"HighLatency\",\"isRegex\":false}],
    \"startsAt\": \"${START}\",
    \"endsAt\": \"${END}\",
    \"comment\": \"Maintenance window — scaling up nodes\",
    \"createdBy\": \"ops-engineer\"
  }"
# Returns: {"silenceID":"<uuid>"}
```

To list and expire an existing silence:
```bash
# List active silences
curl -s http://localhost:9093/api/v2/silences | jq '.[].id'

# Expire (delete) a silence
curl -X DELETE http://localhost:9093/api/v2/silence/{silenceID}
```

**Acknowledgement:** Alertmanager has no native "acknowledge" concept. A short silence (1 hour) serves the same purpose — it stops repeat pages while the on-call engineer investigates.

---

## Adding or Modifying Alert Rules

### Prometheus Rules

Alert rules are defined in the `prometheus-alerts` ConfigMap inside `k8s/base/observability/prometheus.yaml`. Prometheus hot-reloads rules from the mounted ConfigMap without a restart.

1. Edit the ConfigMap in `k8s/base/observability/prometheus.yaml`, find the `groups[0].rules` list, and add a rule:

   ```yaml
   - alert: MyNewAlert
     expr: <promql_expression>
     for: 5m
     labels:
       severity: warning      # critical | warning
     annotations:
       summary: "Short description"
       description: "Longer description with {{ $labels.job }}"
   ```

2. Apply and verify:
   ```bash
   kubectl apply -f k8s/base/observability/prometheus.yaml
   # Wait ~30s for Prometheus to reload
   kubectl port-forward svc/prometheus -n monitoring 9090:9090
   # http://localhost:9090/rules  ← new rule should appear
   # http://localhost:9090/alerts ← shows state: inactive / pending / firing
   ```

### Loki Alert Rules

Loki alert rules are in the `loki-alert-rules` ConfigMap inside `k8s/base/observability/loki.yaml`.

1. Add a rule under `groups[0].rules`:

   ```yaml
   - alert: MyLogAlert
     expr: |
       count_over_time({namespace=~"petclinic-.*"} |= "my-error-pattern" [5m]) > 0
     for: 1m
     labels:
       severity: warning
     annotations:
       summary: "Error pattern detected in petclinic logs"
   ```

2. Apply:
   ```bash
   kubectl apply -f k8s/base/observability/loki.yaml
   # Loki ruler reloads within ~30 seconds
   ```

### Alertmanager Routing Rules

To add a new receiver or routing rule, edit the `alertmanager-config` Secret in `k8s/base/observability/alertmanager.yaml`. The configuration is base64-encoded when deployed; `install-observability.sh` handles encoding. Edit the plain-text source in the script's `ALERTMANAGER_CONFIG` variable, then re-run the install script.

---

## Enabling Email Alerts

The Alertmanager config uses a placeholder SMTP password. To enable real email alerts:

```bash
# 1. Generate a Gmail App Password at https://myaccount.google.com/apppasswords

# 2. Store it in Secrets Manager (optional but recommended)
aws secretsmanager create-secret \
  --name petclinic/alertmanager-smtp \
  --secret-string '{"password":"<your-app-password>"}' \
  --region eu-central-1

# 3. Run the install script with the password
export SMTP_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id petclinic/alertmanager-smtp \
  --query SecretString --output text | jq -r .password)
bash scripts/install-observability.sh --env dev

# 4. Verify the secret was patched
kubectl -n monitoring get secret alertmanager-config -o jsonpath='{.data.alertmanager\.yml}' \
  | base64 -d | grep smtp_auth_password
# Should NOT show "REPLACE_WITH_GMAIL_APP_PASSWORD"
```
