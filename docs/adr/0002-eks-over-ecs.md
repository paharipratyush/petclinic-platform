# ADR-0002: EKS over ECS for Container Orchestration

**Status:** Accepted
**Date:** 2026-06-04

## Context

The Petclinic microservices platform requires a container orchestration layer to run 8 Spring Boot services on AWS. The two primary AWS-native options are:

- **Amazon ECS** (Elastic Container Service) — AWS proprietary orchestrator. Tightly integrated with AWS services. Lower operational complexity, no cluster management fee beyond EC2/Fargate compute.
- **Amazon EKS** (Elastic Kubernetes Service) — Managed Kubernetes. Industry-standard, cloud-agnostic API. $0.10/hr control plane fee on top of compute.

The project's primary goal is a **learning environment** that teaches production-grade cloud infrastructure patterns. Tool choices must reflect what engineers will encounter in real workloads.

## Decision

Use **Amazon EKS** (Elastic Kubernetes Service) with managed node groups (ARM64/Graviton t4g.small).

## Rationale

| Factor | ECS | EKS | Why EKS wins |
|--------|-----|-----|--------------|
| Industry adoption | AWS-only, ~20% market | Industry standard, ~65%+ market | Learning K8s is transferable to GKE, AKS, on-prem |
| K8s ecosystem | Partial (App Mesh, etc.) | Full (ArgoCD, Helm, Karpenter, ESO) | All modern DevOps tooling targets K8s natively |
| ArgoCD (E-17) | Requires ECS plugin, limited | First-class support | GitOps pipeline is simpler and more powerful on K8s |
| Helm (E-16) | Works via Copilot, but awkward | Native packaging format | Helm is the dominant K8s packaging tool |
| Network policies | Task-level SGs only | Full K8s NetworkPolicy spec | Finer-grained egress/ingress control for E-13 |
| Autoscaling | ECS Service Auto Scaling | HPA + Karpenter (E-14) | Karpenter provides faster, cheaper node provisioning |
| Cost | Fargate: ~$50/mo for 8 services | EC2 nodes: ~$0 (Graviton free trial) | EKS + t4g nodes is cheaper during the trial period |
| IRSA | Task roles (similar) | Full IRSA support | More granular per-workload IAM |

## Consequences

**Positive:**
- Students learn Kubernetes directly — the most transferable container skill
- Full access to the CNCF ecosystem: ArgoCD, Helm, Karpenter, External Secrets Operator
- ARM64/Graviton free trial makes compute cost $0 until December 2026 (see ADR-0012)
- Managed node groups reduce operational overhead vs self-managed control plane

**Negative:**
- EKS control plane costs $0.10/hr (~$73/month) unavoidably — ECS has no equivalent fixed fee
- Higher initial learning curve than ECS for students new to Kubernetes
- More configuration: IAM roles for service accounts (IRSA), add-ons, OIDC provider
- `kubectl` + EKS context management vs simpler ECS task/service commands

## Cost Impact

EKS control plane: ~$73/month — this is the single largest unavoidable cost in the project. Students should `terraform destroy` after each session to minimize this. At 10 hours/week of active use, the effective control plane cost is ~$4/week. See [Scaling and Cost](../technical-spec.md#scaling-and-cost).

## Related

- ADR-0001: All-public subnet design (compute placement decision)
- ADR-0012: ARM64/Graviton nodes (node type decision within EKS)
- PETPLAT-12, PETPLAT-13: EKS cluster and node group Terraform implementation
- Technical Spec: [EKS Cluster](../technical-spec.md#eks-cluster)
