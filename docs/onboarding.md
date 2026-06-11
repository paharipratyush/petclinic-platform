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

### What `up.sh` Does (Behind the Scenes)

`up.sh` is the master bootstrap script. Understanding what it does helps you diagnose failures and know what state the cluster is in at each stage:

1. **Terraform apply** (~15 min) — Creates VPC, EKS cluster, RDS database, ECR repos, IAM roles, Karpenter SQS queue, Cloudflare DNS records, ACM certificate.
2. **ECR registry update** — Reads `terraform output ecr_registry_url` and updates `helm-values/dev.yaml` with your account-specific ECR URL, then commits and pushes to Git.
3. **kubectl config** — Runs `aws eks update-kubeconfig` so subsequent `kubectl` commands hit the new cluster.
4. **ArgoCD install** — Applies the ArgoCD manifest to the `argocd` namespace and waits for all deployments to be `Available`. This is the GitOps controller that manages all your apps.
5. **Karpenter install** — Helm-installs Karpenter (node autoscaler) and applies the `NodePool` + `EC2NodeClass` CRDs. Also installs `metrics-server` (needed for HPA).
6. **External Secrets Operator install** — Helm-installs ESO with your IRSA role ARN. ESO syncs AWS Secrets Manager secrets → K8s Secrets. Services will not start until ESO is running.
7. **ArgoCD Application CRDs** — Applies the 8 ArgoCD Application manifests for the env. ArgoCD starts watching `helm-values/` for each service. (Images are not in ECR yet — pods will be in `ImagePullBackOff` until you run step 6 of the Quick Start.)
8. **ALB Controller + Ingress** — Installs the AWS Load Balancer Controller and creates the Ingress resource. The ALB is provisioned and a CNAME is created in Cloudflare pointing `petclinic-{env}.yourdomain.com` → ALB.
9. **Observability stack** — Applies Prometheus, Grafana, Loki, FluentBit, Zipkin, and Alertmanager manifests to the `monitoring` and `tracing` namespaces.

**If `up.sh` fails partway through:** The script is idempotent — most steps check whether resources already exist before creating them. You can re-run `bash scripts/up.sh --env dev` safely. If Terraform fails, check `terraform/environments/dev/` for partial state or run `terraform plan` manually to see what's missing.

---

### GitHub Secrets setup (app repo fork)

After `terraform apply` succeeds, set these secrets in your **microservices fork** on GitHub (Settings → Secrets and variables → Actions → New repository secret):

| Secret | How to get the value | Why it's needed |
|--------|----------------------|-----------------|
| `AWS_ROLE_ARN` | `terraform -chdir=terraform/environments/dev output github_actions_role_arn` | GitHub Actions assumes this IAM role via OIDC federation — no static AWS keys needed. The role has ECR push permissions. |
| `AWS_REGION` | `eu-central-1` | Tells the AWS CLI and Docker which region's ECR to authenticate against. |
| `ECR_REGISTRY` | `terraform -chdir=terraform/environments/dev output ecr_registry_url` | The account-specific ECR base URL used to tag and push images (e.g., `123456789.dkr.ecr.eu-central-1.amazonaws.com`). |
| `PLATFORM_REPO_TOKEN` | Create a GitHub PAT: Settings → Developer settings → Personal access tokens → `repo` scope | After pushing images to ECR, `build-push.yml` fires `repository_dispatch` to the platform repo's `update-image-tags.yml`. This PAT authenticates that cross-repo call. |

> **About OIDC vs static keys:** The `AWS_ROLE_ARN` secret enables [GitHub OIDC federation](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect) — GitHub Actions exchanges a short-lived OIDC token for temporary AWS credentials. No long-lived AWS keys are stored in GitHub. See [ADR-0005](../adr/0005-github-actions-oidc.md) for the rationale.

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

## Troubleshooting

### `terraform apply` fails with `AccessDenied`

Your AWS identity lacks required permissions. Verify which identity is being used:

```bash
aws sts get-caller-identity
```

The caller needs permissions to create EKS clusters, RDS instances, VPCs, IAM roles, and Secrets Manager secrets. If using an IAM user, attach `AdministratorAccess` for initial setup (scope down after).

### Pods are in `ImagePullBackOff`

ECR repositories are empty after a fresh install. Trigger a full image build:

```
App repo fork → GitHub Actions → "CI - Build and Push" → Run workflow → force_rebuild_all=true
```

Wait ~10 minutes for ARM64 builds to complete and push to ECR. ArgoCD in dev will auto-sync within ~10 seconds of images being available.

### `up.sh` fails on the ArgoCD step

Check whether ArgoCD pods are pending due to insufficient capacity:

```bash
kubectl get pods -n argocd
kubectl describe pod -n argocd <pending-pod>  # look for "Insufficient cpu/memory"
```

If nodes haven't joined yet, wait ~2 minutes and retry. If the node group is stuck, check EC2 Auto Scaling in the AWS console.

### Services are `OutOfSync` in ArgoCD

This usually means the Helm values on disk differ from what ArgoCD last applied. Check the diff and sync:

```bash
# Via port-forward
kubectl port-forward svc/argocd-server -n argocd 8443:443 &
argocd login localhost:8443 --insecure

argocd app diff api-gateway-dev      # show what would change
argocd app sync api-gateway-dev      # apply the change
```

### Config-server or discovery-server pods are `CrashLoopBackOff`

These services do not use RDS, so it is not a database issue. Check:

```bash
kubectl logs -n petclinic-dev deployment/config-server
```

Common causes: ECR image not yet available (run CI first), or Secrets Manager secret not yet created (run `terraform apply` first).

### ExternalSecret shows `SecretSyncedError`

ESO cannot read from Secrets Manager. Check the IRSA role trust policy and ESO's service account annotation:

```bash
kubectl describe externalsecret -n petclinic-dev
kubectl get sa external-secrets -n external-secrets -o yaml | grep amazonaws
```

The ESO service account must have `eks.amazonaws.com/role-arn` pointing to the `petclinic-dev-eso-role`. Re-run `bash scripts/install-eso.sh dev` if the annotation is missing.

### `smoke-test.sh` fails with `Connection refused`

The ALB may not have propagated yet (DNS TTL + ALB provisioning takes ~3-5 minutes after `up.sh` completes). Wait and retry:

```bash
# Check ALB state
kubectl get ingress -n petclinic-dev
# "ADDRESS" column should show an ALB DNS name like xxx.eu-central-1.elb.amazonaws.com

# Check Cloudflare CNAME
curl -s "https://dns.google/resolve?name=petclinic-dev.yourdomain.com&type=CNAME" | jq .
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
