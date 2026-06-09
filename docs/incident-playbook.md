# Incident Playbook

**Last Updated:** 2026-06-09

Common failure scenarios for the Petclinic platform, with diagnosis commands and resolution steps.

---

## Table of Contents

1. [Pod in CrashLoopBackOff](#pod-in-crashloopbackoff)
2. [Service Not Registering with Eureka](#service-not-registering-with-eureka)
3. [Database Connection Failures](#database-connection-failures)
4. [Image Pull Errors from ECR](#image-pull-errors-from-ecr)
5. [Node Not Ready](#node-not-ready)
6. [High Latency / Timeouts](#high-latency--timeouts)

---

## Pod in CrashLoopBackOff

**Symptoms:**
- `kubectl get pods -n petclinic-{env}` shows `CrashLoopBackOff` or `Error`
- Service unreachable; ArgoCD shows `Degraded`

**Diagnosis:**
```bash
# 1. Which pod is crashing?
kubectl get pods -n petclinic-{env}

# 2. Get crash reason from current container
kubectl logs -n petclinic-{env} {pod-name} --tail=100

# 3. Get crash reason from the previous container (if already restarted)
kubectl logs -n petclinic-{env} {pod-name} --previous --tail=100

# 4. Check events for OOMKilled, Liveness probe failures, etc.
kubectl describe pod -n petclinic-{env} {pod-name} | tail -30
```

**Common causes and fixes:**

| Exit code / event | Cause | Fix |
|-------------------|-------|-----|
| OOMKilled | Container exceeded memory limit | Increase `resources.limits.memory` in `helm-values/{service}.yaml` |
| Exit 1 + config error in logs | Config Server unreachable at startup | Check config-server pod is Running first; verify init container passed |
| Exit 1 + `Connection refused 8761` | Discovery Server unreachable | Check discovery-server pod is Running |
| Exit 1 + `Could not connect to database` | RDS not reachable or wrong credentials | See [Database Connection Failures](#database-connection-failures) |
| Liveness probe failed | JVM startup too slow | Increase `livenessProbe.initialDelaySeconds` |

**Resolution:**
```bash
# After fixing the underlying cause, force a restart
kubectl rollout restart deployment/{service} -n petclinic-{env}

# Verify rollout completes
kubectl rollout status deployment/{service} -n petclinic-{env}
```

---

## Service Not Registering with Eureka

**Symptoms:**
- Service pod is Running but API Gateway returns 503 or routes don't work
- Eureka UI shows service missing: `kubectl port-forward svc/discovery-server -n petclinic-{env} 8761:8761`

**Diagnosis:**
```bash
# 1. Is discovery-server itself running?
kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name=discovery-server

# 2. Check the failing service's logs for Eureka registration errors
kubectl logs -n petclinic-{env} {service-pod} | grep -i "eureka\|register\|discov"

# 3. Can the service reach discovery-server DNS?
kubectl run -it --rm debug -n petclinic-{env} --image=curlimages/curl --restart=Never -- \
  curl -sf http://discovery-server:8761/eureka/apps

# 4. Check SPRING_PROFILES_ACTIVE includes 'docker'
kubectl get pod -n petclinic-{env} {pod-name} -o jsonpath='{.spec.containers[0].env}'
```

**Common causes and fixes:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| DNS resolution fails | Wrong service name in Eureka URL | Verify `EUREKA_CLIENT_SERVICEURL_DEFAULTZONE` in `helm-values/{service}.yaml` |
| Timeout connecting to 8761 | Init container didn't wait long enough | Check init container logs; restart pod |
| Missing `docker` profile | `SPRING_PROFILES_ACTIVE` env var missing | Add `docker` to `helm-values/{service}.yaml` |

**Resolution:**
```bash
# Restart the service pod after fixing config
kubectl rollout restart deployment/{service} -n petclinic-{env}
```

---

## Database Connection Failures

**Symptoms:**
- customers-service, visits-service, or vets-service crashloops with SQL errors
- Logs show `Could not create connection to database server`

**Diagnosis:**
```bash
# 1. Check logs for the exact error
kubectl logs -n petclinic-{env} {service-pod} --previous | grep -i "sql\|database\|connect\|mysql"

# 2. Verify the ExternalSecret fetched the credentials
kubectl get externalsecret -n petclinic-{env}
kubectl get secret -n petclinic-{env} rds-credentials

# 3. Test connectivity to RDS from a debug pod
kubectl run -it --rm mysql-debug -n petclinic-{env} --image=mysql:8 --restart=Never -- \
  mysql -h petclinic-dev-mysql.{region}.rds.amazonaws.com -u petclinic -p

# 4. Check RDS instance status in AWS
aws rds describe-db-instances \
  --db-instance-identifier petclinic-{env}-mysql \
  --query 'DBInstances[0].DBInstanceStatus'

# 5. Check security group allows EKS node SG to reach RDS on 3306
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values={rds-sg-id}"
```

**Common causes and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `Access denied for user` | Wrong credentials in secret | Run `kubectl edit secret rds-credentials -n petclinic-{env}` or re-sync ExternalSecret |
| `Communications link failure` | Network unreachable | Check SG rule: node-sg → rds-sg:3306 |
| `Unknown database petclinic` | DB schema not initialized | Connect and run schema SQL manually |
| `SecretNotFound` | ESO can't find the secret | Check `aws secretsmanager get-secret-value --secret-id petclinic/{env}/mysql-credentials` |

**Resolution:**
```bash
# Force re-sync of ExternalSecret
kubectl annotate externalsecret rds-credentials -n petclinic-{env} \
  force-sync=$(date +%s) --overwrite

# After credentials are correct
kubectl rollout restart deployment/{service} -n petclinic-{env}
```

---

## Image Pull Errors from ECR

**Symptoms:**
- Pod shows `ErrImagePull` or `ImagePullBackOff`
- `kubectl describe pod` shows `Failed to pull image ... unauthorized`

**Diagnosis:**
```bash
# 1. Which pod fails?
kubectl get pods -n petclinic-{env} | grep -E "ErrImagePull|ImagePullBackOff"

# 2. Get the image reference
kubectl describe pod -n petclinic-{env} {pod-name} | grep "Image:"

# 3. Check ECR repo exists and image tag is present
aws ecr describe-images \
  --repository-name petclinic-{env}/{service} \
  --image-ids imageTag={tag}

# 4. Verify node IAM role has ECR pull permissions
aws iam list-attached-role-policies \
  --role-name petclinic-{env}-node-role

# 5. Check if the ECR repo is in the correct region (eu-central-1)
aws ecr describe-repositories \
  --repository-names petclinic-{env}/{service} \
  --region eu-central-1
```

**Common causes and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `unauthorized` | Node role missing `AmazonEC2ContainerRegistryReadOnly` | Add policy in Terraform, apply |
| `repository does not exist` | Wrong repo name or region | Check `helm-values/{service}.yaml` image field |
| `manifest unknown` | Tag doesn't exist in ECR | Push the image first via CI pipeline |
| `no basic auth credentials` | Token expired | ECR tokens expire after 12h; node should auto-renew via IMDSv2 |

**Resolution:**
```bash
# After fixing permissions/image, delete the pod to force re-pull
kubectl delete pod -n petclinic-{env} {pod-name}
```

---

## Node Not Ready

**Symptoms:**
- `kubectl get nodes` shows `NotReady` for one or more nodes
- Pods on that node move to `Unknown` state

**Diagnosis:**
```bash
# 1. Which node is not ready?
kubectl get nodes

# 2. Get node conditions
kubectl describe node {node-name} | grep -A 5 "Conditions:"

# 3. Check kubelet and system logs on the node
kubectl get events --field-selector involvedObject.name={node-name} -A

# 4. Check if AWS terminated the EC2 instance
aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values={node-name}" \
  --query 'Reservations[0].Instances[0].State.Name'

# 5. Check EKS node group health
aws eks describe-nodegroup \
  --cluster-name petclinic-{env} \
  --nodegroup-name petclinic-{env}-nodes \
  --query 'nodegroup.health'
```

**Common causes and fixes:**

| Cause | Symptom | Fix |
|-------|---------|-----|
| EC2 instance terminated by AWS | Node disappears from `kubectl get nodes` | EKS auto-replaces; wait 3–5 min |
| DiskPressure | `Condition: DiskPressure=True` | Increase EBS volume in Terraform launch template |
| MemoryPressure | `Condition: MemoryPressure=True` | Reduce pod memory requests or add nodes |
| Network plugin crash | `CNI plugin not initialized` | Delete aws-node DaemonSet pod on that node to trigger restart |
| Kubelet certificate expired | `x509: certificate has expired` | Node replacement needed |

**Resolution:**
```bash
# Cordon and drain to evacuate pods before investigating
kubectl cordon {node-name}
kubectl drain {node-name} --ignore-daemonsets --delete-emptydir-data

# After investigation, uncordon or let EKS replace
kubectl uncordon {node-name}
```

---

## High Latency / Timeouts

**Symptoms:**
- API Gateway returning slow responses or timeouts
- Grafana shows p95 latency > 500ms (triggers HighLatency alert)
- Users experiencing slow page loads

**Diagnosis:**
```bash
# 1. Check Prometheus for latency metrics
kubectl port-forward svc/prometheus -n monitoring 9090:9090
# Query: histogram_quantile(0.95, rate(http_server_requests_seconds_bucket[5m]))

# 2. Check which service is slow (Grafana → Per-Service dashboard)
kubectl port-forward svc/grafana -n monitoring 3000:3000
# Dashboard: "Petclinic — Per-Service Metrics"

# 3. Check JVM heap usage (GC pauses → latency spikes)
# Grafana: "Petclinic — JVM Metrics" → Heap Memory panel

# 4. Check pod resource pressure
kubectl top pods -n petclinic-{env}
kubectl top nodes

# 5. Check Zipkin for slow traces
kubectl port-forward svc/zipkin -n tracing 9411:9411
# UI → Find Traces → sort by Duration

# 6. Check database query times (if DB-backed service is slow)
kubectl run -it --rm mysql-debug -n petclinic-{env} --image=mysql:8 --restart=Never -- \
  mysql -h petclinic-{env}-mysql.{region}.rds.amazonaws.com \
        -u petclinic -p -e "SHOW PROCESSLIST;"
```

**Common causes and fixes:**

| Cause | Indicator | Fix |
|-------|-----------|-----|
| JVM GC pause | High GC pause duration in Grafana | Increase heap with `-Xmx` in container env; increase memory limit |
| CPU throttling | Pod CPU near limit | Increase `resources.limits.cpu` in `helm-values/{service}.yaml` |
| DB slow queries | RDS CPU high, long processlist | Add DB index or increase RDS instance class |
| Config Server slow | All services latency spikes together | Restart config-server; check Git remote is accessible |
| Cold start (single replica) | One-off spike after deploy | Add readiness probe warm-up time; add replicas in prod |

**Resolution:**
```bash
# Scale up service replicas temporarily in dev
kubectl scale deployment/{service} --replicas=2 -n petclinic-{env}

# After identifying the root cause, commit a fix to helm-values/{service}.yaml
# ArgoCD will apply it automatically (dev) or on manual sync (prod)
```
