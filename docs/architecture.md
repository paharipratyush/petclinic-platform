# Architecture

**Last Updated:** 2026-06-09

Architecture overview for the Spring Petclinic Microservices platform on AWS.

---

## Table of Contents

1. [Overview](#overview)
2. [AWS Infrastructure Diagram](#aws-infrastructure-diagram)
3. [Service Topology](#service-topology)
4. [Network Design](#network-design)
5. [Environment Differences](#environment-differences)
6. [Technology Decisions](#technology-decisions)
7. [Monthly Cost Estimate](#monthly-cost-estimate)

---

## Overview

Spring Petclinic runs as 8 microservices on an EKS cluster in `eu-central-1`. Infrastructure is managed by Terraform; application deployment is managed by ArgoCD (GitOps). Observability is fully in-cluster (Prometheus + Grafana + Loki + FluentBit + Alertmanager + Zipkin).

---

## AWS Infrastructure Diagram

```
┌─────────────────────────────────────────────────────────┐
│  AWS eu-central-1                                       │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  VPC  10.0.0.0/16                                │  │
│  │                                                  │  │
│  │  ┌────────────────┐  ┌────────────────┐          │  │
│  │  │  Public Subnet │  │  Public Subnet │          │  │
│  │  │  10.0.1.0/24   │  │  10.0.2.0/24   │          │  │
│  │  │  eu-central-1a │  │  eu-central-1b │          │  │
│  │  │                │  │                │          │  │
│  │  │  EKS Node(s)   │  │  EKS Node(s)   │          │  │
│  │  │  t4g.small     │  │  t4g.small     │          │  │
│  │  │  ARM64/Graviton│  │  ARM64/Graviton│          │  │
│  │  └────────┬───────┘  └───────┬────────┘          │  │
│  │           │                  │                    │  │
│  │      ┌────┴──────────────────┴────┐               │  │
│  │      │   EKS Control Plane        │               │  │
│  │      │   v1.34, managed by AWS    │               │  │
│  │      └───────────────────────────┘               │  │
│  │                                                  │  │
│  │  ┌──────────────────────────────────────────┐    │  │
│  │  │  RDS MySQL 8.0  (db.t4g.micro)           │    │  │
│  │  │  petclinic-dev-mysql                     │    │  │
│  │  │  Single-AZ, encrypted at rest            │    │  │
│  │  └──────────────────────────────────────────┘    │  │
│  │                                                  │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  ┌────────────────────────────────────────────────────┐ │
│  │  ECR (Elastic Container Registry)                  │ │
│  │  8 repositories: petclinic-{env}/{service}         │ │
│  │  Scan-on-push enabled, lifecycle: keep last 10     │ │
│  └────────────────────────────────────────────────────┘ │
│                                                         │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Secrets Manager                                   │ │
│  │  petclinic/{env}/mysql-credentials                 │ │
│  │  petclinic/{env}/openai-api-key                    │ │
│  └────────────────────────────────────────────────────┘ │
│                                                         │
│  ┌────────────────────────────────────────────────────┐ │
│  │  ACM (Certificate Manager)                         │ │
│  │  *.{YOUR_DOMAIN} — wildcard TLS, DNS-validated         │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘

External DNS: Cloudflare ({YOUR_DOMAIN} registrar)
petclinic-dev.{YOUR_DOMAIN} → ALB CNAME
```

---

## Service Topology

```
Internet
   │
   ▼
[ALB] petclinic-dev.{YOUR_DOMAIN}:443
   │   TLS terminated, ACM wildcard cert
   │
   ▼
[api-gateway :8080]  ← public-facing, routes all requests
   ├── /api/customer → customers-service:8081
   ├── /api/vet      → vets-service:8083
   ├── /api/visit    → visits-service:8082
   ├── /api/genai    → genai-service:8084
   └── /               (static frontend UI)

[discovery-server :8761]  ← Eureka registry
   └── all services register here on startup

[config-server :8888]  ← Git-backed config (Spring Cloud Config)
   └── all services fetch config from here on startup

[admin-server :9090]  ← Spring Boot Admin dashboard
   └── connects to all services via Eureka

Startup order (enforced by init containers):
  config-server → discovery-server → all other services

Database-backed services (RDS MySQL):
  customers-service, visits-service, vets-service

Tracing (Zipkin :9411 in tracing namespace):
  all services → ZIPKIN_BASE_URL env var

Metrics (Prometheus :9090 in monitoring namespace):
  scrapes: api-gateway, customers-service, visits-service,
           vets-service, genai-service (via /actuator/prometheus)
  excluded: config-server, discovery-server, admin-server
            (no micrometer-registry-prometheus dependency)
```

---

## Network Design

All resources are in **public subnets** (no NAT Gateway). Security groups are the access control perimeter.

```
Security Group Matrix:

  eks-cluster-sg  →  eks-node-sg        (API server → kubelet)
  eks-node-sg     →  rds-sg:3306        (pods → MySQL)
  eks-node-sg     →  0.0.0.0/0:443      (egress: ECR, Secrets Manager, etc.)
  alb-sg:443      →  eks-node-sg:30000-32767  (ALB → NodePort)
  alb-sg:80       →  alb-sg:443         (HTTP → HTTPS redirect)
  0.0.0.0/0:443   →  alb-sg             (Internet → ALB)

VPC Flow:
  VPC CIDR:    10.0.0.0/16
  Subnet A:    10.0.1.0/24  (eu-central-1a)
  Subnet B:    10.0.2.0/24  (eu-central-1b)

Pod networking:
  VPC CNI (vpc-cni addon) — each pod gets a VPC IP
  t4g.small: max 11 pods/node (3 ENIs × 3 secondary IPs + 2)
  ENI pod limit resolved by Karpenter provisioning (E-14)

DNS:
  {YOUR_DOMAIN} registered at Cloudflare Registrar
  Cloudflare Terraform provider manages DNS records
  ACM wildcard cert validated via Cloudflare CNAME (Cloudflare is authoritative)
```

---

## Environment Differences

| Aspect | Dev | Prod |
|--------|-----|------|
| EKS nodes | 4× t4g.small | 4× t4g.small |
| Node min/desired/max | 2/4/4 | 2/2/4 |
| Namespace | petclinic-dev | petclinic-prod |
| Replicas | 1 per service | 2+ per service |
| HPA | disabled | enabled |
| PDB | disabled | enabled |
| ArgoCD sync | auto (prune + selfHeal) | manual (UI/CLI only) |
| RDS instance | db.t4g.micro, single-AZ | db.t4g.micro, single-AZ |
| RDS backups | disabled (free-tier) | 7-day retention |
| Tag mutability | MUTABLE (re-push same tag) | IMMUTABLE |
| DNS record | petclinic-dev.{YOUR_DOMAIN} | petclinic.{YOUR_DOMAIN} |

---

## Technology Decisions

| Decision | Choice | ADR |
|----------|--------|-----|
| Container orchestration | EKS (not ECS) | ADR-0002 |
| Subnets | All-public (no NAT) | ADR-0001 |
| RDS deployment | Single shared instance | ADR-0003 |
| K8s packaging | Helm generic chart | ADR-0007 |
| CI/CD auth | GitHub Actions OIDC | ADR-0005 |
| RDS AZ | Single-AZ (both envs) | ADR-0006 |
| CD strategy | ArgoCD GitOps | ADR-0008 |
| Container registry | ECR Private | ADR-0009 |
| Secrets | Secrets Manager + ESO | ADR-0010 |
| Log aggregation | Loki + FluentBit (in-cluster) | ADR-0011 |
| EKS worker architecture | ARM64 Graviton t4g.small | ADR-0012 |
| DNS provider | Cloudflare Terraform | ADR-0013 |
| Node scaling | Karpenter | ADR-0014 |

See `docs/adr/` for full decision records.

---

## Monthly Cost Estimate

All instance choices maximize AWS free tier / Graviton trial eligibility. This is a learning project.

| Resource | Dev (~) | Prod (~) | Free Tier Note |
|----------|---------|----------|---------------|
| EKS Control Plane | $73 | $73 | No free tier — unavoidable |
| EC2 Nodes (2× t4g.small, ARM64) | $0 | $0 | Graviton free trial (750 hrs/mo, until Dec 2026) |
| RDS MySQL (db.t4g.micro) | $0 | $0 | RDS free tier (750 hrs/mo, 12 months) |
| ALB | $0 | $0 | Free tier (750 hrs/mo, 12 months) |
| S3 + DynamoDB (Terraform state) | ~$1 | ~$1 | Mostly free tier |
| ECR Storage | ~$1 | ~$1 | 500 MB free; $0.10/GB/month beyond |
| EBS (PVs for Prometheus, Grafana, Loki) | ~$2 | ~$2 | 30 GB gp2 free (12 months) |
| Cloudflare DNS | $0 | $0 | Free — no Route 53 hosted zone needed |
| Secrets Manager (~3 secrets) | ~$1 | ~$1 | $0.40/secret/month |
| Data Transfer | ~$1 | ~$1 | 100 GB/mo free |
| **Total** | **~$80/mo** | **~$80/mo** | EKS control plane dominates |

**No NAT Gateway cost** — the all-public subnet design saves ~$35–65/mo vs a standard VPC with NAT.

**Cost optimization tips:**
- Run `terraform destroy` after each session to eliminate EKS control plane charges (~$0.10/hr = ~$17/mo for 10 hrs/week)
- After the Graviton free trial expires, enable Karpenter spot instances (dev NodePool) for 60–70% compute savings
- Budget alerts fire at 50%, 80%, and 100% of $100/month per environment (configured in Terraform)

See [`docs/technical-spec.md § Scaling and Cost`](technical-spec.md#scaling-and-cost) for the full cost breakdown and spot instance configuration.
