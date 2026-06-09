# ADR-0009: Karpenter over Cluster Autoscaler

**Status:** Proposed (implementation pending — E-14)
**Date:** 2026-06-09
**PETPLAT:** E-14

---

## Context

The EKS cluster needs to scale node capacity automatically as workloads change. Two primary options exist for EKS node autoscaling:

**Cluster Autoscaler (CA):**
- Works with managed node groups
- Scales existing node groups up/down based on pending pods
- Uses predefined instance types; can't adapt instance type per workload
- Requires separate Helm chart + IRSA role
- Scales incrementally (one node at a time)

**Karpenter:**
- AWS-native, open-source node provisioner
- Provisions EC2 instances directly (any type matching NodePool constraints)
- Understands pod resource requirements and picks optimally sized nodes
- ~60-second provisioning time (vs 3–5 min for CA)
- Spot + On-Demand mixed fleets in a single NodePool
- Handles deprovisioning (consolidation): terminates underutilized nodes
- Works alongside managed node groups or replaces them

For the Petclinic platform, the immediate problem is the VPC CNI ENI pod limit on t4g.small (11 pods/node). Karpenter solves this by provisioning larger instances or instances with more ENIs when needed, rather than scaling t4g.small nodes that immediately hit the pod ceiling.

---

## Decision

Use **Karpenter** for node autoscaling in both dev and prod environments.

The managed node group stays as a "baseline" with 2 nodes (`min_size=2`) for system pods. Karpenter provisions additional capacity for application workloads via NodePool + EC2NodeClass resources.

NodePool configuration (planned):
- **Dev:** t4g.small or t4g.medium spot + on-demand mixed; ARM64; limit: 4 nodes
- **Prod:** t4g.medium/large on-demand; ARM64; limit: 6 nodes; consolidation policy

---

## Consequences

### Positive

- **Removes the 11-pod ENI wall**: Karpenter picks t4g.medium (23 pod max) or larger when t4g.small is insufficient
- **Cost optimization**: Consolidation removes idle nodes automatically; Spot support reduces costs 60–80%
- **Faster scaling**: 60-second node provisioning vs 3–5 minutes for CA
- **No node group management**: No pre-configured scaling steps; Karpenter provisions exactly the capacity needed
- **Drift detection**: Karpenter can replace out-of-date nodes automatically on new AMI releases

### Negative / Watch out for

- **More complex setup**: Requires SQS + EventBridge for spot interruption handling, IAM NodeRole, IRSA role
- **Replaces some managed node group responsibilities**: Operators must define NodePool constraints carefully
- **Spot interruption handling**: Application pods must tolerate interruption (all petclinic services are stateless, so this is acceptable)
- **ARM64 constraint must be explicit**: NodePool must specify `kubernetes.io/arch: arm64` to match existing ECR images

### When to revisit

- When E-14 is implemented: review NodePool sizing and consolidation settings
- When Graviton free trial ends (December 2026): Karpenter's instance flexibility makes the x86 vs ARM64 decision easier

---

## Related

- ADR-0012: ARM64 Graviton nodes (constrains NodePool to ARM64)
- PETPLAT E-14: Scaling & Cost Optimization
- `terraform/modules/karpenter/` (planned)
