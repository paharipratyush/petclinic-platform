# Petclinic Platform — Operations Runbook

**Last Updated:** 2026-06-06
**Purpose:** Step-by-step procedures for common operational tasks on the petclinic-platform infrastructure. Each procedure is self-contained and includes verification and rollback steps.

## Table of Contents

1. [EKS: Add an IAM User or Role to the Cluster](#eks-add-an-iam-user-or-role-to-the-cluster)
2. [EKS: Upgrade Add-on Versions](#eks-upgrade-add-on-versions)
3. [ECR: Authenticate Docker to the Registry](#ecr-authenticate-docker-to-the-registry)
4. [ECR: Build and Push Images Manually](#ecr-build-and-push-images-manually)

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

---

## ECR: Authenticate Docker to the Registry

**Related stories:** PETPLAT-21

### Procedure: Log in Docker to ECR before pushing or pulling images

**When:** Before running `docker push` or `docker pull` against ECR. ECR tokens expire after 12 hours — re-run this if you get an authentication error.

**Who:** Any engineer with AWS credentials configured (`aws sts get-caller-identity` must work)

**Time:** ~5 seconds

**Steps:**

1. Run the helper script:
   ```bash
   ./scripts/ecr-login.sh
   ```
   Override the region if needed:
   ```bash
   ./scripts/ecr-login.sh --region eu-west-1
   ```

2. The script auto-detects your AWS account ID and logs Docker in to:
   ```
   {account}.dkr.ecr.eu-central-1.amazonaws.com
   ```

**Verify:**
- Script prints `Login successful`
- `docker pull {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-dev/config-server:v1.0.0` succeeds

**Rollback:**
- Not applicable. If login fails, check AWS credentials with `aws sts get-caller-identity` and ensure Docker Desktop is running.

---

## ECR: Build and Push Images Manually

**Related stories:** PETPLAT-85

### Procedure: Build ARM64 images from source and push to ECR

**When:** Initial setup, or when CI is unavailable and you need to push a new image tag manually. In normal operations, GitHub Actions handles this automatically on every commit.

**Who:** Engineer with Docker Desktop running, Java 17 installed, AWS credentials, and the app repo cloned locally

**Time:** ~15–20 minutes (Maven build ~5 min + ARM64 image builds ~90 sec each × 8 services)

**Steps:**

1. Ensure ECR repos exist (`terraform apply` must have been run for the target environment).

2. Have the app repo cloned:
   ```bash
   git clone https://github.com/spring-petclinic/spring-petclinic-microservices.git /path/to/app-repo
   ```

3. Run the build and push script:
   ```bash
   ./scripts/build-push.sh \
     --app-repo /path/to/spring-petclinic-microservices \
     --env dev \
     --tag v1.0.0
   ```
   Use `--env prod` and a commit SHA tag for production:
   ```bash
   ./scripts/build-push.sh \
     --app-repo /path/to/spring-petclinic-microservices \
     --env prod \
     --tag a1b2c3d
   ```

4. The script:
   - Builds all JARs with `./mvnw clean install -DskipTests`
   - Sets up Docker buildx for `linux/arm64` (required for Graviton t4g nodes)
   - Authenticates to ECR automatically
   - Builds and pushes all 8 images sequentially

**Verify:**
```bash
for svc in config-server discovery-server api-gateway customers-service visits-service vets-service genai-service admin-server; do
  tag=$(aws ecr describe-images --region eu-central-1 --repository-name "petclinic-dev/$svc" \
    --filter tagStatus=TAGGED --query "imageDetails[0].imageTags[0]" --output text)
  echo "$svc: $tag"
done
```
All 8 services should show the expected tag.

**Rollback:**
- ECR repos in dev use `MUTABLE` tags — you can overwrite a tag by re-running the script with the same `--tag` value.
- ECR repos in prod use `IMMUTABLE` tags — to fix a bad image, push a new tag and update `helm-values/{service}.yaml`.
