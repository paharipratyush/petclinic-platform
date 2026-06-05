# ADR-0001: All-Public Subnet Design (No NAT Gateway)

**Status:** Accepted
**Date:** 2026-06-05
**PETPLAT:** PETPLAT-81

---

## Context

This is a student learning project deploying Spring Petclinic Microservices to AWS EKS. The standard production VPC pattern uses private subnets for workloads and a NAT Gateway so those workloads can reach the internet (ECR, STS, CloudWatch, S3) without being publicly reachable.

A NAT Gateway costs ~$32/month in fixed charges plus ~$0.045/GB of data processed. Across two environments (dev + prod), that is **~$65-130/month of baseline cost** before any data transfer — purely for network address translation.

For a learning project where students pay their own AWS bills, this cost is prohibitive. The core learning objective is Kubernetes, CI/CD, and GitOps — not VPC networking subtleties. We needed a design that keeps costs near zero without removing the security learning entirely.

---

## Decision

All workloads (EKS nodes, RDS, ALB) are placed in **public subnets**. No NAT Gateway, no private subnets, no VPC endpoints.

**Security groups are the primary access control boundary.** Four security groups enforce a strict perimeter:

| Security Group | Inbound | Outbound |
|----------------|---------|----------|
| `alb-sg` | TCP 80, 443 from `0.0.0.0/0` | TCP 30000-32767 + TCP 8080 to EKS Node SG only |
| `eks-cluster-sg` | TCP 443 from EKS Node SG only | All (to AWS services) |
| `eks-node-sg` | All from EKS Cluster SG; all from self; TCP 10250 from Cluster SG; TCP 30000-32767 from ALB SG | All (to ECR, STS, S3, CloudWatch) |
| `rds-sg` | TCP 3306 from EKS Node SG only | None (stateful SG handles TCP responses) |

In addition, the VPC default security group is locked down with no rules (`aws_default_security_group`) to prevent any resource from accidentally inheriting open access.

---

## Consequences

### Cost savings

- **NAT Gateway removed:** saves ~$32-65/month per environment
- **VPC Endpoints removed:** saves ~$7-14/month per interface endpoint
- **Total saving:** ~$35-65/month, or ~$70-130/month across dev + prod

### Trade-offs accepted

| Trade-off | Risk | Mitigation |
|-----------|------|------------|
| EKS nodes have public IPs | A misconfigured SG rule could expose a node port to the internet | All node SG rules use SG-to-SG references, never `0.0.0.0/0` ingress |
| RDS instance has a public IP | Database reachable if SG is misconfigured | RDS SG allows port 3306 from EKS Node SG only. No `0.0.0.0/0` ever |
| Less defense-in-depth | No network layer between internet and workloads | SGs enforce the perimeter; EKS nodes only accept traffic from ALB SG or Cluster SG |
| No VPC flow log isolation | Lateral movement harder to detect | Acceptable for learning context; added in observability epic (PETPLAT-15) |

### What this does NOT affect

- IAM least-privilege (enforced separately, see E-5 and OIDC stories)
- Secrets management (AWS Secrets Manager + External Secrets Operator, ADR-0011)
- TLS in transit (ALB terminates HTTPS, inter-service traffic inside the cluster)
- Image scanning (Trivy in CI pipeline blocks CRITICAL CVEs)

### When to revisit

Promote this to a private-subnet design if:
- The project moves to a production workload with real customer data
- A security audit requires network-layer isolation
- AWS Free Tier or credits make NAT Gateway cost negligible

At that point, add private subnets + NAT Gateway and move EKS nodes and RDS into them. The ALB stays in the public subnets. The security group rules remain identical.
