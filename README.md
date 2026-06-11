# Petclinic Platform — AWS Infrastructure

Production AWS infrastructure for [Spring Petclinic Microservices](https://github.com/spring-petclinic/spring-petclinic-microservices) (8 services, Spring Boot, Spring Cloud).

## Repository Structure

```
petclinic-platform/
│
├── terraform/                    # Infrastructure as Code
│   ├── environments/
│   │   ├── dev/                  # Dev environment root module
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   └── backend.tf        # S3 state: petclinic/dev/terraform.tfstate
│   │   └── prod/                 # Prod environment root module
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── backend.tf        # S3 state: petclinic/prod/terraform.tfstate
│   └── modules/                  # Reusable modules
│       ├── vpc/                  # VPC, subnets, IGW, security groups (all-public, no NAT)
│       ├── eks/                  # EKS cluster, node groups, OIDC, IAM
│       ├── ecr/                  # ECR repos (per service per env), lifecycle policies
│       ├── rds/                  # RDS MySQL, subnet group, parameter group, Secrets Manager
│       ├── dns/                  # Cloudflare DNS zone lookup (ACM cert via ACM module)
│       ├── secrets/              # Secrets Manager resources (OpenAI key, Grafana credentials)
│       ├── github-oidc/          # GitHub Actions OIDC federation role
│       ├── karpenter/            # Karpenter IRSA, SQS interruption queue, EventBridge rules
│       └── observability/        # (Observability is deployed as raw K8s manifests — see k8s/base/observability/)
│
├── k8s/                          # Kubernetes Manifests
│   ├── base/                     # Base manifests applied to both envs
│   │   ├── namespaces/           # Namespace definitions + ResourceQuota + LimitRange
│   │   ├── observability/        # Prometheus, Grafana, Loki, FluentBit, Zipkin, Alertmanager
│   │   ├── network-policies/     # Default-deny + per-service allow NetworkPolicies
│   │   └── external-secrets/     # ClusterSecretStore + ExternalSecret CRs
│   └── argocd/                   # ArgoCD installation + RBAC + Application CRDs
│       ├── install/              # ArgoCD namespace + install manifest
│       ├── argocd-rbac-cm.yaml   # RBAC: admin / developer roles, deny-by-default
│       └── applications/
│           ├── dev/              # 8 ArgoCD Application CRDs (auto-sync)
│           └── prod/             # 8 ArgoCD Application CRDs (manual sync)
│
├── helm/                         # Helm Charts
│   └── petclinic-service/        # Generic chart shared by all 8 services
│
├── helm-values/                  # Per-service YAML + per-env overrides (dev.yaml, prod.yaml)
│
├── .github/workflows/            # Platform CI: image tag updates only (build-push.yml is in the application repo fork)
│   └── update-image-tags.yml     # Triggered by repository_dispatch from app repo → commits image tags → ArgoCD deploys
│
├── scripts/                      # Operational scripts
│   ├── bootstrap-state.sh        # Create S3 bucket + DynamoDB for TF state
│   ├── build-push.sh             # Build Docker images and push to ECR
│   ├── ecr-login.sh              # ECR authentication helper
│   ├── install-eso.sh            # Install External Secrets Operator via Helm
│   ├── install-lb-controller.sh  # Install AWS Load Balancer Controller + create CNAME
│   ├── install-observability.sh  # Apply all observability K8s manifests
│   ├── smoke-test.sh             # End-to-end smoke test after deploy
│   ├── up.sh                     # Bootstrap full cluster post-Terraform
│   ├── validate-helm.sh          # Lint + template all 16 Helm releases
│   └── load-tests/
│       └── petclinic-load-test.js  # k6 load test (PETPLAT-102)
│
└── docs/                         # Operational Documentation
    ├── architecture.md           # Infrastructure architecture & component relationships
    ├── runbook.md                # Day-2 operations (deploy, rollback, scale, EKS upgrades, state ops)
    ├── incident-playbook.md      # Severity classification, escalation tiers, RCA template
    ├── onboarding.md             # New engineer setup guide
    ├── monitoring-guide.md       # Dashboards, alerts, SLOs, on-call guide
    ├── secret-rotation.md        # How to rotate each secret type safely
    ├── disaster-recovery.md      # RTO/RPO, backup strategy, full rebuild procedure
    ├── compliance-checklist.md   # Security controls, encryption inventory, IAM roles, review cadence
    ├── helm-guide.md             # Helm chart structure and values hierarchy
    ├── rollback-runbook.md       # Service rollback procedures
    ├── technical-spec.md         # Source of truth for all infrastructure values
    ├── jira-backlog.md           # Epics and task tracking
    └── adr/                      # Architecture Decision Records (ADR-0001 through ADR-0014)
```

## Tech Stack

| Layer | Tool | Details |
|-------|------|---------|
| Cloud | AWS | eu-central-1 |
| IaC | Terraform >= 1.6 | AWS provider ~> 5.0, S3 + DynamoDB state |
| Cluster | Amazon EKS | K8s 1.34, managed node groups, OIDC, Graviton t4g.small (ARM64) |
| Registry | Amazon ECR | One repo per service per env, lifecycle policies, scan-on-push |
| Database | Amazon RDS MySQL 8.0 | Single-AZ both envs (cost optimization), Secrets Manager for credentials |
| DNS | Cloudflare + ACM | Your domain managed via Cloudflare; ACM cert for TLS at ALB (ADR-0013) |
| Secrets | AWS Secrets Manager | External Secrets Operator syncs to K8s Secrets |
| Ingress | AWS ALB Ingress Controller | Public ALB → API Gateway service |
| Observability | Prometheus + Grafana + Loki | Micrometer metrics, dashboards, alerts, log aggregation (ADR-0011) |
| Logging | FluentBit → Loki | Centralized log collection from all pods |
| Tracing | Zipkin | Distributed tracing |
| CI | GitHub Actions | OIDC → AWS (no static keys), build → push ECR → commit image tag |
| CD | ArgoCD | GitOps — auto-sync dev, manual sync prod (ADR-0008) |
| Packaging | Helm | Generic chart per service, per-service + per-env values (ADR-0007) |
| Node Scaling | Karpenter | NodePools, EC2NodeClass, Spot diversification (ADR-0014) |

## Environments

| Environment | K8s Namespace | RDS | EKS Nodes | Deploy Mode |
|-------------|---------------|-----|-----------|------------|
| dev | `petclinic-dev` | db.t4g.micro, single-AZ, no backup | 2× t4g.small | ArgoCD auto-sync |
| prod | `petclinic-prod` | db.t4g.micro, single-AZ, 30-day backup, deletion_protection=true | 2× t4g.small | ArgoCD manual sync |

## How It All Works

This platform uses a **GitOps model** — Git is the single source of truth for what runs in the cluster.

```
Developer pushes code
       │
       ▼
[App repo: build-push.yml]
  Build ARM64 Docker images → Push to ECR → Fire repository_dispatch
       │
       ▼
[Platform repo: update-image-tags.yml]
  Commit new image tag to helm-values/{service}.yaml → Push to Git
       │
       ▼
[ArgoCD] (running inside EKS)
  Detects Git change → Reconciles Helm release → Rolling pod update
       │
       ▼
[EKS] New pods running the new image
  Prometheus scrapes metrics → Grafana dashboards update
  FluentBit ships logs → Loki for querying
  Zipkin collects distributed traces
```

**Why two repos?** The application repo (Spring Petclinic source code) is separate from the platform repo (infrastructure + Helm values). This lets the platform team manage infrastructure without touching application code, and CI in the app repo triggers the platform repo via `repository_dispatch`. See [ADR-0008](docs/adr/0008-argocd-gitops.md) for the full rationale.

**First deploy:** The cluster starts empty (no images in ECR). After `up.sh` finishes, you trigger a manual GitHub Actions run with `force_rebuild_all=true` to build and push all 8 service images for the first time. ArgoCD then syncs automatically in dev. See [docs/architecture.md](docs/architecture.md) for full component details.

---

## Quick Start

### Prerequisites

- git, Terraform >= 1.6, kubectl, helm, argocd CLI
- AWS CLI authenticated with sufficient permissions
- A domain managed via [Cloudflare DNS](https://cloudflare.com) (free account works)
- An [OpenAI API key](https://platform.openai.com) (for the GenAI service)
- **macOS users only:** install GNU sed — `brew install gnu-sed && echo 'export PATH="$(brew --prefix gnu-sed)/libexec/gnubin:$PATH"' >> ~/.zshrc` — the scripts use GNU `sed -i` syntax which differs from BSD sed

> **Estimated cost:** ~$80/month if both dev + prod are left running continuously (EKS control plane + t4g.small nodes + RDS). To minimize cost, run `bash scripts/destroy.sh --env dev` when you are done exploring. See [docs/architecture.md § Monthly Cost Estimate](docs/architecture.md#monthly-cost-estimate) for a line-item breakdown.

### 1 — Fork both repos

```
1. Fork this repo:         https://github.com/paharipratyush/petclinic-platform
   → your fork will be:   https://github.com/<YOUR_USERNAME>/petclinic-platform

2. Fork the application repo: https://github.com/paharipratyush/spring-petclinic-microservices
   (This fork already has build-push.yml pre-configured to build ARM64 images and push to ECR)
   → in your fork, search for `paharipratyush/petclinic-platform` in `.github/workflows/build-push.yml`
     and replace it with `<YOUR_USERNAME>/petclinic-platform`
```

> **Why this edit?** After building images, `build-push.yml` fires a `repository_dispatch` event to the platform repo's `update-image-tags.yml`. The `repository:` field in that step controls which platform repo receives the event. Without this edit, new image tags are pushed to ECR but ArgoCD never learns about them.

### 2 — Set environment variables

```bash
# Required — Cloudflare API token (Zone:Read + DNS:Edit on your domain)
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"

# Required — Terraform variables (passed without storing secrets in files)
export TF_VAR_domain_name="yourdomain.com"        # your Cloudflare-managed domain
export TF_VAR_openai_api_key="sk-..."              # OpenAI API key for GenAI service
export TF_VAR_grafana_admin_password="ChangeMe!"  # Grafana dashboard password
export TF_VAR_budget_alert_email="you@email.com"  # AWS Budget alert recipient
```

### 3 — Configure terraform.tfvars

```bash
# Copy the example file (it already contains domain_name and github_repo placeholders)
cp terraform/environments/dev/terraform.tfvars.example terraform/environments/dev/terraform.tfvars

# Edit the file and replace the placeholder values:
#   domain_name = "yourdomain.com"          → your Cloudflare-managed domain
#   github_repo = "your-github-username/spring-petclinic-microservices"  → your fork
# github_repo is required (not optional) — it scopes the OIDC trust policy for CI/CD
```

### 4 — Bootstrap state backend (once per AWS account)

```bash
bash scripts/bootstrap-state.sh
```

This creates the S3 bucket + DynamoDB table and **automatically updates `backend.tf`** in both environments with your account ID — no manual editing required.

### 5 — Deploy everything with one command

```bash
# This runs terraform apply + installs ArgoCD, Karpenter, ESO, LB Controller, observability
bash scripts/up.sh --env dev
```

`up.sh` auto-detects your fork URL from `git remote get-url origin` and configures ArgoCD to watch your repo — no manual YAML editing required.

### 6 — Populate ECR (first deploy only)

After `up.sh` finishes, trigger a full image build in GitHub Actions:
```
GitHub Actions → CI - Build and Push → Run workflow → force_rebuild_all=true
```

### 7 — Run smoke test

```bash
bash scripts/smoke-test.sh --env dev
```

### Destroy

```bash
bash scripts/destroy.sh --env dev
```

> All required env vars (CLOUDFLARE_API_TOKEN, TF_VAR_*) must be set before running `destroy.sh`.

See [docs/onboarding.md](docs/onboarding.md) for the full step-by-step guide including GitHub Secrets setup.

## Key Design Decisions

| ADR | Decision |
|-----|---------|
| [ADR-0001](docs/adr/0001-public-subnets.md) | All-public subnets (no NAT Gateway) for cost optimization; SGs as perimeter |
| [ADR-0007](docs/adr/0007-helm-over-plain-yaml.md) | Helm for K8s packaging — single chart, per-service + per-env values |
| [ADR-0008](docs/adr/0008-argocd-gitops.md) | ArgoCD GitOps — CI pushes image tags, ArgoCD deploys |
| [ADR-0011](docs/adr/0011-loki-over-cloudwatch.md) | Loki over CloudWatch — cost and query experience |
| [ADR-0012](docs/adr/0012-arm64-graviton-nodes.md) | ARM64 (Graviton) for EKS nodes — cost and Graviton free trial |
| [ADR-0013](docs/adr/0013-cloudflare-provider-for-dns.md) | Cloudflare for DNS — domain registered with Cloudflare, no NS delegation to Route 53 |
| [ADR-0014](docs/adr/0014-karpenter-over-cluster-autoscaler.md) | Karpenter over Cluster Autoscaler — faster, more flexible node provisioning |
