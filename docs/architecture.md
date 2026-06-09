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
│  │  *.praty.dev — wildcard TLS, DNS-validated         │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘

External DNS: Cloudflare (praty.dev registrar)
petclinic-dev.praty.dev → ALB CNAME
```

---

## Service Topology

```
Internet
   │
   ▼
[ALB] petclinic-dev.praty.dev:443
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
  praty.dev registered at Cloudflare Registrar
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
| DNS record | petclinic-dev.praty.dev | petclinic.praty.dev |

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
| Container registry | ECR Private | ADR-0010 |
| Secrets | Secrets Manager + ESO | ADR-0011 |
| EKS worker architecture | ARM64 Graviton t4g.small | ADR-0012 |
| DNS provider | Cloudflare Terraform | ADR-0013 |
| Log aggregation | Loki + FluentBit (in-cluster) | ADR-0014 |
| Node scaling | Karpenter (planned E-14) | ADR-0009 |

See `docs/adr/` for full decision records.
