# Petclinic Platform — Operations Runbook

**Last Updated:** 2026-06-06
**Purpose:** Step-by-step procedures for common operational tasks on the petclinic-platform infrastructure. Each procedure is self-contained and includes verification and rollback steps.

## Table of Contents

1. [EKS: Add an IAM User or Role to the Cluster](#eks-add-an-iam-user-or-role-to-the-cluster)
2. [EKS: Upgrade Add-on Versions](#eks-upgrade-add-on-versions)
3. [ECR: Authenticate Docker to the Registry](#ecr-authenticate-docker-to-the-registry)
4. [ECR: Build and Push Images Manually](#ecr-build-and-push-images-manually)
5. [RDS: Database Initialization Strategy](#rds-database-initialization-strategy)
6. [RDS: Retrieve Credentials from Secrets Manager](#rds-retrieve-credentials-from-secrets-manager)
7. [RDS: Free-Tier Backup Retention Deviation](#rds-free-tier-backup-retention-deviation)
8. [DNS: Delegate Domain to Route 53](#dns-delegate-domain-to-route-53)
9. [DNS: Install AWS Load Balancer Controller and Apply Ingress](#dns-install-aws-load-balancer-controller-and-apply-ingress)
10. [DNS: Create Route 53 A Record After ALB Provisioning](#dns-create-route-53-a-record-after-alb-provisioning)

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

---

## RDS: Database Initialization Strategy

**Related stories:** PETPLAT-24

### Overview

All three database-backed services (customers, visits, vets) share a **single RDS MySQL instance** with a single `petclinic` database. Each service owns its own tables within that database. The database is created automatically by Terraform (`db_name = "petclinic"` on the `aws_db_instance` resource).

**Strategy: Spring Boot auto-initialization** — each service initializes its own schema tables on first startup using `spring.sql.init.mode=always` (active when the `mysql` profile is set). No manual schema scripts are run; no init containers handle SQL.

### Schema Ownership

| Service | Tables Created | Foreign Keys |
|---------|---------------|--------------|
| customers-service | `types`, `owners`, `pets` | `pets.owner_id` → `owners(id)`, `pets.type_id` → `types(id)` |
| vets-service | `vets`, `specialties`, `vet_specialties` | `vet_specialties.vet_id` → `vets(id)`, `vet_specialties.specialty_id` → `specialties(id)` |
| visits-service | `visits` | `visits.pet_id` → `pets(id)` — **cross-service FK** |

### Initialization Order (CRITICAL)

`visits.pet_id` references `pets(id)` which is created by customers-service. Deploy in this order:

1. **customers-service** — creates `types`, `owners`, `pets`
2. **vets-service** — creates `vets`, `specialties`, `vet_specialties` (independent, can be parallel)
3. **visits-service** — creates `visits` (must run after customers-service creates `pets`)

This order is enforced in ArgoCD via sync waves (E-17) and init containers (E-8). Do not start visits-service before customers-service has initialized its schema.

### Required Spring Profiles

DB-backed services must have both profiles active:

```
SPRING_PROFILES_ACTIVE=docker,mysql
```

- `docker` — switches Config Server URL from localhost to `config-server` (Docker DNS)
- `mysql` — switches from in-memory HSQLDB to MySQL datasource

### Connection String Format

```
SPRING_DATASOURCE_URL=jdbc:mysql://{rds-endpoint}:3306/petclinic
SPRING_DATASOURCE_USERNAME={from Secrets Manager}
SPRING_DATASOURCE_PASSWORD={from Secrets Manager}
```

Example:
```
jdbc:mysql://petclinic-dev-mysql.abc123.eu-central-1.rds.amazonaws.com:3306/petclinic
```

The endpoint is available from Terraform output:
```bash
terraform -chdir=terraform/environments/dev output rds_endpoint
```

### SQL Script Locations (in application repo)

Scripts are in `src/main/resources/db/mysql/` within each service module. Spring auto-runs them via `spring.sql.init.schema-locations`. Do not run these manually unless re-initializing after data loss.

---

## RDS: Retrieve Credentials from Secrets Manager

**Related stories:** PETPLAT-23

### Procedure: Get the RDS master username and password

**When:** Debugging connectivity, running a manual migration, or verifying credentials.

**Who:** Engineer with `secretsmanager:GetSecretValue` IAM permission on `petclinic/{env}/rds-credentials`

**Time:** ~5 seconds

**Steps:**

1. Retrieve the secret as JSON:
   ```bash
   aws secretsmanager get-secret-value \
     --secret-id "petclinic/{env}/rds-credentials" \
     --region eu-central-1 \
     --query SecretString \
     --output text | jq .
   ```
   Replace `{env}` with `dev` or `prod`.

2. Extract individual fields:
   ```bash
   SECRET=$(aws secretsmanager get-secret-value \
     --secret-id "petclinic/dev/rds-credentials" \
     --region eu-central-1 \
     --query SecretString --output text)

   DB_USER=$(echo "$SECRET" | jq -r .username)
   DB_PASS=$(echo "$SECRET" | jq -r .password)
   ```

3. Connect to the database (from within the cluster or a debug pod):
   ```bash
   mysql -h {rds-endpoint} -u "$DB_USER" -p"$DB_PASS" petclinic
   ```

**Verify:**
```sql
SHOW TABLES;
```
After services have started, you should see: `owners`, `pets`, `types`, `specialties`, `vet_specialties`, `vets`, `visits`.

**Note:** Never log or commit the password. The password is rotated by re-running Terraform (which regenerates `random_password` only if tainted) or manually in Secrets Manager.

---

## RDS: Free-Tier Backup Retention Deviation

**Related stories:** PETPLAT-25

### Overview

The technical spec and Jira backlog specify `backup_retention_period = 7` for dev. This cannot be applied to free-tier AWS accounts — AWS returns `FreeTierRestrictionError` when any value greater than 0 is set.

**Dev:** `backup_retention_period = 0` (automated backups disabled — free tier requirement)
**Prod:** `backup_retention_period = 30` (as specced — prod is not a free tier resource)

### Impact

Automated daily snapshots are disabled for the dev RDS instance. Manual snapshots are still possible via the AWS Console or CLI:

```bash
aws rds create-db-snapshot \
  --db-instance-identifier petclinic-dev-mysql \
  --db-snapshot-identifier petclinic-dev-mysql-manual-$(date +%Y%m%d) \
  --region eu-central-1
```

### Restoring from Manual Snapshot

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier petclinic-dev-mysql-restored \
  --db-snapshot-identifier <snapshot-id> \
  --region eu-central-1
```

### When Upgrading Account Tier

If the AWS account is upgraded from free tier, re-enable automated backups by changing `backup_retention_period` in `terraform/environments/dev/main.tf` from `0` to `7` and re-applying.

---

## DNS: Delegate Domain to Route 53

**Related stories:** PETPLAT-28, PETPLAT-32

### Overview

The DNS module creates a Route 53 hosted zone and an ACM wildcard certificate (`*.{domain}`) with DNS validation. The ACM certificate cannot be issued until Route 53 is authoritative for your domain — which requires updating your registrar's nameservers.

**When:** After the first `terraform apply` for the target environment. Do this before running `install-lb-controller.sh`.

**Who:** Domain registrar admin access (Cloudflare dashboard, Route 53 console, etc.) + Terraform access

**Time:** ~5 minutes to update NS records + 5–30 minutes for DNS propagation + ACM certificate issuance

**Steps:**

1. Run `terraform apply` for the target environment. The apply will block at `aws_acm_certificate_validation` until the certificate is issued:
   ```bash
   cd terraform/environments/dev
   terraform plan -var="domain_name=example.com" -out plan.out
   terraform apply plan.out
   ```
   Leave this running. Open a second terminal for the next steps.

2. Get the Route 53 nameservers from the Terraform output:
   ```bash
   terraform -chdir=terraform/environments/dev output dns_name_servers
   ```
   You will see 4 NS records like:
   ```
   [
     "ns-1234.awsdns-56.com.",
     "ns-789.awsdns-01.co.uk.",
     "ns-012.awsdns-34.net.",
     "ns-567.awsdns-89.org.",
   ]
   ```

3. Update your domain registrar with these nameservers:
   - **Cloudflare registrar:** Dashboard → your domain → DNS → Nameservers → Custom → paste all 4 NS records (without trailing dot)
   - **Route 53 registrar:** Dashboard → Registered domains → your domain → Update nameservers
   - **Other registrar:** DNS Settings / Nameserver Settings → replace existing NS records with the 4 above

4. DNS propagation typically takes 5–30 minutes but can take up to 48 hours. Monitor progress:
   ```bash
   # Check if your domain now resolves via Route 53 NS
   dig NS example.com @8.8.8.8
   ```
   Once you see the Route 53 NS records in the response, ACM will validate and the `terraform apply` will complete.

**Verify:**
```bash
# Confirm certificate is issued
aws acm describe-certificate \
  --certificate-arn "$(terraform -chdir=terraform/environments/dev output -raw certificate_arn)" \
  --region eu-central-1 \
  --query "Certificate.Status" \
  --output text
# Expected: ISSUED
```

**Rollback:**
- Revert your registrar's nameservers to the previous values to move DNS back to the original provider.
- The Route 53 hosted zone can be destroyed with `terraform destroy -target=module.dns.aws_route53_zone.main` (requires approval per safety hooks).

---

## DNS: Install AWS Load Balancer Controller and Apply Ingress

**Related stories:** PETPLAT-29, PETPLAT-30

### Procedure: Install the AWS Load Balancer Controller and create the ALB

**When:** After `terraform apply` has completed (IRSA role and ACM cert exist) and DNS is delegated to Route 53.

**Who:** kubectl access to the EKS cluster + helm installed

**Time:** ~5 minutes

**Prerequisites:**
- `kubectl` configured: `aws eks update-kubeconfig --name petclinic-{env} --region eu-central-1`
- `helm` installed (>= 3.x)
- `terraform apply` completed successfully (outputs `lb_controller_role_arn` and `certificate_arn` must exist)

**Steps:**

Run the install script for the target environment:
```bash
./scripts/install-lb-controller.sh --env dev
```

The script performs all steps automatically:
1. Adds the `eks` Helm chart repository
2. Installs (or upgrades) `aws-load-balancer-controller` in `kube-system`, annotated with the IRSA role ARN
3. Waits for the controller deployment to be ready
4. Applies `k8s/base/ingress/ingress.yaml` with the ACM certificate ARN and ALB security group substituted
5. Waits for the ALB to be provisioned and prints the ALB DNS name

**Verify:**
```bash
# Controller pods running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# IngressClass created
kubectl get ingressclass alb

# Ingress has an ALB address
kubectl get ingress petclinic-ingress -n petclinic-{env}
# ADDRESS column should show an ALB hostname like k8s-petclini-xxxx.eu-central-1.elb.amazonaws.com
```

**Rollback:**
```bash
helm uninstall aws-load-balancer-controller -n kube-system
kubectl delete ingress petclinic-ingress -n petclinic-{env}
```
The ALB is deleted when the Ingress resource is deleted.

---

## DNS: Create Route 53 A Record After ALB Provisioning

**Related stories:** PETPLAT-31

### Procedure: Point your domain at the ALB

**When:** After `install-lb-controller.sh` has run and the Ingress shows an ALB DNS name.

**Who:** Terraform access to the environment

**Time:** ~2 minutes (Terraform apply) + DNS propagation (typically instant for Route 53 aliases)

**Steps:**

1. Get the ALB DNS name from the Ingress:
   ```bash
   ALB_DNS=$(kubectl get ingress petclinic-ingress -n petclinic-dev \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   echo $ALB_DNS
   # Example: k8s-petclini-a1b2c3d4-1234567890.eu-central-1.elb.amazonaws.com
   ```

2. Plan and apply the Route 53 A record (alias to ALB):
   ```bash
   cd terraform/environments/dev
   terraform plan -var="domain_name=example.com" -var="alb_dns_name=$ALB_DNS" -out plan.out
   terraform apply plan.out
   ```
   This creates `petclinic-dev.example.com → ALB` (for dev) or `petclinic.example.com → ALB` (for prod).

3. For subsequent applies (e.g., to make changes), pass the same variable:
   ```bash
   terraform plan -var="domain_name=example.com" -var="alb_dns_name=$ALB_DNS" -out plan.out
   ```
   Or add `alb_dns_name = "..."` to the environment's `terraform.tfvars` (do not commit this file — it may contain other sensitive values).

**Verify:**
```bash
# DNS lookup
nslookup petclinic-dev.example.com

# HTTPS access
curl -I https://petclinic-dev.example.com
# Expected: HTTP/2 200 (or 302 redirect from api-gateway)
```

**If HTTP redirects to HTTPS:** This is correct behavior — the ALB listener is configured to redirect port 80 → 443.

**If DNS does not resolve:** Check that NS delegation is still active:
```bash
dig NS example.com @8.8.8.8
# Should show Route 53 nameservers
```
