# Lab 2 Guide — GitOps with ArgoCD + Helm

**Lab 1 must be complete before starting.** Your EKS cluster should have the `dev` namespace, RBAC, and secrets (`db-credentials`, `jwt-secret`) already applied.

Verify before starting:
```bash
kubectl get namespace dev
kubectl get secret db-credentials -n dev
kubectl get secret jwt-secret -n dev
```

All three must exist. If not, complete Lab 1 first.

---

## Before You Deploy — Set Your RDS Endpoint

The raw manifests in `lab2/manifests/` contain a `DB_HOST` configmap entry that must match **your** RDS instance. This is the same step as Lab 1 — if your RDS was reprovisioned since Lab 1 (or you are starting fresh), re-run it.

```bash
export DB_HOST=$(aws rds describe-db-instances \
  --query 'DBInstances[?DBInstanceIdentifier==`pharma-dev-postgres`].Endpoint.Address' \
  --output text)
echo $DB_HOST

# macOS
find lab2/manifests/ -name "configmap.yaml" -exec \
  sed -i '' "s|DB_HOST:.*rds\.amazonaws\.com|DB_HOST: $DB_HOST|g" {} +

# Linux / Cloud9
find lab2/manifests/ -name "configmap.yaml" -exec \
  sed -i "s|DB_HOST:.*rds\.amazonaws\.com|DB_HOST: $DB_HOST|g" {} +
```

Verify:
```bash
grep "DB_HOST" lab2/manifests/*/configmap.yaml
```

Commit the changes so ArgoCD picks them up when it clones your fork:
```bash
git add lab2/manifests/
git commit -m "lab2: set RDS endpoint for my environment"
git push
```

> **Why this step exists:** ArgoCD applies what is in Git — not what is in your cluster. If the endpoint in the manifest files is wrong, ArgoCD will keep applying the broken ConfigMap and your pods will keep crashing even after you fix the cluster manually.

---

# Part 1 — Day 2: ArgoCD with Raw Manifests

## What We Are Building

In Lab 1 you deployed 9 services by running `kubectl apply` manually — one command per resource, per service. Today you hand that job to ArgoCD. ArgoCD watches this Git repo and applies changes automatically. You will never run `kubectl apply` in production again.

By the end of Day 2 you will have:
- ArgoCD installed on your EKS cluster
- A pharma AppProject scoping what ArgoCD can touch
- All 9 services deployed via ArgoCD watching `lab2/manifests/`
- Experienced configuration drift and ArgoCD's response to it

---

## Step 1 — Fork the Repository

Every student needs their own copy of zen-gitops so ArgoCD can watch YOUR repo.

1. Go to `https://github.com/ravdy/zen-gitops`
2. Click **Fork** → create under your GitHub account
3. Clone your fork locally:

```bash
git clone https://github.com/<YOUR_GITHUB_USERNAME>/zen-gitops.git
cd zen-gitops
```

4. Replace `<YOUR_GITHUB_USERNAME>` in every YAML file under `lab2/argocd-apps/`:

```bash
export YOUR_GITHUB_USERNAME=<your-actual-github-username>
# macOS
find lab2/argocd-apps -name "*.yaml" -exec \
  sed -i '' "s/<YOUR_GITHUB_USERNAME>/$YOUR_GITHUB_USERNAME/g" {} +

# Linux / Cloud9
find lab2/argocd-apps -name "*.yaml" -exec \
  sed -i "s/<YOUR_GITHUB_USERNAME>/$YOUR_GITHUB_USERNAME/g" {} +

# Verify
grep -r "github.com" lab2/argocd-apps/ | head -3
# Should show your actual username, not the placeholder
```

5. Commit and push:

```bash
git add lab2/argocd-apps/
git commit -m "lab2: set my GitHub username in app specs"
git push
```

---

## Step 2 — Install ArgoCD

```bash
# Create the argocd namespace
kubectl create namespace argocd

# Install ArgoCD (stable release)
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all pods to be ready (takes 2-3 minutes)
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

# Verify all pods are Running
kubectl get pods -n argocd
```

Expected output — all pods Running and Ready:
```
NAME                                                READY   STATUS    RESTARTS
argocd-application-controller-0                     1/1     Running   0
argocd-applicationset-controller-xxx                1/1     Running   0
argocd-dex-server-xxx                               1/1     Running   0
argocd-notifications-controller-xxx                 1/1     Running   0
argocd-redis-xxx                                    1/1     Running   0
argocd-repo-server-xxx                              1/1     Running   0
argocd-server-xxx                                   1/1     Running   0
```

---

## Step 3 — Access the ArgoCD UI

Open a new terminal tab and run the port-forward (keep it running):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Get the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Open your browser: `https://localhost:8080`
Login: username `admin`, password from above command.

**You will see a certificate warning** — this is expected for a local port-forward. Click "Advanced" → "Proceed".

---

## Step 4 — Login via ArgoCD CLI

Install the CLI if not already installed:
```bash
# Mac
brew install argocd

# Linux
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
```

Login:
```bash
argocd login localhost:8080 \
  --username admin \
  --password $(kubectl get secret argocd-initial-admin-secret -n argocd \
    -o jsonpath='{.data.password}' | base64 -d) \
  --insecure
```

Expected: `'admin:login' logged in successfully`

---

## Step 5 — ArgoCD Concepts

**AppProject** — A security boundary. Defines which Git repos ArgoCD can use as sources, which namespaces it can deploy to, and which Kubernetes resource types it can create. Think of it as IAM for ArgoCD.

**Application** — The core ArgoCD object. Links a Git source (repo + path + branch) to a Kubernetes destination (cluster + namespace). ArgoCD continuously compares what's in Git with what's in the cluster and reports the difference.

**Sync Status:**
- `Synced` — cluster matches Git exactly
- `OutOfSync` — something differs (Git changed, or cluster was modified manually)
- `Unknown` — ArgoCD can't determine state yet

**Health Status:**
- `Healthy` — all Kubernetes resources are in their desired state
- `Progressing` — pods are starting or updating
- `Degraded` — something is wrong (pods crashing, etc.)

**Reconciliation loop:** ArgoCD polls Git every 3 minutes. When it detects a difference between Git and the cluster, it marks the Application as OutOfSync. With `automated: true` in syncPolicy, it applies the diff automatically.

---

## Step 6 — Create the pharma AppProject

```bash
kubectl apply -f lab2/argocd-apps/project/pharma-project.yaml

# Verify
argocd proj list
```

Explore the AppProject in the UI: click **Settings** → **Projects** → **pharma**. You will see the allowed source repos, destination namespaces, and the resource whitelist.

---

## Step 7 — Deploy auth-service via ArgoCD (Raw Manifests)

This is the anchor service. Do this one first and understand every step before scaling to all 9.

```bash
# Create the ArgoCD Application pointing to lab2/manifests/auth-service/
kubectl apply -f lab2/argocd-apps/day2-raw/auth-service-app.yaml

# Check the application status
argocd app list

# Get detailed status
argocd app get auth-service-dev-raw
```

Watch the pods come up:
```bash
kubectl get pods -n dev -w
```

**What just happened?**
1. ArgoCD cloned your zen-gitops repo
2. Found all YAML files in `lab2/manifests/auth-service/`
3. Applied them to the `dev` namespace in order
4. Is now watching for any difference between that directory and the cluster

---

## Step 8 — Explore the ArgoCD UI

In the browser, click on the `auth-service-dev-raw` application.

**Resource Tree** — You see the full hierarchy ArgoCD is managing:
```
Application (auth-service-dev-raw)
├── ServiceAccount (auth-service)
├── ConfigMap (auth-service)
├── Deployment (auth-service)
│   └── ReplicaSet (auth-service-xxx)
│       └── Pod (auth-service-xxx-yyy)  ← click here to see logs
└── Service (auth-service)
```

Click any resource to see its YAML, events, and logs.

**Diff view** — Click **App Diff** to see what ArgoCD would change if you synced right now. Currently it should be empty (Synced).

**Sync History** — Click **History** to see every previous sync with its Git commit hash.

---

## Step 9 — Simulate Configuration Drift

Someone on your team bypasses GitOps and manually scales auth-service:

```bash
kubectl scale deployment auth-service --replicas=3 -n dev
kubectl get pods -n dev
```

Watch ArgoCD detect the drift (within 3 minutes, or force a refresh):
```bash
argocd app get auth-service-dev-raw
# STATUS: OutOfSync

# See the exact diff
argocd app diff auth-service-dev-raw
```

In the UI, the app now shows an orange `OutOfSync` badge.

Sync back to Git state:
```bash
argocd app sync auth-service-dev-raw
kubectl get pods -n dev
# Back to 1 pod — drift reverted
```

**Key insight:** With `selfHeal: true` in syncPolicy, ArgoCD would have reverted this automatically without your intervention. This is what "GitOps" means — Git wins, always.

---

## Step 10 — Deploy All 9 Services

Now apply the same pattern to all services:

```bash
for app in lab2/argocd-apps/day2-raw/*.yaml; do
  kubectl apply -f $app
done

# Watch all applications appear
argocd app list

# Watch all pods come up in dev namespace
kubectl get pods -n dev -w
```

Wait for all pods to reach `1/1 Running`. Services that connect to the database (auth, catalog, inventory, manufacturing, supplier, notification) need 60-90 seconds for Flyway DB migrations on first start. If any pod stays in `CrashLoopBackOff`, check that `DB_HOST` in its ConfigMap matches your RDS endpoint — see the "Before You Deploy" section above.

---

## Step 11 — Feel the Pain

You now have 9 services deployed. Count what it took:

```bash
find lab2/manifests -name "*.yaml" | wc -l
# 36 files — 4 per service × 9 services
```

Now imagine: the team releases a new Docker image. You need to update the image tag. That means editing `deployment.yaml` in 9 service directories. Add a new environment variable? Edit 9 `configmap.yaml` files. Change the readiness probe delay? Edit 9 `deployment.yaml` files.

**This is what Helm solves. See you in Day 3.**

---

# Part 2 — Day 3: Migration to Helm

## Prerequisites

- Day 2 complete: ArgoCD installed, pharma AppProject created, all 9 day2-raw apps running
- `helm` CLI installed: `brew install helm` (Mac) or see https://helm.sh/docs/intro/install/

Verify:
```bash
helm version
argocd app list | grep "dev-raw"
# Should show 9 apps running
```

---

## Step 1 — What is Helm?

Helm is a package manager for Kubernetes. Instead of 9 × 4 = 36 YAML files with identical structure, you have:

```
helm-charts/           ← one chart for ALL 9 services
├── Chart.yaml
├── values.yaml        ← default values
└── templates/
    ├── deployment.yaml    ← {{ .Values.image.tag }}, {{ .Values.replicaCount }}
    ├── service.yaml       ← {{ .Values.service.port }}
    ├── configmap.yaml     ← iterates over {{ .Values.configmap }}
    ├── serviceaccount.yaml
    ├── hpa.yaml           ← {{- if .Values.autoscaling.enabled }}
    └── ingress.yaml       ← {{- if .Values.ingress.enabled }}
```

Combined with per-service values files:
```
envs/dev/values-auth-service.yaml   ← auth-service's port, image, config
envs/dev/values-api-gateway.yaml    ← api-gateway's port, image, config
```

**One chart + one values file = all the manifests for one service in one environment.**

---

## Step 2 — Walk Through the Helm Chart

```bash
# See the chart structure
ls helm-charts/
ls helm-charts/templates/

# Read the deployment template — notice the Go template syntax
cat helm-charts/templates/deployment.yaml
```

Key template patterns you will see:
```yaml
name: {{ include "pharma-service.fullname" . }}
replicas: {{ .Values.replicaCount }}
image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- if .Values.autoscaling.enabled }}
# HPA is only rendered when autoscaling.enabled: true
{{- end }}
```

---

## Step 3 — Preview What Helm Renders

Before ArgoCD uses Helm, see what it will produce:

```bash
# Render the chart with auth-service dev values
helm template auth-service ./helm-charts \
  -f envs/dev/values-auth-service.yaml \
  -n dev | less
```

Compare with what you wrote manually in `lab2/manifests/auth-service/` — same Deployment structure, same ConfigMap keys, same Service spec.

**This is what ArgoCD runs internally every 3 minutes.** It renders the template, compares the output to the cluster, and applies the diff.

---

## Step 4 — Migrate auth-service from Raw to Helm

Delete the Day 2 raw app:
```bash
argocd app delete auth-service-dev-raw --yes

# Clean up the raw resources manually since we are replacing them
kubectl delete -f lab2/manifests/auth-service/ -n dev
```

Apply the Day 3 Helm app:
```bash
kubectl apply -f lab2/argocd-apps/day3-helm/dev/auth-service-app.yaml

argocd app get auth-service-dev
# SOURCE: helm-charts (Helm)
# STATUS: Synced
```

Watch pods:
```bash
kubectl get pods -n dev -w
```

The pod is identical to what the raw manifest deployed — same image, same config, same probes. But now the source is a Helm chart + a values file instead of 4 separate manifests.

```bash
# Confirm ArgoCD is using Helm
argocd app get auth-service-dev -o yaml | grep -A5 "source:"
```

---

## Step 5 — Migrate All 9 Services to Helm (dev)

Delete all Day 2 raw apps:
```bash
for app in $(argocd app list -o name | grep "dev-raw"); do
  argocd app delete $app --yes
done

# Clean up all raw manifests
for svc in auth-service api-gateway drug-catalog-service inventory-service \
           manufacturing-service supplier-service qc-service notification-service pharma-ui; do
  kubectl delete -f lab2/manifests/$svc/ -n dev --ignore-not-found
done
```

Apply all Day 3 Helm apps for dev:
```bash
for app in lab2/argocd-apps/day3-helm/dev/*.yaml; do
  kubectl apply -f $app
done

# Watch all 9 apps sync
argocd app list
kubectl get pods -n dev -w
```

---

## Step 6 — Deploy QA Environment

```bash
for app in lab2/argocd-apps/day3-helm/qa/*.yaml; do
  kubectl apply -f $app
done

argocd app list | grep "\-qa"
kubectl get pods -n qa -w
```

QA uses automated sync — ArgoCD applies changes from `envs/qa/` automatically when you push to main.

---

## Step 7 — Deploy Production Environment (Manual Sync Gate)

```bash
for app in lab2/argocd-apps/day3-helm/prod/*.yaml; do
  kubectl apply -f $app
done

# Note: prod apps do NOT have automated sync
argocd app list | grep "\-prod"
# STATUS: OutOfSync  ← waiting for human approval
```

The prod apps are OutOfSync — ArgoCD knows what to apply but will not do it without a human trigger.

In the ArgoCD UI: click any prod application → **Sync** button → review the diff → click **Synchronize**.

Or via CLI:
```bash
# Sync all prod services
for app in $(argocd app list -o name | grep "\-prod"); do
  argocd app sync $app
done
kubectl get pods -n prod
```

**Why manual for prod?** Every prod change must be explicitly approved by a human. Even if Git has the right values, ArgoCD waits. This is your compliance gate.

---

## Step 8 — Simulate a CI Image Tag Update

This is the full end-to-end GitOps workflow. In real life, your CI pipeline does this after a successful build.

```bash
# Simulate CI: update auth-service image tag in dev
yq e '.image.tag = "sha-classdemo"' -i envs/dev/values-auth-service.yaml

git add envs/dev/values-auth-service.yaml
git commit -m "ci(dev): update auth-service -> sha-classdemo"
git push
```

ArgoCD detects the change within 3 minutes (or force a refresh):
```bash
argocd app get auth-service-dev --watch
# STATUS changes: Synced → OutOfSync → Synced (automated sync)

kubectl get pods -n dev
kubectl describe pod -l app=auth-service -n dev | grep Image
# Image: 516209541629.dkr.ecr.us-east-1.amazonaws.com/auth-service:sha-classdemo
```

**You just completed the full GitOps CD pipeline:**
1. Value changed in Git
2. ArgoCD detected the change
3. Helm rendered new manifests
4. Kubernetes rolled out the update
5. Zero manual kubectl commands in production

---

## Final State — What You Built

```
EKS Cluster
├── dev namespace    — 9 services, Helm-managed, auto-sync
├── qa namespace     — 8 services, Helm-managed, auto-sync
└── prod namespace   — 8 services, Helm-managed, MANUAL sync gate

ArgoCD
└── pharma project
    ├── 9 × dev apps
    ├── 8 × qa apps   (qc-service excluded — no qa/prod values file exists)
    └── 8 × prod apps (qc-service excluded, manual sync)

zen-gitops repo
├── helm-charts/           ← one chart for all services
├── envs/dev|qa|prod/      ← per-service per-env values files
└── lab2/argocd-apps/      ← Application specs you applied
```

**Interview showcase:**
- Open ArgoCD UI, show all apps Synced/Healthy
- Update a values file, push, watch ArgoCD sync dev automatically
- Show a prod app OutOfSync waiting for the manual gate
- Explain: "This is how a code change travels from developer commit to production"
