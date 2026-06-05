# Petclinic Platform — Operations Runbook

**Last Updated:** 2026-06-06
**Purpose:** Step-by-step procedures for common operational tasks on the petclinic-platform infrastructure. Each procedure is self-contained and includes verification and rollback steps.

## Table of Contents

1. [EKS: Add an IAM User or Role to the Cluster](#eks-add-an-iam-user-or-role-to-the-cluster)
2. [EKS: Upgrade Add-on Versions](#eks-upgrade-add-on-versions)

---

## EKS: Add an IAM User or Role to the Cluster

**Related stories:** PETPLAT-14

### Procedure: Grant cluster-admin access to an IAM principal

**When:** A new engineer, CI/CD role, or AWS account principal needs `kubectl` access to `petclinic-dev` or `petclinic-prod`.

**Who:** IAM admin + Terraform access to the environment

**Time:** ~2 minutes (Terraform apply is near-instant for access entries)

**Steps:**

1. Obtain the ARN of the IAM user or role that needs access:
   ```bash
   # IAM user
   aws iam get-user --user-name <username> --query "User.Arn" --output text

   # IAM role
   aws iam get-role --role-name <role-name> --query "Role.Arn" --output text
   ```

2. Open the environment's `main.tf` and pass the ARN via `admin_iam_arns`:
   ```hcl
   # terraform/environments/dev/main.tf
   module "eks" {
     # ... existing config ...
     admin_iam_arns = [
       "arn:aws:iam::568521409121:user/new-engineer",
     ]
   }
   ```

3. Plan and apply:
   ```bash
   cd terraform/environments/dev
   terraform plan -out plan.out
   terraform apply plan.out
   ```

4. Have the new user run:
   ```bash
   aws eks update-kubeconfig --name petclinic-{env} --region eu-central-1
   ```

**Verify:**
- `kubectl get nodes` returns 2 Ready nodes without error
- `aws eks list-access-entries --cluster-name petclinic-{env}` shows the new ARN

**Rollback:**
- Remove the ARN from `admin_iam_arns` and re-apply. The access entry and policy association are deleted immediately.

**Note:** The IAM user or role that runs `terraform apply` always gets cluster-admin access automatically (via `data.aws_caller_identity.current`). You only need `admin_iam_arns` for additional principals.

---

## EKS: Upgrade Add-on Versions

**Related stories:** PETPLAT-84

### Procedure: Upgrade a pinned EKS managed add-on

**When:** Upgrading the EKS cluster to a new Kubernetes minor version, or applying a security patch to an add-on.

**Who:** Terraform access to the environment

**Time:** ~5 minutes per add-on (EKS applies upgrades rolling, add-ons restart quickly)

**Steps:**

1. Find the latest add-on version compatible with your cluster's Kubernetes version:
   ```bash
   aws eks describe-addon-versions \
     --kubernetes-version 1.34 \
     --addon-name <addon-name> \
     --region eu-central-1 \
     --query "addons[0].addonVersions[*].{version: addonVersion, default: compatibilities[0].defaultVersion}" \
     --output table
   ```
   Replace `<addon-name>` with one of: `coredns`, `kube-proxy`, `vpc-cni`, `aws-ebs-csi-driver`

2. Update the relevant variable in `terraform/modules/eks/variables.tf`:
   ```hcl
   variable "addon_version_coredns" {
     default = "v1.11.4-eksbuild.33"   # <-- update this value
   }
   ```
   Variables to update per add-on:
   | Add-on | Variable |
   |--------|----------|
   | coredns | `addon_version_coredns` |
   | kube-proxy | `addon_version_kube_proxy` |
   | vpc-cni | `addon_version_vpc_cni` |
   | aws-ebs-csi-driver | `addon_version_ebs_csi` |

3. Plan and verify only the target add-on changes:
   ```bash
   cd terraform/environments/dev
   terraform plan -out plan.out
   ```
   The plan should show `~ update in-place` for only the target `aws_eks_addon` resource.

4. Apply:
   ```bash
   terraform apply plan.out
   ```

5. Repeat for prod after validating dev:
   ```bash
   cd terraform/environments/prod
   terraform plan -out plan.out
   terraform apply plan.out
   ```

**Verify:**
```bash
kubectl get pods -n kube-system
```
All add-on pods should show `Running` status. For coredns, there will be a brief rolling restart.

```bash
aws eks describe-addon --cluster-name petclinic-{env} --addon-name <addon-name> \
  --query "addon.{version: addonVersion, status: status}"
```
Status should be `ACTIVE`.

**Rollback:**
- Revert the version variable to the previous value in `variables.tf` and re-apply.
- EKS supports downgrading add-on versions via Terraform the same way — just change the version string and apply.
