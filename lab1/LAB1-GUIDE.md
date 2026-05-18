# Session 1 Lab Guide — Deploy Zen Pharma Platform Manually

**Prerequisites:** Your EKS cluster is up and `kubectl` is configured against it. Your RDS instance must be provisioned via `zen-infra` before starting — the services will fail to start without a reachable database.

Verify before starting:
```bash
kubectl cluster-info
kubectl get nodes
```

You should see your nodes in `Ready` state. If not, fix your kubeconfig before continuing.

---

## Before You Deploy — Set Your RDS Endpoint

Every service that connects to the database reads `DB_HOST` from its ConfigMap. The manifests in `lab1/` contain a placeholder endpoint that **must be replaced** with your own RDS address before you apply anything.

**Get your RDS endpoint:**
```bash
export DB_HOST=$(aws rds describe-db-instances \
  --query 'DBInstances[?DBInstanceIdentifier==`pharma-dev-postgres`].Endpoint.Address' \
  --output text)
echo $DB_HOST
# Expected: pharma-dev-postgres.<unique-id>.us-east-1.rds.amazonaws.com
```

**Replace the endpoint in all manifests:**
```bash
# macOS
find lab1/ -name "*.yaml" -exec \
  sed -i '' "s|DB_HOST:.*rds\.amazonaws\.com|DB_HOST: $DB_HOST|g" {} +

# Linux / Cloud9
find lab1/ -name "*.yaml" -exec \
  sed -i "s|DB_HOST:.*rds\.amazonaws\.com|DB_HOST: $DB_HOST|g" {} +
```

**Verify the replacement:**
```bash
grep "DB_HOST" lab1/*.yaml
# Every line should show your actual RDS endpoint, not a stale one
```

> **Why this matters:** If the endpoint is wrong, all database-dependent services will fail on startup with `UnknownHostException`. The pods will enter `CrashLoopBackOff`. The fix is always to update the ConfigMap and restart the deployment — not to touch the application code.

---

## What We Are Deploying

The Zen Pharma platform has 9 microservices. Today you will deploy all of them to the `dev` namespace using raw Kubernetes manifests — no automation, no templating, just `kubectl apply`.

| Service | Port | Language | Secrets Needed |
|---|---|---|---|
| auth-service | 8081 | Spring Boot | db-credentials, jwt-secret |
| api-gateway | 8080 | Spring Boot | db-credentials, jwt-secret |
| drug-catalog-service | 8082 | Spring Boot | db-credentials |
| inventory-service | 8083 | Spring Boot | db-credentials |
| manufacturing-service | 8085 | Spring Boot | db-credentials |
| supplier-service | 8084 | Spring Boot | db-credentials |
| qc-service | 8086 | Spring Boot | none |
| notification-service | 3000 | Node.js | db-credentials |
| pharma-ui | 80 | React / nginx | none |

By the end of this lab, all 9 services will be running in the `dev` namespace.

---

## Step 1 — Clone the Repository

```bash
git clone https://github.com/<your-org>/zen-gitops.git
cd zen-gitops
```

All manifest files for this lab are in the `lab1/` directory.

---

## Step 2 — Create the Namespace

```bash
kubectl apply -f lab1/00-namespace.yaml
```

Verify:
```bash
kubectl get namespace dev
```

Expected output:
```
NAME   STATUS   AGE
dev    Active   5s
```

---

## Step 3 — Apply RBAC

```bash
kubectl apply -f lab1/01-rbac.yaml
```

This creates a `pharma-deployer` Role in the `dev` namespace that allows deployment operations.

Verify:
```bash
kubectl get role pharma-deployer -n dev
kubectl get rolebinding pharma-deployer-binding -n dev
```

---

## Step 4 — Create Secrets

Secrets must exist **before** pods start. Pods that reference a missing secret will fail immediately with `CreateContainerConfigError`.

Use the credentials that match your RDS instance. The username is whatever you configured when provisioning via `zen-infra` (default: `pharmaadmin`). Get the password from AWS Secrets Manager or your Terraform outputs.

```bash
# Database credentials — used by 7 of the 9 services.
# The secret needs both DB_* and SPRING_DATASOURCE_* keys because
# different services reference different variable names.
kubectl create secret generic db-credentials \
  --from-literal=DB_USERNAME=pharmaadmin \
  --from-literal=DB_PASSWORD=<YOUR_DB_PASSWORD> \
  --from-literal=SPRING_DATASOURCE_USERNAME=pharmaadmin \
  --from-literal=SPRING_DATASOURCE_PASSWORD=<YOUR_DB_PASSWORD> \
  -n dev

# JWT signing key — used by auth-service and api-gateway
kubectl create secret generic jwt-secret \
  --from-literal=JWT_SECRET=mysupersecretjwtkey256bitslongkey \
  -n dev
```

Or run the provided script (edit it with your password first):
```bash
bash lab1/02-create-secrets.sh
```

Verify:
```bash
kubectl get secrets -n dev
```

Expected output:
```
NAME             TYPE     DATA   AGE
db-credentials   Opaque   4      5s
jwt-secret       Opaque   1      3s
```

Peek at the values (note: base64 is NOT encryption):
```bash
kubectl get secret db-credentials -n dev \
  -o jsonpath='{.data.DB_USERNAME}' | base64 -d && echo
```

> **Discussion point:** We are typing passwords directly into the terminal. The secret is stored in etcd as base64. Anyone with `kubectl get secret` access can decode it. In Session 3, External Secrets Operator will replace this step entirely — secrets will be pulled from AWS Secrets Manager automatically.

---

## Step 5 — Deploy auth-service First

We start with auth-service because it is the most complete service — it uses a ConfigMap, two Secrets, a ServiceAccount, liveness and readiness probes, and a read-only filesystem with a `/tmp` volume.

```bash
kubectl apply -f lab1/auth-service.yaml
```

This creates 4 resources at once:
- `ServiceAccount/auth-service`
- `ConfigMap/auth-service`
- `Deployment/auth-service`
- `Service/auth-service`

Watch the pod come up:
```bash
kubectl get pods -n dev -w
```

Press `Ctrl+C` when the pod reaches `Running`.

Describe the pod to understand every field:
```bash
kubectl describe pod -l app=auth-service -n dev
```

Read through the output. Focus on:
- `Events` section at the bottom — this is your first debug tool
- `Containers.auth-service.Liveness` and `Readiness` — see the probe config
- `Volumes` — note the `tmp` emptyDir

Check the logs:
```bash
kubectl logs -l app=auth-service -n dev
```

> **Expected:** If you completed the "Before You Deploy" step and created secrets correctly, the pod should reach `1/1 Running` within 60-90 seconds (Flyway runs DB migrations on startup). If it stays at `0/1` or goes into `CrashLoopBackOff`, see the troubleshooting section at the bottom of this guide.

Test the health endpoint from inside the pod:
```bash
kubectl exec -n dev deploy/auth-service -- \
  curl -s http://localhost:8081/actuator/health
```

Check Service endpoints (will be empty if pod is not ready):
```bash
kubectl get endpoints auth-service -n dev
```

---

## Step 6 — Deploy the Remaining 8 Services

Now deploy all remaining services one by one. After each one, observe what happens.

```bash
kubectl apply -f lab1/api-gateway.yaml
kubectl apply -f lab1/drug-catalog-service.yaml
kubectl apply -f lab1/inventory-service.yaml
kubectl apply -f lab1/manufacturing-service.yaml
kubectl apply -f lab1/supplier-service.yaml
kubectl apply -f lab1/qc-service.yaml
kubectl apply -f lab1/notification-service.yaml
kubectl apply -f lab1/pharma-ui.yaml
```

Watch all pods come up together:
```bash
kubectl get pods -n dev -w
```

---

## Step 7 — Verify Everything

Check all resources in the dev namespace:
```bash
kubectl get all -n dev
```

You should see:
- 9 Deployments
- 9 ReplicaSets
- 9 Pods
- 9 Services
- 2 Ingresses (api-gateway and pharma-ui)

Check ConfigMaps and ServiceAccounts:
```bash
kubectl get configmaps -n dev
kubectl get serviceaccounts -n dev
```

List only the pods and their status:
```bash
kubectl get pods -n dev -o wide
```

---

## Step 8 — Explore and Troubleshoot

### View logs for any service
```bash
kubectl logs -l app=<service-name> -n dev

# Example:
kubectl logs -l app=api-gateway -n dev
```

### Describe a pod to see events and config
```bash
kubectl describe pod -l app=<service-name> -n dev
```

### Execute a command inside a running pod
```bash
# Test internal DNS — api-gateway should be able to reach auth-service by name
kubectl exec -n dev deploy/api-gateway -- \
  curl -s http://auth-service:8081/actuator/health
```

### Check that the Service has endpoints
```bash
# An empty ENDPOINTS column means the pod is not passing readiness
kubectl get endpoints -n dev
```

### View events for the whole namespace (sorted by time)
```bash
kubectl get events -n dev --sort-by='.lastTimestamp'
```

---

## Step 9 — See the Pain Point

You have just deployed 9 services. Count what you did manually:

| What | Count |
|---|---|
| Secrets created by hand | 2 |
| Files applied | 11 |
| Resources created | ~40 (Deployments, Services, ConfigMaps, SAs, ReplicaSets, Pods, Ingresses) |
| Environments covered | 1 (dev only) |

Now imagine doing this for **qa** and **prod** as well — with different image tags, different replica counts, different resource limits, and different config values per environment.

That is 9 services × 3 environments = **27 deployments**, all maintained by hand, with no audit trail, no rollback, and no guarantee that dev and prod configs match.

This is exactly the problem that **Helm + ArgoCD** solves in Session 2.

---

## Troubleshooting

### Pods in CrashLoopBackOff — `UnknownHostException`

**Symptom:** Pods crash immediately with this in the logs:
```
Caused by: java.net.UnknownHostException: pharma-dev-postgres.<id>.us-east-1.rds.amazonaws.com
```

**Cause:** The `DB_HOST` in the ConfigMap points to a stale or wrong RDS endpoint.

**Fix:**
```bash
# 1. Get the correct endpoint
export DB_HOST=$(aws rds describe-db-instances \
  --query 'DBInstances[?DBInstanceIdentifier==`pharma-dev-postgres`].Endpoint.Address' \
  --output text)

# 2. Re-apply the manifests (after updating DB_HOST in the files — see "Before You Deploy")
kubectl apply -f lab1/auth-service.yaml   # repeat for each affected service

# 3. Restart the pods to pick up the new ConfigMap
kubectl rollout restart deployment/auth-service -n dev
# Replace auth-service with whichever service is crashing
```

### Pods in ImagePullBackOff

**Symptom:** Events show `failed to pull image ... not found`

**Cause:** The image tag in the manifest doesn't exist in ECR. The tag may have been built and pushed under a different SHA.

**Fix:** Update the `image:` field in the relevant YAML file to a tag that exists in your ECR repository, then re-apply.

```bash
# List available tags for a service
aws ecr describe-images \
  --repository-name auth-service \
  --query 'sort_by(imageDetails,&imagePushedAt)[-5:].imageTags' \
  --output table
```

### New pods Pending — insufficient resources

**Symptom:** New pods stay in `Pending`. Events show: `0/N nodes are available: Insufficient memory` or `Too many pods`.

**Cause:** During a rolling update, both old and new pods exist simultaneously. If the cluster is near capacity, new pods can't be scheduled.

**Fix:** Delete the old crashing pods to free capacity. Kubernetes will not restart them if a healthy replacement is already running.
```bash
# List old pods (look for ones with high RESTARTS or CrashLoopBackOff)
kubectl get pods -n dev

# Delete the stuck old pods by name
kubectl delete pod <pod-name> -n dev
```

---

## Cleanup (Optional)

To remove everything you deployed:

```bash
kubectl delete namespace dev
```

This deletes the namespace and everything inside it — all pods, services, configmaps, secrets, and deployments.

---

## Summary

| Step | Command |
|---|---|
| Create namespace | `kubectl apply -f lab1/00-namespace.yaml` |
| Apply RBAC | `kubectl apply -f lab1/01-rbac.yaml` |
| Create secrets | `kubectl create secret generic ...` |
| Deploy auth-service | `kubectl apply -f lab1/auth-service.yaml` |
| Deploy all others | `kubectl apply -f lab1/<service>.yaml` |
| Verify | `kubectl get all -n dev` |
| Debug | `kubectl describe pod / kubectl logs / kubectl get events` |
| Cleanup | `kubectl delete namespace dev` |
