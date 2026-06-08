# Rollback Runbook

**Last Updated:** 2026-06-08
**Purpose:** Step-by-step procedures for rolling back a failed or bad deployment in the petclinic-platform. Three methods are documented in order of preference.

## Table of Contents

1. [Method 1: GitOps Rollback (Preferred)](#method-1-gitops-rollback-preferred)
2. [Method 2: ArgoCD Native Rollback](#method-2-argocd-native-rollback)
3. [Method 3: kubectl rollout undo (Emergency)](#method-3-kubectl-rollout-undo-emergency)
4. [Verify Rollback Success](#verify-rollback-success)

---

## Method 1: GitOps Rollback (Preferred)

**When:** A recent `ci: update image tags` commit introduced a bad image tag. Reverting the commit restores the previous tag and ArgoCD re-deploys the working version.

**Who:** Engineer with write access to `petclinic-platform` repo

**Time:** ~3–5 minutes (time for ArgoCD to detect and sync)

**Steps:**

1. Find the commit that introduced the bad tag:
   ```bash
   git log --oneline helm-values/<service>.yaml
   # Example output:
   # a1b2c3d ci: update image tags to badsha7 (customers-service)
   # e4f5g6h ci: update image tags to goodsha (customers-service)
   ```

2. Revert the offending commit (creates a new revert commit — does not rewrite history):
   ```bash
   git revert <bad-commit-sha> --no-edit
   git push origin main
   ```

   If only one service needs rolling back and the commit changed multiple services, edit the revert commit or use `yq` to restore just that file:
   ```bash
   # Restore a single service to a specific tag
   yq -i '.image.tag = "<previous-sha>"' helm-values/<service>.yaml
   git add helm-values/<service>.yaml
   git commit -m "fix: rollback <service> to <previous-sha>"
   git push origin main
   ```

3. ArgoCD detects the Git change automatically:
   - **Dev:** auto-syncs within ~3 minutes.
   - **Prod:** requires manual sync approval in ArgoCD UI or CLI (see [Verify](#verify-rollback-success)).

**Verify:**
- Run `git log --oneline -3 helm-values/<service>.yaml` — confirm the reverted tag is the HEAD value.
- Check ArgoCD sync status (see [Verify Rollback Success](#verify-rollback-success)).
- Check pod image: `kubectl get pod -n petclinic-{env} -l app.kubernetes.io/name=<service> -o jsonpath='{.items[0].spec.containers[0].image}'`

**Rollback of the rollback:**
- If the revert itself was wrong, revert the revert: `git revert HEAD --no-edit && git push`

---

## Method 2: ArgoCD Native Rollback

**When:** You want to roll back to a previous ArgoCD sync without touching Git. Use this for immediate mitigation when a Git revert would take too long. Note: ArgoCD will re-sync on the next Git change unless auto-sync is disabled first.

**Who:** Engineer with ArgoCD admin access

**Time:** ~1–2 minutes

**Steps:**

1. Open the ArgoCD UI:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8443:443
   # Navigate to https://localhost:8443
   ```
   Or use the CLI:
   ```bash
   argocd login localhost:8443 --insecure
   ```

2. **Via UI:** Open the application (`<service>-dev` or `<service>-prod`), click **History and Rollback**, select the last known-good sync, and click **Rollback**.

3. **Via CLI:**
   ```bash
   # List sync history for an application
   argocd app history <service>-{env}

   # Roll back to a specific history ID (shown in the history list)
   argocd app rollback <service>-{env} <history-id>
   ```

4. For dev environments where auto-sync is enabled, disable it first to prevent ArgoCD from immediately re-syncing back to the bad Git state:
   ```bash
   argocd app set <service>-dev --sync-policy none
   argocd app rollback <service>-dev <history-id>
   ```
   Re-enable auto-sync after the Git revert (Method 1) is merged:
   ```bash
   argocd app set <service>-dev --sync-policy automated --self-heal --auto-prune
   ```

**Verify:**
- `argocd app get <service>-{env}` — check `Status: Healthy` and `Sync: Synced`.
- Confirm the pod is running the intended image (see [Verify Rollback Success](#verify-rollback-success)).

**Rollback of the rollback:**
- Re-enable auto-sync and trigger a fresh sync: `argocd app sync <service>-{env}`

---

## Method 3: kubectl rollout undo (Emergency)

**When:** ArgoCD is unavailable or unreachable and you need an immediate fix without waiting for GitOps. This is an out-of-band change — ArgoCD will overwrite it on the next sync unless auto-sync is disabled.

**Who:** Engineer with `kubectl` cluster access (kubeconfig for the target cluster)

**Time:** ~30 seconds

**Steps:**

1. Connect to the target cluster (if not already):
   ```bash
   aws eks update-kubeconfig --name petclinic-{env} --region eu-central-1
   ```

2. Roll back the Deployment to its previous revision:
   ```bash
   kubectl rollout undo deployment/<service> -n petclinic-{env}
   ```

3. Monitor rollout:
   ```bash
   kubectl rollout status deployment/<service> -n petclinic-{env}
   ```

4. Immediately follow up with a Git revert (Method 1) so the GitOps state matches the cluster state. If ArgoCD auto-syncs before you commit the revert, it will undo your kubectl change.

   To buy time, pause ArgoCD auto-sync for the affected app:
   ```bash
   argocd app set <service>-dev --sync-policy none
   ```

**Verify:**
- `kubectl rollout history deployment/<service> -n petclinic-{env}` — confirm the active revision.
- Check pod readiness (see [Verify Rollback Success](#verify-rollback-success)).

**Rollback of the rollback:**
- `kubectl rollout undo deployment/<service> -n petclinic-{env}` rolls forward one revision again.
- Then re-enable ArgoCD sync.

---

## Verify Rollback Success

Run these checks after any rollback method to confirm the service has recovered:

```bash
# 1. Check pods are running (substitute env and service name)
kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name=<service>

# 2. Confirm the pod is running the expected image tag
kubectl get pod -n petclinic-{env} -l app.kubernetes.io/name=<service> \
  -o jsonpath='{.items[0].spec.containers[0].image}'

# 3. Confirm the deployment is stable (no restart loop)
kubectl rollout status deployment/<service> -n petclinic-{env}

# 4. Check health endpoint via port-forward
kubectl port-forward svc/<service> -n petclinic-{env} 8080:<service-port>
curl -s http://localhost:8080/actuator/health | jq .status

# 5. Run the smoke test script
scripts/smoke-test.sh petclinic-{env}
```

ArgoCD application health indicators:
```bash
# Check ArgoCD sees the app as Healthy and Synced
argocd app get <service>-{env} | grep -E "Health Status|Sync Status"
```

Expected output after a successful rollback:
```
Health Status:  Healthy
Sync Status:    Synced
```
