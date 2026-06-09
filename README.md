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
| DNS | Cloudflare + ACM | praty.dev managed via Cloudflare; ACM cert for TLS at ALB (ADR-0013) |
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

## Quick Start

### Prerequisites

- Terraform >= 1.6, kubectl, helm, argocd CLI
- AWS CLI authenticated with sufficient permissions
- `CLOUDFLARE_API_TOKEN` environment variable set
- Secrets set: `TF_VAR_openai_api_key`, `TF_VAR_grafana_admin_password`, `TF_VAR_budget_alert_email`, `TF_VAR_domain_name`

### Bootstrap and Deploy

```bash
# 1. Bootstrap Terraform state backend
bash scripts/bootstrap-state.sh dev

# 2. Apply infrastructure
cd terraform/environments/dev
terraform init
terraform plan -out plan.out
terraform apply plan.out

# 3. Configure kubectl
aws eks update-kubeconfig --region eu-central-1 --name petclinic-dev-eks

# 4. Bootstrap cluster (ESO, LB Controller, Karpenter, observability)
bash scripts/up.sh dev

# 5. Run smoke test
bash scripts/smoke-test.sh dev
```

See [docs/onboarding.md](docs/onboarding.md) for the full step-by-step guide.

## Key Design Decisions

| ADR | Decision |
|-----|---------|
| [ADR-0001](docs/adr/0001-public-subnets.md) | All-public subnets (no NAT Gateway) for cost optimization; SGs as perimeter |
| [ADR-0007](docs/adr/0007-helm-over-plain-yaml.md) | Helm for K8s packaging — single chart, per-service + per-env values |
| [ADR-0008](docs/adr/0008-argocd-gitops.md) | ArgoCD GitOps — CI pushes image tags, ArgoCD deploys |
| [ADR-0011](docs/adr/0011-loki-over-cloudwatch.md) | Loki over CloudWatch — cost and query experience |
| [ADR-0012](docs/adr/0012-arm64-graviton-nodes.md) | ARM64 (Graviton) for EKS nodes — cost and Graviton free trial |
| [ADR-0013](docs/adr/0013-cloudflare-provider-for-dns.md) | Cloudflare for DNS — praty.dev is registered with Cloudflare |
| [ADR-0014](docs/adr/0014-karpenter-over-cluster-autoscaler.md) | Karpenter over Cluster Autoscaler — faster, more flexible node provisioning |
