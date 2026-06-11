# Onboarding Guide

**Last Updated:** 2026-06-09

Get a new engineer productive with the Petclinic platform in under 90 minutes.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Repository Setup](#repository-setup)
3. [Connect to the Cluster](#connect-to-the-cluster)
4. [Explore the Running Application](#explore-the-running-application)
5. [View Dashboards and Logs](#view-dashboards-and-logs)
6. [Make a Change and Deploy](#make-a-change-and-deploy)
7. [Key Reference Points](#key-reference-points)

---

## Prerequisites

**Estimated time: 20 min**

Install the following tools before starting.

### Required tools

```bash
# AWS CLI v2
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
aws --version  # expect: aws-cli/2.x.x

# kubectl
# https://kubernetes.io/docs/tasks/tools/
kubectl version --client  # expect: v1.29+

# Helm v3
# https://helm.sh/docs/intro/install/
helm version  # expect: v3.x.x

# Terraform v1.7+
# https://developer.hashicorp.com/terraform/install
terraform version  # expect: v1.7+

# ArgoCD CLI (optional but helpful)
# https://argo-cd.readthedocs.io/en/stable/cli_installation/
argocd version --client
```

### AWS access

You need an IAM user or role with permission to:
- `eks:DescribeCluster` + `eks:AccessKubernetesApi`
- Read access to Secrets Manager (`petclinic/dev/*`)
- Read access to ECR (`petclinic-dev/*`)

Configure your AWS credentials:

```bash
aws configure
# AWS Access Key ID: xxxxxx
# AWS Secret Access Key: xxxxxx
# Default region name: eu-central-1
# Default output format: json

# Verify
aws sts get-caller-identity
```

---

## Repository Setup

**Estimated time: 5 min**

### Fork and clone

1. Fork this platform repo to your GitHub account.
2. Fork `https://github.com/paharipratyush/spring-petclinic-microservices` (the app fork that already has `build-push.yml` pre-configured for this platform).
3. In your microservices fork, edit `.github/workflows/build-push.yml` **line 247** — change `paharipratyush/petclinic-platform` to `<YOUR_USERNAME>/petclinic-platform`:
   ```yaml
   repository: <YOUR_USERNAME>/petclinic-platform   # line 247 in build-push.yml
   ```

```bash
git clone https://github.com/<YOUR_GITHUB_USERNAME>/petclinic-platform.git
cd petclinic-platform

# Review the structure
ls -la
# Key directories:
#   terraform/         — all AWS infrastructure (IaC)
#   helm/              — shared Helm chart for all 8 services
#   helm-values/       — per-service and per-env values
#   k8s/               — namespaces, ArgoCD apps, observability
#   .github/workflows/ — update-image-tags.yml only (build-push.yml is in the application repo fork)
#   docs/              — this file + architecture, runbooks, ADRs
#   scripts/           — operational scripts

# Read the project instructions
cat CLAUDE.md
```

### Set environment variables and bootstrap Terraform state

```bash
# Required — Cloudflare API token (Zone:Read + DNS:Edit on your domain)
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"

# Required — passed without storing secrets in files
export TF_VAR_domain_name="yourdomain.com"
export TF_VAR_openai_api_key="sk-..."
export TF_VAR_grafana_admin_password="YourPassword!"
export TF_VAR_budget_alert_email="you@example.com"

# One-time: create S3 bucket + DynamoDB for Terraform state
bash scripts/bootstrap-state.sh dev

# Copy the example tfvars and fill in non-secret values
cp terraform/environments/dev/terraform.tfvars.example terraform/environments/dev/terraform.tfvars
# Edit terraform.tfvars: set domain_name and github_repo

# Deploy everything
bash scripts/up.sh --env dev
```

### GitHub Secrets setup (app repo fork)

After `terraform apply` succeeds, set these secrets in your **microservices fork** on GitHub:

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | output from `terraform output github_actions_role_arn` |
| `AWS_REGION` | `eu-central-1` |
| `ECR_REGISTRY` | output from `terraform output ecr_registry` |
| `PLATFORM_REPO_TOKEN` | GitHub PAT (repo scope) for dispatching to your platform repo fork |

---

## Connect to the Cluster

**Estimated time: 5 min**

```bash
# Update kubeconfig to point to the dev cluster
aws eks update-kubeconfig \
  --region eu-central-1 \
  --name petclinic-dev

# Verify
kubectl get nodes
# Expected: 4× Ready nodes (t4g.small ARM64)

kubectl get pods -n petclinic-dev
# Expected: 8 pods, all 1/1 Running (startup order: config, discovery, then others)
```

### Granting cluster access to additional users

The EKS cluster uses EKS access entries (not `aws-auth` ConfigMap). To grant another IAM user or role cluster-admin access, add their ARN to the `admin_iam_arns` variable in the environment's Terraform:

```hcl
# terraform/environments/dev/terraform.tfvars
admin_iam_arns = [
  "arn:aws:iam::{YOUR_ACCOUNT_ID}:user/alice",
  "arn:aws:iam::{YOUR_ACCOUNT_ID}:role/engineer-role",
]
```

Then apply:

```bash
cd terraform/environments/dev
terraform plan -out plan.out
terraform apply plan.out
```

The caller identity that ran the last `terraform apply` always has access automatically — no need to add it explicitly. The same variable exists in `terraform/environments/prod/terraform.tfvars`.

---

## Explore the Running Application

**Estimated time: 10 min**

### Check all services are healthy

```bash
kubectl get pods -n petclinic-dev -o wide
# All pods should be 1/1 Running

# Check Eureka — all 8 services should be registered
kubectl port-forward svc/discovery-server -n petclinic-dev 8761:8761 &
open http://localhost:8761
```

### Access the Petclinic UI

The public URL is `https://petclinic-dev.<YOUR_DOMAIN>` (requires DNS + ALB, set via `TF_VAR_domain_name`).

For local access via port-forward:

```bash
kubectl port-forward svc/api-gateway -n petclinic-dev 8080:8080 &
open http://localhost:8080
# Browse: Owners, Pets, Vets — verify data loads from RDS
```

### Inspect a service's configuration

```bash
# View environment variables injected into a running pod
kubectl exec -n petclinic-dev deployment/api-gateway -- env | sort

# Check mounted secrets (from External Secrets Operator)
kubectl get externalsecret -n petclinic-dev
```

---

## View Dashboards and Logs

**Estimated time: 15 min**

### Grafana (metrics + log exploration)

```bash
kubectl port-forward svc/grafana -n monitoring 3000:3000 &
open http://localhost:3000
# Login: admin / petclinic-admin
#
# Dashboards → Petclinic folder:
#   "Petclinic — Service Overview"     — all services at a glance
#   "Petclinic — Per-Service Metrics"  — select a service from dropdown
#   "Petclinic — JVM Metrics"          — heap, GC, threads
#
# Explore → Loki datasource:
#   {namespace="petclinic-dev"} |= "ERROR"   — all errors
#   {namespace="petclinic-dev", app="api-gateway"}  — one service
```

### Prometheus (raw metrics + alerts)

```bash
kubectl port-forward svc/prometheus -n monitoring 9090:9090 &
open http://localhost:9090
# Status → Targets: all 5 scrape targets should be "up"
# Alerts tab: shows active alert rules
```

### Zipkin (distributed traces)

```bash
kubectl port-forward svc/zipkin -n tracing 9411:9411 &
open http://localhost:9411
# Find Traces → select a service → view cross-service spans
```

### Alertmanager

```bash
kubectl port-forward svc/alertmanager -n monitoring 9093:9093 &
open http://localhost:9093
# Shows active alerts and silences
```

### Logs via kubectl

```bash
# Follow logs for a service
kubectl logs -n petclinic-dev -l app.kubernetes.io/name=api-gateway -f

# Get logs from a crashed pod
kubectl logs -n petclinic-dev {pod-name} --previous
```

---

## Make a Change and Deploy

**Estimated time: 20 min**

The platform uses GitOps: push to `main` → ArgoCD auto-syncs to the dev cluster.

### Example: Change a log level

```bash
# Edit the Helm values for a service
vim helm-values/api-gateway.yaml
# Add under env: LOGGING_LEVEL_ROOT: DEBUG

git add helm-values/api-gateway.yaml
git commit -m "chore: increase api-gateway log level for debugging"
git push origin main
```

ArgoCD detects the change within ~3 minutes (default polling interval) and applies it:

```bash
# Watch the rollout happen
kubectl rollout status deployment/api-gateway -n petclinic-dev

# Or force an immediate sync via ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8443:443 &
argocd app sync api-gateway-dev --auth-token $(argocd account generate-token)
```

### Example: Scale a service

```bash
# Dev uses 1 replica by default (set in helm-values/dev.yaml)
# Override for testing by editing helm-values/dev.yaml:
# replicaCount: 2

# Or scale directly (not GitOps-persisted, ArgoCD will revert on next sync):
kubectl scale deployment/api-gateway -n petclinic-dev --replicas=2
```

### Example: Check that a new image was deployed

After a CI run pushes a new image:

```bash
# The CI pipeline commits the new image tag to helm-values/{service}.yaml
git log --oneline helm-values/api-gateway.yaml

# ArgoCD syncs the new tag; verify the pod image
kubectl get pod -n petclinic-dev -l app.kubernetes.io/name=api-gateway \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

---

## Key Reference Points

| Topic | Where to look |
|-------|---------------|
| Architecture decisions | `docs/adr/` — numbered decision records |
| Infrastructure values | `docs/technical-spec.md` |
| Day-2 operations | `docs/runbook.md` |
| Failure diagnosis | `docs/incident-playbook.md` |
| Observability access | `docs/monitoring-guide.md` |
| Helm chart conventions | `docs/helm-guide.md` |
| Terraform modules | `terraform/modules/{vpc,eks,ecr,rds,dns,secrets}` |
| Per-service config | `helm-values/{service}.yaml` |
| ArgoCD application CRDs | `k8s/argocd/applications/{dev,prod}/` |
| CI (build+push) | `build-push.yml` in **application repo fork** |
| CI (tag update) | `.github/workflows/update-image-tags.yml` |
| Safety hooks | `.claude/settings.local.json` |

### Useful aliases

```bash
alias k='kubectl'
alias kdev='kubectl -n petclinic-dev'
alias km='kubectl -n monitoring'

# Port-forward all observability tools at once
kubectl port-forward svc/grafana -n monitoring 3000:3000 &
kubectl port-forward svc/prometheus -n monitoring 9090:9090 &
kubectl port-forward svc/zipkin -n tracing 9411:9411 &
```
