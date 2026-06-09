# Secret Rotation

**Last Updated:** 2026-06-09
**Purpose:** Procedures for safely rotating every secret type used by the platform.

## Table of Contents
1. [RDS Master Password](#1-rds-master-password)
2. [RDS Application Credentials (if separate)](#2-rds-application-credentials-if-separate)
3. [OpenAI API Key](#3-openai-api-key)
4. [Alertmanager SMTP App Password](#4-alertmanager-smtp-app-password)
5. [GitHub Actions OIDC (no rotation needed)](#5-github-actions-oidc-no-rotation-needed)
6. [How ESO Refresh Works](#6-how-eso-refresh-works)

---

## 1. RDS Master Password

### Procedure: Rotate RDS master password

**When:** Quarterly, or immediately on suspected compromise
**Who:** AWS admin (IAM: `secretsmanager:PutSecretValue`, `rds:ModifyDBInstance`)
**Time:** ~10 minutes (includes pod restart)

**Steps:**
1. Generate a new password (min 20 chars, no `@`, `/`, `"`, `\`):
   ```bash
   openssl rand -base64 30 | tr -d '@/"\\'
   ```
2. Update the secret in Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id petclinic/{env}/rds-credentials \
     --secret-string "{\"username\":\"petclinic\",\"password\":\"NEW_PASSWORD\"}"
   ```
3. Update RDS with the new password:
   ```bash
   aws rds modify-db-instance \
     --db-instance-identifier petclinic-{env}-mysql \
     --master-user-password NEW_PASSWORD \
     --apply-immediately
   ```
4. Wait for RDS to apply the change (~2 minutes):
   ```bash
   aws rds wait db-instance-available \
     --db-instance-identifier petclinic-{env}-mysql
   ```
5. Force ESO to re-sync the K8s secret immediately (default refresh is 1h):
   ```bash
   kubectl annotate externalsecret rds-credentials \
     -n petclinic-{env} \
     force-sync="$(date +%s)" --overwrite
   ```
6. Restart the 3 DB-backed services to pick up the new credentials:
   ```bash
   kubectl rollout restart deployment/customers-service \
     deployment/visits-service \
     deployment/vets-service \
     -n petclinic-{env}
   kubectl rollout status deployment/customers-service \
     deployment/visits-service \
     deployment/vets-service \
     -n petclinic-{env} --timeout=180s
   ```

**Verify:**
- `kubectl get secret rds-credentials -n petclinic-{env} -o jsonpath='{.data.password}' | base64 -d` — should decode to the new password
- Check pod logs: `kubectl logs -n petclinic-{env} -l app.kubernetes.io/name=customers-service --tail=20`
- No `HikariPool` or `Access denied` errors

**Rollback:**
- Re-run steps 2–6 with the previous password

---

## 2. RDS Application Credentials (if separate)

The current design uses a single RDS master user (`petclinic`) for all application services. If you later create a separate application user with reduced privileges:

**Steps:**
1. Create the new user in MySQL and grant permissions:
   ```bash
   kubectl exec -it -n petclinic-dev deployment/customers-service -- \
     mysql -h petclinic-{env}-mysql.{endpoint}.rds.amazonaws.com \
       -u petclinic -p{CURRENT_PASSWORD} \
       -e "CREATE USER 'app'@'%' IDENTIFIED BY 'NEW_APP_PASSWORD'; GRANT SELECT,INSERT,UPDATE,DELETE ON petclinic.* TO 'app'@'%';"
   ```
2. Store the new credentials in Secrets Manager under a new key (e.g., `petclinic/{env}/rds-app-credentials`).
3. Update `k8s/base/external-secrets/rds-credentials.yaml` to point to the new key.
4. Apply and restart affected deployments.

---

## 3. OpenAI API Key

### Procedure: Rotate the OpenAI API key

**When:** On key compromise, or when revoking a developer's access
**Who:** AWS admin + OpenAI account owner
**Time:** ~5 minutes

**Steps:**
1. Generate a new key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys) and revoke the old one.
2. Update Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id petclinic/{env}/openai-api-key \
     --secret-string "{\"OPENAI_API_KEY\":\"sk-...NEW_KEY...\"}"
   ```
3. Force ESO to re-sync:
   ```bash
   kubectl annotate externalsecret openai-api-key \
     -n petclinic-{env} \
     force-sync="$(date +%s)" --overwrite
   ```
4. Restart genai-service:
   ```bash
   kubectl rollout restart deployment/genai-service -n petclinic-{env}
   kubectl rollout status deployment/genai-service -n petclinic-{env} --timeout=120s
   ```

**Verify:**
- `kubectl logs -n petclinic-{env} deployment/genai-service --tail=20` — no `401 Unauthorized` from OpenAI

---

## 4. Alertmanager SMTP App Password

The SMTP credentials live in AWS Secrets Manager (`petclinic/alertmanager-smtp`) and are patched into the `alertmanager-config` K8s Secret at install time.

### Procedure: Rotate the Gmail App Password

**When:** On compromise, or after revoking the old app password in Google Account settings
**Who:** AWS admin + Google account owner
**Time:** ~5 minutes

**Steps:**
1. Generate a new App Password at `myaccount.google.com/apppasswords` (format: `xxxx xxxx xxxx xxxx`).
2. Update Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id petclinic/alertmanager-smtp \
     --secret-string '{"email":"you@gmail.com","password":"xxxx xxxx xxxx xxxx"}'
   ```
3. Re-patch the Alertmanager K8s Secret using the install script:
   ```bash
   bash scripts/install-observability.sh --env {dev|prod}
   ```
   The script auto-loads from Secrets Manager and patches the secret in-place.
4. Alertmanager will reload its config automatically within ~30 seconds (it watches the volume mount).

**Verify:**
- Port-forward and send a test alert:
  ```bash
  kubectl port-forward svc/alertmanager -n monitoring 9093:9093 &
  curl -s -XPOST http://localhost:9093/api/v1/alerts \
    -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"RotationTest","severity":"warning","namespace":"petclinic-dev"}}]'
  ```
- Confirm email arrives within ~5 minutes.

---

## 5. GitHub Actions OIDC (no rotation needed)

The GitHub Actions → AWS trust uses OIDC federation (`terraform/modules/github-oidc/`). There are no long-lived credentials to rotate. The OIDC tokens are short-lived JWTs issued per workflow run.

If the IAM role or OIDC provider is compromised:
```bash
# Revoke by removing the role's trust policy or deleting the OIDC provider in IAM
aws iam delete-role --role-name petclinic-github-actions-role
# Then re-apply Terraform to recreate it
terraform apply -target=module.github_oidc
```

---

## 6. How ESO Refresh Works

External Secrets Operator syncs Secrets Manager → K8s Secrets on a schedule set by `refreshInterval: 1h` in each `ExternalSecret` CR.

- **Automatic:** Every 1 hour, ESO polls Secrets Manager and updates the K8s Secret if the value changed.
- **Immediate (manual trigger):** Annotate the `ExternalSecret` resource:
  ```bash
  kubectl annotate externalsecret {secret-name} \
    -n {namespace} \
    force-sync="$(date +%s)" --overwrite
  ```
- **Pod restart required:** ESO updating the K8s Secret does NOT restart pods. Pods that loaded the secret as env vars at startup will continue using the old value until restarted:
  ```bash
  kubectl rollout restart deployment/{service-name} -n {namespace}
  ```
  Pods that mount the secret as a volume (e.g., Alertmanager) pick up changes automatically within ~60 seconds.
