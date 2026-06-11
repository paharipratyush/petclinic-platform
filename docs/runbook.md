# Petclinic Platform â€” Operations Runbook

**Last Updated:** 2026-06-09
**Purpose:** Step-by-step procedures for common operational tasks on the petclinic-platform infrastructure. Each procedure is self-contained and includes verification and rollback steps.

## Table of Contents

1. [EKS: Add an IAM User or Role to the Cluster](#eks-add-an-iam-user-or-role-to-the-cluster)
2. [EKS: Upgrade Add-on Versions](#eks-upgrade-add-on-versions)
3. [EKS: Kubernetes Version Upgrade Strategy](#eks-kubernetes-version-upgrade-strategy)
4. [ECR: Authenticate Docker to the Registry](#ecr-authenticate-docker-to-the-registry)
5. [ECR: Build and Push Images Manually](#ecr-build-and-push-images-manually)
6. [RDS: Database Initialization Strategy](#rds-database-initialization-strategy)
7. [RDS: Retrieve Credentials from Secrets Manager](#rds-retrieve-credentials-from-secrets-manager)
8. [RDS: Free-Tier Backup Retention Deviation](#rds-free-tier-backup-retention-deviation)
9. [DNS: Set CLOUDFLARE_API_TOKEN Before Applying](#dns-set-cloudflare_api_token-before-applying)
10. [DNS: Install AWS Load Balancer Controller and Apply Ingress](#dns-install-aws-load-balancer-controller-and-apply-ingress)
11. [DNS: Create Cloudflare CNAME After ALB Provisioning](#dns-create-cloudflare-cname-after-alb-provisioning)
12. [Infrastructure: Safe Teardown Before terraform destroy](#infrastructure-safe-teardown-before-terraform-destroy)
13. [Secrets: Add a New Application Secret](#secrets-add-a-new-application-secret)
14. [Services: Restart a Service](#services-restart-a-service)
15. [Services: Scale Replicas Manually](#services-scale-replicas-manually)
16. [ArgoCD: Roll Back to a Previous Image Tag](#argocd-roll-back-to-a-previous-image-tag)
17. [Terraform: Plan and Apply Workflow](#terraform-plan-and-apply-workflow)
18. [Terraform: State Management Operations](#terraform-state-management-operations)
19. [Infrastructure: Full Destroy and Rebuild Procedure](#infrastructure-full-destroy-and-rebuild-procedure)

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
       "arn:aws:iam::<ACCOUNT_ID>:user/new-engineer",
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
- EKS supports downgrading add-on versions via Terraform the same way â€” just change the version string and apply.

---

## ECR: Authenticate Docker to the Registry

**Related stories:** PETPLAT-21

### Procedure: Log in Docker to ECR before pushing or pulling images

**When:** Before running `docker push` or `docker pull` against ECR. ECR tokens expire after 12 hours â€” re-run this if you get an authentication error.

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

**Time:** ~15â€“20 minutes (Maven build ~5 min + ARM64 image builds ~90 sec each Ã— 8 services)

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
- ECR repos in dev use `MUTABLE` tags â€” you can overwrite a tag by re-running the script with the same `--tag` value.
- ECR repos in prod use `IMMUTABLE` tags â€” to fix a bad image, push a new tag and update `helm-values/{service}.yaml`.

---

## RDS: Database Initialization Strategy

**Related stories:** PETPLAT-24

### Overview

All three database-backed services (customers, visits, vets) share a **single RDS MySQL instance** with a single `petclinic` database. Each service owns its own tables within that database. The database is created automatically by Terraform (`db_name = "petclinic"` on the `aws_db_instance` resource).

**Strategy: Spring Boot auto-initialization** â€” each service initializes its own schema tables on first startup using `spring.sql.init.mode=always` (active when the `mysql` profile is set). No manual schema scripts are run; no init containers handle SQL.

### Schema Ownership

| Service | Tables Created | Foreign Keys |
|---------|---------------|--------------|
| customers-service | `types`, `owners`, `pets` | `pets.owner_id` â†’ `owners(id)`, `pets.type_id` â†’ `types(id)` |
| vets-service | `vets`, `specialties`, `vet_specialties` | `vet_specialties.vet_id` â†’ `vets(id)`, `vet_specialties.specialty_id` â†’ `specialties(id)` |
| visits-service | `visits` | `visits.pet_id` â†’ `pets(id)` â€” **cross-service FK** |

### Initialization Order (CRITICAL)

`visits.pet_id` references `pets(id)` which is created by customers-service. Deploy in this order:

1. **customers-service** â€” creates `types`, `owners`, `pets`
2. **vets-service** â€” creates `vets`, `specialties`, `vet_specialties` (independent, can be parallel)
3. **visits-service** â€” creates `visits` (must run after customers-service creates `pets`)

This order is enforced in ArgoCD via sync waves (E-17) and init containers (E-8). Do not start visits-service before customers-service has initialized its schema.

### Required Spring Profiles

DB-backed services must have both profiles active:

```
SPRING_PROFILES_ACTIVE=docker,mysql
```

- `docker` â€” switches Config Server URL from localhost to `config-server` (Docker DNS)
- `mysql` â€” switches from in-memory HSQLDB to MySQL datasource

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

The technical spec and Jira backlog specify `backup_retention_period = 7` for dev. This cannot be applied to free-tier AWS accounts â€” AWS returns `FreeTierRestrictionError` when any value greater than 0 is set.

**Dev:** `backup_retention_period = 0` (automated backups disabled â€” free tier requirement)
**Prod:** `backup_retention_period = 30` (as specced â€” prod is not a free tier resource)

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

## DNS: Set CLOUDFLARE_API_TOKEN Before Applying

**Related stories:** PETPLAT-28, PETPLAT-32

### Overview

DNS records for `{YOUR_DOMAIN}` are managed by the **Cloudflare Terraform provider** â€” there is no manual registrar step, no NS delegation, and no waiting for propagation. The provider creates ACM validation CNAMEs and the app subdomain CNAME directly in Cloudflare via API. See [ADR-0013](adr/0013-cloudflare-provider-for-dns.md) for the rationale.

Every `terraform plan` and `terraform apply` that touches the DNS module or the app CNAME requires `CLOUDFLARE_API_TOKEN` to be set in the shell environment. The token is **never stored in code or state**.

**When:** Before any `terraform plan` or `terraform apply` for an environment that includes the DNS module.

**Who:** Operator with Cloudflare API token access

**Time:** ~1 minute

### Procedure: Obtain and set the Cloudflare API token

**Steps:**

1. Generate a token at [Cloudflare Dashboard â†’ My Profile â†’ API Tokens](https://dash.cloudflare.com/profile/api-tokens):
   - Use the **"Edit zone DNS"** template
   - Scope it to the specific zone (`{YOUR_DOMAIN}`)
   - Permissions needed: `Zone:Read` + `DNS:Edit`

2. Export the token in your shell before running Terraform:
   ```bash
   export CLOUDFLARE_API_TOKEN="<your-token>"
   ```

3. Then run Terraform as normal:
   ```bash
   cd terraform/environments/dev
   terraform plan -var="domain_name={YOUR_DOMAIN}" -out plan.out
   terraform apply plan.out
   ```
   The ACM validation CNAME is created in Cloudflare automatically. `aws_acm_certificate_validation` completes within 2â€“5 minutes with no additional steps.

**Verify:**
```bash
# Confirm the ACM certificate is ISSUED (the validation CNAME record name is
# ACM-generated and shown in the AWS console or via describe-certificate below)
aws acm describe-certificate \
  --certificate-arn "$(terraform -chdir=terraform/environments/dev output -raw certificate_arn)" \
  --region eu-central-1 \
  --query "Certificate.Status" \
  --output text
# Expected: ISSUED
```

**Token security:**
- Store the token in a password manager, not in `.bashrc` or `.zshrc`.
- Rotate the token immediately if it is ever visible in chat, logs, or shell history.
- A compromised token with `DNS:Edit` scope can modify DNS records for the domain â€” treat it like a root password.

---

## DNS: Install AWS Load Balancer Controller and Apply Ingress

**Related stories:** PETPLAT-29, PETPLAT-30

### Procedure: Install the AWS Load Balancer Controller and create the ALB

**When:** After `terraform apply` has completed (IRSA role and ACM cert exist). DNS is managed automatically â€” no manual delegation step required.

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

## DNS: Create Cloudflare CNAME After ALB Provisioning

**Related stories:** PETPLAT-31

### Procedure: Point your subdomain at the ALB

**When:** After `install-lb-controller.sh` has run and the Ingress shows an ALB DNS hostname.

**Who:** Terraform access to the environment + `CLOUDFLARE_API_TOKEN` set

**Time:** ~2 minutes (Terraform apply) + Cloudflare DNS propagation (typically seconds)

**Steps:**

1. Get the ALB DNS hostname from the Ingress:
   ```bash
   ALB_DNS=$(kubectl get ingress petclinic-ingress -n petclinic-dev \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   echo $ALB_DNS
   # Example: k8s-petclini-a1b2c3d4-1234567890.eu-central-1.elb.amazonaws.com
   ```

2. Plan and apply the Cloudflare CNAME record:
   ```bash
   export CLOUDFLARE_API_TOKEN="<your-token>"
   cd terraform/environments/dev
   terraform plan -var="domain_name={YOUR_DOMAIN}" -var="alb_dns_name=$ALB_DNS" -out plan.out
   terraform apply plan.out
   ```
   This creates `petclinic-dev.{YOUR_DOMAIN} â†’ ALB` (for dev) or `petclinic.{YOUR_DOMAIN} â†’ ALB` (for prod).

3. Persist the ALB hostname so future applies don't lose it:
   ```bash
   # Add to terraform/environments/dev/terraform.tfvars (gitignored â€” local only):
   # alb_dns_name = "k8s-petclini-a1b2c3d4-1234567890.eu-central-1.elb.amazonaws.com"
   ```
   With this set, subsequent `terraform plan` calls don't require the `-var="alb_dns_name=..."` flag.

**Verify:**
```bash
# DNS lookup â€” CNAME chain visible
nslookup petclinic-dev.{YOUR_DOMAIN}

# HTTP â†’ HTTPS redirect (ALB listener)
curl -I http://petclinic-dev.{YOUR_DOMAIN}
# Expected: HTTP/1.1 301 Moved Permanently â†’ https://petclinic-dev.{YOUR_DOMAIN}

# HTTPS response (before app services are deployed, expect 404 or 503 from ALB default rule)
curl -I https://petclinic-dev.{YOUR_DOMAIN}
```

**If DNS does not resolve:** Confirm the `cloudflare_record.app` resource was created:
```bash
cd terraform/environments/dev
terraform state show 'cloudflare_record.app[0]'
```

---

## Infrastructure: Safe Teardown Before terraform destroy

**Related stories:** PETPLAT-29 (LB Controller), PETPLAT-30 (Ingress)

### Overview

Running `terraform destroy` directly while an Ingress exists will fail with dependency violations. The ALB is created by the AWS Load Balancer Controller (a Kubernetes operator) â€” not by Terraform. Terraform has no state entry for it and cannot delete it. The ALB holds references to the ACM certificate, subnets, security group, and IGW, which causes a cascade of `DependencyViolation` and `ResourceInUseException` errors.

**ECR is not a concern**: `force_delete = true` is set in the ECR module. Terraform destroy succeeds even when repositories contain images.

### Procedure: Tear down all infrastructure safely

**When:** Before running `terraform destroy` on any environment that has had the Ingress applied.

**Who:** `kubectl` access to the cluster + AWS CLI access to eu-central-1

**Time:** ~3 minutes (ALB deletion) + however long `terraform destroy` takes (~15 min)

**Steps:**

1. Delete the Kubernetes Ingress â€” the LB Controller sees this and deletes the ALB automatically:
   ```bash
   kubectl delete ingress petclinic-ingress -n petclinic-{env}
   ```

2. Wait for the LB Controller to delete the ALB (~30â€“60 seconds), then confirm it is gone:
   ```bash
   aws elbv2 describe-load-balancers --region eu-central-1 \
     --query "LoadBalancers[*].{Name:LoadBalancerName,State:State.Code}" \
     --output table
   # Expected: no rows (or only unrelated load balancers)
   ```

3. Run `terraform destroy`:
   ```bash
   cd terraform/environments/{env}
   terraform destroy
   ```
   All resources should now delete cleanly. If any Secrets Manager deletion fails due to a recovery window, the `recovery_window_in_days = 0` setting on dev ensures force-deletion.

**Why the ALB must be deleted first:** Terraform never created the ALB â€” the LB Controller did. Terraform cannot destroy what it doesn't manage. Deleting the Ingress delegates the cleanup back to the same controller that created the ALB, which is the correct and safe path.

**Rollback / if you skipped step 1:**
If `terraform destroy` fails with `DependencyViolation` or `ResourceInUseException`, the ALB is still alive. Find and delete it manually:
```bash
# Find the orphaned ALB
aws elbv2 describe-load-balancers --region eu-central-1 \
  --query "LoadBalancers[?contains(LoadBalancerName,'petclini')].LoadBalancerArn" \
  --output text

# Delete it
aws elbv2 delete-load-balancer --region eu-central-1 \
  --load-balancer-arn <arn-from-above>

# Wait ~30 seconds, then retry terraform destroy
```

**If the ALB is recreated** (e.g., after Ingress delete + re-apply), the ALB hostname changes. Repeat step 1â€“2 with the new hostname and update `terraform.tfvars`.

---

## Secrets: Add a New Application Secret

**When:** A new service needs a secret (API key, credentials) that is NOT the RDS password or OpenAI key.
**Who:** Platform engineer with AWS admin access and cluster access.
**Time:** 10-15 minutes.

**Steps:**

1. **Create the secret in AWS Secrets Manager:**

   ```bash
   export ENV=dev  # or prod
   export SECRET_NAME="petclinic/${ENV}/my-new-secret"

   # For a plaintext value (e.g., API key):
   aws secretsmanager create-secret \
     --name "${SECRET_NAME}" \
     --secret-string "your-secret-value-here" \
     --region eu-central-1

   # For a JSON object (e.g., username + password):
   aws secretsmanager create-secret \
     --name "${SECRET_NAME}" \
     --secret-string '{"key1":"value1","key2":"value2"}' \
     --region eu-central-1
   ```

2. **Add `secretsmanager:GetSecretValue` permission to the ESO IAM role:**

   In `terraform/environments/${ENV}/main.tf`, find the `eso_policy_arns` or inline policy for the ESO role and add the new secret ARN:

   ```hcl
   # In the secrets module or ESO IRSA resource, add to the allowed_secret_arns list:
   "arn:aws:secretsmanager:eu-central-1:<ACCOUNT_ID>:secret:petclinic/${ENV}/my-new-secret-*"
   ```

   Then run:
   ```bash
   cd terraform/environments/${ENV}
   terraform plan -out plan.out
   terraform apply plan.out
   ```

3. **Create an `ExternalSecret` manifest** (copy from an existing one):

   ```bash
   cp k8s/base/external-secrets/openai-api-key.yaml k8s/base/external-secrets/my-new-secret.yaml
   ```

   Edit the new file:
   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: my-new-secret
     namespace: petclinic-dev      # petclinic-prod for prod
     labels:
       app.kubernetes.io/name: my-new-secret
       app.kubernetes.io/part-of: petclinic
       app.kubernetes.io/managed-by: kubectl
       app.kubernetes.io/component: secrets
   spec:
     refreshInterval: 1h
     secretStoreRef:
       name: aws-secrets-manager
       kind: ClusterSecretStore
     target:
       name: my-new-secret
       creationPolicy: Owner
     data:
       - secretKey: MY_ENV_VAR_NAME
         remoteRef:
           key: petclinic/dev/my-new-secret
   ```

4. **Apply the ExternalSecret:**

   ```bash
   kubectl apply -f k8s/base/external-secrets/my-new-secret.yaml
   ```

5. **Verify the K8s Secret was created:**

   ```bash
   kubectl get secret my-new-secret -n petclinic-dev
   # Expected: Opaque secret with the correct number of data keys
   ```

6. **Reference the secret in the Deployment** (in the service's `deployment.yaml`):

   ```yaml
   env:
     - name: MY_ENV_VAR_NAME
       valueFrom:
         secretKeyRef:
           name: my-new-secret
           key: MY_ENV_VAR_NAME
   ```

**Verify:**
```bash
kubectl get externalsecret -n petclinic-dev
# STATUS column should show SecretSynced and READY=True within ~30 seconds

kubectl describe secret my-new-secret -n petclinic-dev
# Shows Data keys (values are redacted)
```

**Rollback:**
```bash
# Delete the ExternalSecret and the K8s Secret it owns:
kubectl delete externalsecret my-new-secret -n petclinic-dev
# The K8s Secret is also deleted (creationPolicy: Owner)

# Delete the Secrets Manager secret:
aws secretsmanager delete-secret \
  --secret-id "petclinic/dev/my-new-secret" \
  --force-delete-without-recovery \
  --region eu-central-1
```

---

## Services: Restart a Service

### Procedure: Rolling restart of a petclinic service

**When:** Pod is stuck, config was updated, or a secret was rotated
**Who:** Cluster access (kubectl)
**Time:** 1-3 minutes per service

**Steps:**
1. Trigger a rolling restart (ArgoCD will not revert this â€” it only reverts spec changes, not restarts):
   ```bash
   kubectl rollout restart deployment/{service-name} -n petclinic-{env}
   ```
   Example â€” restart all 8 services at once:
   ```bash
   for svc in config-server discovery-server api-gateway customers-service visits-service vets-service genai-service admin-server; do
     kubectl rollout restart deployment/$svc -n petclinic-dev
   done
   ```

2. Watch the rollout:
   ```bash
   kubectl rollout status deployment/{service-name} -n petclinic-{env} --timeout=120s
   ```

**Verify:**
```bash
kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service-name}
# All pods should be Running with READY 1/1 and a fresh AGE
```

**Rollback:**
- A restart does not change config, so no rollback needed. If the pod fails after restart, check logs:
  ```bash
  kubectl logs -n petclinic-{env} deployment/{service-name} --previous
  ```

---

## Services: Scale Replicas Manually

### Procedure: Temporarily override replica count

**When:** Load spike, debugging, or rolling back a bad deploy
**Who:** Cluster access
**Time:** Under 1 minute

> **Note (dev environment):** ArgoCD auto-sync is enabled with `selfHeal: true` in dev. A manual scale will be reverted within ~10-15 seconds unless you suspend auto-sync first.

**Steps (dev â€” suspend ArgoCD first):**
```bash
# 1. Suspend auto-sync for the app
argocd app set {service-name}-dev --sync-policy none

# 2. Scale
kubectl scale deployment/{service-name} --replicas=3 -n petclinic-dev

# 3. When done, re-enable auto-sync
argocd app set {service-name}-dev --sync-policy automated
```

**Steps (prod â€” ArgoCD is manual, so no suspension needed):**
```bash
kubectl scale deployment/{service-name} --replicas=3 -n petclinic-prod
```

**Permanent change:** Update `replicaCount` in `helm-values/{service}.yaml` or `helm-values/prod.yaml`, commit, and let ArgoCD sync.

**Verify:**
```bash
kubectl get deployment {service-name} -n petclinic-{env} -o jsonpath='{.spec.replicas}'
```

---

## ArgoCD: Roll Back to a Previous Image Tag

### Procedure: Revert a service to the previous image tag

**When:** A bad image was pushed and the service is crashing or degraded
**Who:** Cluster access + Git write access
**Time:** 5-10 minutes

**Steps:**
1. Find the previous good tag in Git history:
   ```bash
   git log --oneline helm-values/{service}.yaml
   # Example output:
   # a1b2c3d chore(ci): update customers-service image tag to d3f4a5b
   # 9e8f7a6 chore(ci): update customers-service image tag to 1c2d3e4
   ```

2. Roll back the tag in `helm-values/{service}.yaml`:
   ```bash
   # Option A: Revert to a known good SHA
   yq -i '.image.tag = "1c2d3e4"' helm-values/{service}.yaml

   # Option B: Revert the file to its state at a previous commit
   git checkout 9e8f7a6 -- helm-values/{service}.yaml
   ```

3. Commit and push:
   ```bash
   git add helm-values/{service}.yaml
   git commit -m "revert: roll back {service} to tag 1c2d3e4"
   git push origin main
   ```

4. In dev, ArgoCD will auto-sync within ~30 seconds. In prod, trigger a manual sync:
   ```bash
   argocd app sync {service-name}-prod
   ```

5. Watch the rollout:
   ```bash
   kubectl rollout status deployment/{service-name} -n petclinic-{env} --timeout=120s
   ```

**Verify:**
```bash
kubectl get deployment {service-name} -n petclinic-{env} \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show the rolled-back SHA tag
```

**Alternative: ArgoCD native rollback (without Git commit)**

ArgoCD keeps a history of previous sync states. Use this when you need instant rollback without touching Git:
```bash
# List previous syncs (history)
argocd app history {service-name}-{env}
# Example output:
# ID   DATE                           REVISION
# 0    2026-06-08 12:00:00 +0000 UTC  main (abc1234)
# 1    2026-06-09 10:00:00 +0000 UTC  main (def5678)

# Roll back to a previous sync by ID
argocd app rollback {service-name}-{env} 0
```

**Emergency fallback: `kubectl rollout undo`**

Use only when ArgoCD is unreachable or rollback must happen faster than a Git commit can propagate. This bypasses GitOps — ArgoCD will revert it on the next sync:
```bash
# Roll back to the previous deployment revision
kubectl rollout undo deployment/{service-name} -n petclinic-{env}

# Verify the rolled-back image
kubectl get deployment {service-name} -n petclinic-{env} \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# IMPORTANT: After using kubectl rollout undo, immediately update helm-values/{service}.yaml
# with the correct tag and push so ArgoCD does not overwrite your rollback on next sync.
```

**Rollback of rollback:**
```bash
git revert HEAD  # undoes the revert commit, restoring the bad tag
git push origin main
# Then redeploy and investigate the root cause instead
```

---

## Terraform: Plan and Apply Workflow

### Procedure: Safely apply infrastructure changes

**When:** Any Terraform change â€” adding a resource, changing config, version upgrade
**Who:** AWS admin (IAM permissions matching the resource being changed)
**Time:** 5-30 minutes depending on resources

**Steps:**
1. Format and validate before anything else:
   ```bash
   cd terraform/environments/{env}
   terraform fmt -recursive ../../
   terraform validate
   ```

2. Generate and review the plan:
   ```bash
   terraform plan -out plan.out
   ```
   Review the plan output carefully:
   - `+` create (new resource â€” low risk)
   - `~` update in-place (change attributes â€” medium risk)
   - `-/+` destroy and recreate (check the `# forces replacement` annotation â€” HIGH RISK)
   - `-` destroy (HIGH RISK â€” confirm this is intentional)

3. Apply the saved plan:
   ```bash
   terraform apply plan.out
   ```
   Never run `terraform apply` without a saved plan file â€” the pre-commit hook will warn you.

4. After apply, verify key outputs:
   ```bash
   terraform output
   ```

**Rollback:**
- Terraform has no built-in rollback. To undo a change, revert the `.tf` source and re-apply:
  ```bash
  git revert HEAD
  terraform plan -out plan.out
  terraform apply plan.out
  ```
- For accidentally destroyed resources, restore from the state backup in S3 (versioning is enabled):
  ```bash
  # List state file versions:
  aws s3api list-object-versions \
    --bucket petclinic-terraform-state \
    --prefix petclinic/{env}/terraform.tfstate

  # Restore a previous version:
  aws s3api get-object \
    --bucket petclinic-terraform-state \
    --key petclinic/{env}/terraform.tfstate \
    --version-id {VERSION_ID} \
    terraform.tfstate.bak
  # Then import or re-create the affected resources
  ```

**Safety reminders:**
- Always use `terraform plan -out plan.out` and review before applying.
- Never run `terraform destroy` without reading the [Infrastructure: Safe Teardown](#infrastructure-safe-teardown-before-terraform-destroy) procedure first.
- The `block-destroy.sh` hook blocks `terraform destroy` at the CLI level. Contact the team lead to override.

---

## EKS: Kubernetes Version Upgrade Strategy

**Related stories:** PETPLAT-91

### Overview

AWS EKS supports Kubernetes versions for ~14 months after release. Monitor the [AWS EKS version calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) and upgrade before the current version reaches end-of-support.

### Procedure: Upgrade EKS Cluster Version

**When:** Current K8s version is within 60 days of EKS end-of-support, or a security advisory requires it.

**Who:** Terraform access + `kubectl` admin on the cluster

**Time:** 45â€“90 minutes (control plane: ~30 min, node group rolling update: ~30 min)

**Steps:**

```bash
# 1. Check current version and available upgrades
aws eks describe-cluster \
  --name petclinic-{env}-eks \
  --query 'cluster.{version:version,status:status}'

# 2. Review release notes for the target version
#    https://kubernetes.io/releases/

# 3. Update cluster_version in the EKS module variable (one minor version at a time)
#    Edit: terraform/environments/{env}/main.tf
#    module "eks" { ... cluster_version = "1.35" }
#    Note: always upgrade one minor version at a time (1.34 â†’ 1.35, not 1.34 â†’ 1.36)

# 4. Plan and apply â€” control plane upgrades first
cd terraform/environments/{env}
terraform plan -target=module.eks -out plan.out
# Review: confirm only EKS cluster version changes
terraform apply plan.out

# 5. Wait for control plane upgrade to complete
aws eks wait cluster-active --name petclinic-{env}-eks

# 6. Upgrade managed node group (triggers rolling replacement)
#    Terraform applies this automatically in the same apply, but verify:
aws eks describe-nodegroup \
  --cluster-name petclinic-{env}-eks \
  --nodegroup-name petclinic-{env}-nodes \
  --query 'nodegroup.{status:status,version:version,releaseVersion:releaseVersion}'

# 7. Upgrade EKS add-ons to versions compatible with new K8s version
#    See: EKS: Upgrade Add-on Versions procedure

# 8. Verify cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
```

**Verify:**
- `kubectl version` shows the new server version
- All pods are Running or Completed
- ArgoCD shows all applications Healthy

**Rollback:**
- EKS control plane upgrades are one-way â€” you cannot downgrade K8s versions
- If node group upgrade fails: the old nodes remain in service; rolling update can be re-triggered
- If add-on upgrades break workloads: roll back the add-on version in `module.eks`

**Pre-upgrade checklist:**
- [ ] Test upgrade in dev environment first
- [ ] Review `kubectl get pods --all-namespaces` â€” no pods stuck in Pending/Error before starting
- [ ] Confirm Karpenter compatibility with new K8s version
- [ ] Check Helm chart apiVersion compatibility (especially if upgrading past K8s 1.25+)
- [ ] Schedule during low-traffic window (prod only)

---

## Terraform: State Management Operations

**Related stories:** PETPLAT-92

### Overview

Terraform state is stored in S3 (`petclinic-terraform-state`) with DynamoDB locking (`petclinic-terraform-locks`). These procedures handle common state problems without destructive actions.

### Procedure: Unlock a Stale State Lock

**When:** A `terraform plan/apply` fails with "Error acquiring the state lock" and the process that acquired it is no longer running.

**Who:** Terraform access + AWS CLI

**Time:** 2 minutes

**Steps:**

```bash
# 1. Get the lock ID from the error message, or query DynamoDB directly
aws dynamodb scan \
  --table-name petclinic-terraform-locks \
  --filter-expression "begins_with(LockID, :prefix)" \
  --expression-attribute-values '{":prefix": {"S": "petclinic/{env}/"}}' \
  --query 'Items[*].{LockID:LockID.S,Created:Info.S}' \
  --output table

# 2. Confirm no terraform process is actually running (check CI and other team members)

# 3. Force-unlock (use the ID from the error message or step 1 output)
terraform force-unlock LOCK_ID
```

**Verify:** `terraform plan` runs without "state lock" error.

---

### Procedure: Import an Existing Resource into State

**When:** A resource was created manually in AWS or outside Terraform and needs to be brought under Terraform management.

**Who:** Terraform access

**Time:** 5â€“10 minutes

**Steps:**

```bash
# 1. Find the resource ARN or ID in AWS Console or CLI

# 2. Add the resource block to the appropriate .tf file WITHOUT applying yet

# 3. Import the resource into state
terraform import {resource_type}.{name} {resource_id}
# Example:
terraform import aws_secretsmanager_secret.my_secret arn:aws:secretsmanager:eu-central-1:ACCOUNT:secret:name

# 4. Run plan to verify no unexpected changes
terraform plan
# Expected: "No changes" or only attribute diffs that are acceptable

# 5. Apply only if plan shows safe changes
terraform apply plan.out
```

---

### Procedure: Remove a Resource from State (Without Destroying)

**When:** A resource should no longer be managed by Terraform but must not be deleted (e.g., transferring ownership).

**Steps:**

```bash
# 1. Remove from state â€” the AWS resource is NOT deleted
terraform state rm {resource_type}.{name}
# Example:
terraform state rm aws_s3_bucket.legacy

# 2. Remove the resource block from the .tf file

# 3. Run terraform plan to confirm no references remain
terraform plan
```

---

### Procedure: Recover from Corrupted State

**When:** `terraform plan` shows unexpected destroy/recreate for resources that are actually healthy.

**Steps:**

```bash
# 1. List S3 state file versions
aws s3api list-object-versions \
  --bucket petclinic-terraform-state \
  --prefix petclinic/{env}/terraform.tfstate \
  --query 'Versions[*].[VersionId,LastModified,IsLatest]' \
  --output table

# 2. Download a known-good version for inspection
aws s3api get-object \
  --bucket petclinic-terraform-state \
  --key petclinic/{env}/terraform.tfstate \
  --version-id {PREVIOUS_VERSION_ID} \
  terraform.tfstate.bak

# 3. Inspect the backup â€” verify it reflects real AWS state
terraform show terraform.tfstate.bak

# 4. Restore the backup (upload as new current version)
aws s3 cp terraform.tfstate.bak \
  s3://petclinic-terraform-state/petclinic/{env}/terraform.tfstate

# 5. Re-run plan and verify
terraform plan
```

**Safety reminders:**
- Always use `terraform plan -out plan.out` and review before applying.
- Never run `terraform destroy` without reading the [Infrastructure: Safe Teardown](#infrastructure-safe-teardown-before-terraform-destroy) procedure first.
- The `block-destroy.sh` hook blocks `terraform destroy` at the CLI level. Contact the team lead to override.

---

## Infrastructure: Full Destroy and Rebuild Procedure

**Related stories:** PETPLAT-78, PETPLAT-90
**Also see:** [disaster-recovery.md Â§ Infrastructure Rebuild Procedure](disaster-recovery.md#infrastructure-rebuild-procedure) for the rebuild steps.

This procedure completely tears down and optionally recreates the entire Petclinic platform. Use it for: end-of-session cost saving, DR testing, or starting fresh after a misconfiguration.

---

### Part 1: Full Infrastructure Destroy

Resources created by Kubernetes operators (ALB, EBS PVs) are **not tracked by Terraform** and must be cleaned up first, or `terraform destroy` will fail with dependency errors.

**When:** Completely destroying a dev or prod environment.
**Who:** `kubectl` access + AWS CLI + Terraform.
**Time:** ~20â€“30 minutes.
**Note:** The `block-destroy.sh` safety hook intercepts `terraform destroy`. Acknowledge the prompt to proceed.

#### Step 1 â€” Pause ArgoCD auto-sync (dev only)

Prevents ArgoCD from re-creating resources during cleanup:

```bash
argocd app list --output name | grep "\-dev" | while read app; do
  argocd app set "$app" --sync-policy none
done
```

Or via ArgoCD UI: each application â†’ App Details â†’ Disable Auto-Sync.

#### Step 2 â€” Delete all ArgoCD Applications

Gracefully removes all Helm releases (pods, services, configmaps) from petclinic namespaces:

```bash
kubectl get applications -n argocd -o name | grep "{env}" | xargs kubectl delete -n argocd
```

Wait for pods to terminate:
```bash
kubectl get pods -n petclinic-{env} --watch
```

#### Step 3 â€” Delete the Kubernetes Ingress (triggers ALB deletion)

```bash
kubectl delete ingress petclinic-ingress -n petclinic-{env}
```

Wait for ALB deletion (~30â€“60 seconds):
```bash
aws elbv2 describe-load-balancers --region eu-central-1 \
  --query "LoadBalancers[*].{Name:LoadBalancerName,State:State.Code}" \
  --output table
# Expected: no ALBs with "petclinic" in the name
```

#### Step 4 â€” Delete PVCs to release EBS volumes

PVCs have `reclaimPolicy: Delete` â€” deleting the PVC deletes the underlying EBS volume:

```bash
kubectl delete pvc --all -n monitoring
kubectl delete pvc --all -n petclinic-{env}
```

Confirm EBS volumes are released:
```bash
aws ec2 describe-volumes --region eu-central-1 \
  --filters "Name=tag:kubernetes.io/cluster/petclinic-{env},Values=owned,shared" \
            "Name=status,Values=available" \
  --query 'Volumes[*].{ID:VolumeId,State:State}' --output table
# Expected: no results
```

#### Step 5 â€” Uninstall Karpenter

Karpenter must be removed before EKS destroy. If left running, Karpenter may provision new nodes during teardown, creating orphaned EC2 instances not tracked by Terraform:

```bash
helm uninstall karpenter -n kube-system
kubectl wait --for=delete pod -l app.kubernetes.io/name=karpenter -n kube-system --timeout=60s
```

#### Step 6 â€” Uninstall AWS Load Balancer Controller

```bash
helm uninstall aws-load-balancer-controller -n kube-system
```

#### Step 7 â€” Uninstall External Secrets Operator

```bash
helm uninstall external-secrets -n external-secrets
```

#### Step 8 â€” Delete petclinic and observability namespaces

```bash
kubectl delete namespace petclinic-{env} monitoring tracing --ignore-not-found
kubectl wait --for=delete namespace/petclinic-{env} --timeout=120s
```

#### Step 9 â€” Uninstall ArgoCD

```bash
kubectl delete namespace argocd --ignore-not-found
```

#### Step 10 â€” Run terraform destroy

```bash
cd terraform/environments/{env}
terraform destroy
```

Terraform displays all resources to be destroyed. Type `yes` to confirm.
Expected duration: ~15 minutes. Secrets Manager uses `recovery_window_in_days = 0` (dev) for immediate deletion.

#### Step 11 â€” Verify: no orphaned resources

```bash
# Orphaned EC2 instances (Karpenter-launched nodes)
aws ec2 describe-instances --region eu-central-1 \
  --filters "Name=tag:karpenter.sh/provisioner-name,Values=default" \
            "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name}' --output table

# Orphaned EBS volumes
aws ec2 describe-volumes --region eu-central-1 \
  --filters "Name=status,Values=available" \
            "Name=tag:kubernetes.io/cluster/petclinic-{env},Values=owned,shared" \
  --query 'Volumes[*].{ID:VolumeId,Size:Size}' --output table

# Orphaned load balancers
aws elbv2 describe-load-balancers --region eu-central-1 \
  --query "LoadBalancers[*].{Name:LoadBalancerName,State:State.Code}" --output table
```

All three should return no results. Delete any orphans manually before considering teardown complete.

---

### Part 2: Full Infrastructure Rebuild

Complete rebuild procedure: [`docs/disaster-recovery.md Â§ Infrastructure Rebuild Procedure`](disaster-recovery.md#infrastructure-rebuild-procedure).

| Step | Action | Est. Time |
|------|--------|-----------|
| 1 | Bootstrap Terraform state backend: `bash scripts/bootstrap-state.sh {env}` | 1 min |
| 2 | Apply Terraform: `cd terraform/environments/{env} && terraform init && terraform plan -out plan.out && terraform apply plan.out` | 10â€“15 min |
| 3 | Configure kubectl: `aws eks update-kubeconfig --region eu-central-1 --name petclinic-{env}-eks` | 30 sec |
| 4 | Bootstrap cluster add-ons (ESO, LB Controller, Karpenter, observability): `bash scripts/up.sh {env}` | 5 min |
| 5 | Apply base K8s manifests: namespaces, observability namespace, ESO CRDs, network policies | 2 min |
| 6 | Install ArgoCD: `kubectl apply -f k8s/argocd/install/` + `kubectl apply -f k8s/argocd/argocd-rbac-cm.yaml` + AppProjects + wait for readiness | 2 min |
| 7 | Register ArgoCD Applications: `kubectl apply -f k8s/argocd/appproject-dev.yaml -f k8s/argocd/appproject-prod.yaml` then `kubectl apply -f k8s/argocd/applications/{env}/` | 30 sec |
| 8 | Run smoke test: `bash scripts/smoke-test.sh {env}` | 2 min |

**Total rebuild time target: < 30 minutes** (assumes images already exist in ECR).

---

## Known Issues and Workarounds

### KI-001: MSYS_NO_PATHCONV=1 Required on Git Bash / Windows

**Symptom:** AWS CLI commands that accept a path-style parameter (e.g., SSM parameter names `/petclinic/dev/alb-dns-name`) fail with a `ValidationException: Parameter name must be a fully qualified name` error when run from Git Bash on Windows.

**Root cause:** MSYS (the POSIX layer under Git Bash) converts any argument starting with `/` to a Windows path. `/petclinic/dev/alb-dns-name` becomes `C:\petclinic\dev\alb-dns-name` before the AWS CLI ever sees it.

**Fix:** Prefix the AWS CLI call with `MSYS_NO_PATHCONV=1`:
```bash
MSYS_NO_PATHCONV=1 aws ssm put-parameter \
  --name "/petclinic/dev/alb-dns-name" \
  ...
```
This env var is a no-op on Linux and macOS — it is safe to include unconditionally.

**Affected scripts:** `install-lb-controller.sh` already includes this prefix. Apply the same pattern anywhere an AWS CLI call uses a `/`-prefixed path argument.

---

### KI-002: ECR Empty After Destroy — Use workflow_dispatch to Rebuild Images

**Symptom:** After `destroy.sh` + `up.sh`, pods get `ErrImagePull` or `ImagePullBackOff`. ECR repositories are recreated empty by Terraform; images must be rebuilt.

**Root cause:** `destroy.sh` deletes ECR repos (including all images). `up.sh` re-creates the empty repos. The CI pipeline (`build-push.yml`) is triggered by file changes in the application repo — if no source files changed since the last push, `dorny/paths-filter` detects zero changes and skips all builds.

**Wrong approach:** Pushing an empty commit or dummy file change. This is fragile and pollutes Git history.

**Correct approach:** Use GitHub Actions `workflow_dispatch` to force a full rebuild:
1. Go to the application repo fork on GitHub
2. Actions → "CI - Build and Push" → Run workflow
3. Set `force_rebuild_all` = `true`
4. Click "Run workflow"

All 8 services will be built and pushed to both `petclinic-dev` and `petclinic-prod` ECR repos.

---

### KI-003: ESO Must Be Ready Before ArgoCD Apps Are Registered

**Symptom:** On a fresh `up.sh` run in dev, pods for `customers-service`, `visits-service`, `vets-service`, and `genai-service` immediately fail with `CreateContainerConfigError`. `kubectl describe pod` shows `Error: secret "rds-credentials" not found` or `secret "openai-api-key" not found`.

**Root cause:** Dev ArgoCD auto-sync fires immediately after `kubectl apply -f k8s/argocd/applications/dev/`. If the External Secrets Operator `SecretStore` is not yet ready, the ExternalSecret CRs cannot sync, so the K8s Secrets referenced by pods do not exist yet.

**Fix:** Already applied in `up.sh` — ESO is installed (Step 4) before ArgoCD apps are registered (Step 5). If you see this issue on a manual run, install ESO first:
```bash
bash scripts/install-eso.sh --env dev
# Wait for ESO to show "SecretSyncedError" or "SecretSynced" on ExternalSecrets:
kubectl get externalsecret -n petclinic-dev
# Then register ArgoCD apps:
kubectl apply -f k8s/argocd/appproject-dev.yaml -n argocd
kubectl apply -f k8s/argocd/applications/dev/ -n argocd
```

---

### KI-004: Second Prod Destroy Fails with DBSnapshotAlreadyExists

**Symptom:** `terraform destroy` on prod fails with:
```
Error: creating DB Snapshot: DBSnapshotAlreadyExists: Cannot create the snapshot because a snapshot with the identifier "petclinic-prod-mysql-final" already exists.
```

**Root cause:** Prod uses `skip_final_snapshot = false`. Terraform creates `petclinic-prod-mysql-final` on the first destroy. On the second destroy, the snapshot already exists and Terraform cannot create it again.

**Fix:** Already applied in `destroy.sh` Step 1.8 — the script checks for and deletes the existing final snapshot before running `terraform destroy`. If you hit this manually:
```bash
aws rds delete-db-snapshot \
  --db-snapshot-identifier petclinic-prod-mysql-final \
  --region eu-central-1
# Wait ~30 seconds, then re-run terraform destroy
```

---

### KI-005: Karpenter NodePool Tag Substitution for Prod

**Symptom:** Karpenter does not provision nodes in prod, or nodes are provisioned into the wrong cluster.

**Root cause:** `k8s/base/karpenter/nodepool.yaml` is written for `petclinic-dev`. It uses `petclinic-dev` in `subnetSelectorTerms`, `securityGroupSelectorTerms`, and `instanceProfile`. Running `kubectl apply -f nodepool.yaml` directly in prod would configure Karpenter to use dev resources.

**Fix:** `up.sh` already applies the substitution: `sed "s/petclinic-dev/petclinic-${ENV}/g" nodepool.yaml | kubectl apply -f -`. If applying manually, always use:
```bash
sed "s/petclinic-dev/petclinic-prod/g" k8s/base/karpenter/nodepool.yaml | kubectl apply -f -
```
