# Argo CD Demo — One-Sheet Command Cheat Sheet
Argo CD is a GitOps-based Continuous Delivery (CD) tool 
that automatically deploys applications to Kubernetes by 
monitoring configuration files stored in Git.
In simple terms:
Argo CD makes sure that what is running in Kubernetes matches what you have defined in GitHub.
**Project:** TestBook API · **EKS:** `testbook-cluster` · **Region:** `eu-north-1`  
**Argo CD Application:** `testbook-api-dev` · **Argo CD namespace:** `argocd` · **App namespace:** `dev`  
**GitHub repository:** `kscorpio77/testbookapiworkflowdemo` · **Branch:** `main`  
**Helm values file:** `helm/testbook-api/values-dev.yaml`  
**ECR image:** `316255801172.dkr.ecr.eu-north-1.amazonaws.com/mybookapi`

> **GitOps principle:** Edit locally → commit → push to GitHub → Argo CD refreshes/compares desired state → auto-sync applies Kubernetes changes → pods converge. A local edit alone will **not** deploy.

## 0. Prerequisites (run from the repository root)

```bash
# Verify your EKS connection and Kubernetes context
aws eks update-kubeconfig --region eu-north-1 --name testbook-cluster
kubectl config current-context
kubectl get nodes

# Confirm namespaces, Argo CD application, and current deployment
kubectl get namespaces
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get applications -n argocd
kubectl get deployments,pods,services -n dev
```

## 1. Show the starting state

```bash
# Application sync + health status
kubectl get applications -n argocd

# Desired/ready/up-to-date pod counts
kubectl get deployment testbook-api -n dev

# Pods and their readiness/status
kubectl get pods -n dev -o wide

# Current configured replica count
kubectl get deployment testbook-api -n dev -o jsonpath='{.spec.replicas}{"\n"}'

# Actual Docker image configured on the Deployment
kubectl get deployment testbook-api -n dev -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'

# See local values (working tree)
cat helm/testbook-api/values-dev.yaml

# See GitHub main values (after fetching)
git fetch origin main
git --no-pager show origin/main:helm/testbook-api/values-dev.yaml
```

> `git --no-pager show` avoids the `(END)` screen. If you do enter that screen, press **q** to exit.

## 2. DEMO A — Scale from 1 pod to 2 pods (GitOps)

Edit `helm/testbook-api/values-dev.yaml` in VS Code:

```yaml
replicaCount: 2
```

Then run:

```bash
# Inspect changes before committing
git diff -- helm/testbook-api/values-dev.yaml

git status --short

# Ensure you're on the intended branch (main for this demo)
git branch --show-current

# Commit and push the changed desired state
git add helm/testbook-api/values-dev.yaml
git commit -m "Demo: scale DEV to 2 replicas"
git push origin main

# Confirm the pushed value in remote main
git fetch origin main
git --no-pager show origin/main:helm/testbook-api/values-dev.yaml
```

**In a second terminal, watch the change:**

```bash
# Watch Argo CD's sync/health status (not pod counts)
kubectl get applications -n argocd -w

# OR watch Deployment replica readiness
kubectl get deployment testbook-api -n dev -w

# OR watch pod creation/termination and state changes
kubectl get pods -n dev -w
```

**Expected eventual outcome (if images pull and readiness succeeds):** `READY 2/2`, two healthy pods, Argo CD `Synced / Healthy`. Intermediate states may be too fast to appear. Press **Ctrl+C** to stop any watch.

**Important:** If `replicaCount: 2` is only changed locally or committed without pushing, Argo CD will continue using the GitHub version (for example, `replicaCount: 1`).

## 3. DEMO B — Scale back from 2 pods to 1

Edit the same file:

```yaml
replicaCount: 1
```

```bash
git add helm/testbook-api/values-dev.yaml
git commit -m "Demo: scale DEV back to 1 replica"
git push origin main
kubectl get deployment testbook-api -n dev -w
```

Watch a pod terminate with `kubectl get pods -n dev -w` in another terminal.

## 4. DEMO C — Change the Docker image tag

Only use a tag **already pushed to ECR**. Do not invent a tag.

```bash
# List available ECR tags
aws ecr describe-images --repository-name mybookapi --region eu-north-1 --query 'imageDetails[].imageTags' --output table

# Inspect local and GitHub versions of values-dev.yaml
cat helm/testbook-api/values-dev.yaml
git fetch origin main
git --no-pager show origin/main:helm/testbook-api/values-dev.yaml
```

Edit `helm/testbook-api/values-dev.yaml`, e.g.:

```yaml
image:
  tag: "e4791af"  # Example: replace with an ECR tag you verified
```

```bash
# Preview Helm's rendered image BEFORE pushing
helm template testbook-api helm/testbook-api -f helm/testbook-api/values-dev.yaml | grep 'image:'

# Commit and push
git add helm/testbook-api/values-dev.yaml
git commit -m "Demo: update DEV image tag"
git push origin main

# Watch the rollout
kubectl rollout status deployment/testbook-api -n dev --timeout=180s

# Verify the image now configured on the Deployment
kubectl get deployment testbook-api -n dev -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'

# Inspect the pods
kubectl get pods -n dev -o wide
```

> A new ECR image **alone** does not deploy. GitHub Actions must also update and **push** `values-dev.yaml`, or you must do so manually. The GitOps source is Git.

## 5. Refresh Argo CD (optional: avoid waiting for polling)

```bash
# Request an immediate Git refresh (does not itself force a sync)
kubectl annotate application testbook-api-dev -n argocd argocd.argoproj.io/refresh=normal --overwrite

# Inspect current sync/health
kubectl get application testbook-api-dev -n argocd

# Watch status changes
kubectl get applications -n argocd -w
```

Argo CD normally checks Git periodically (often around 3 minutes, depending on configuration) or responds to configured webhooks. Your Application has automated sync enabled, so a detected desired-state difference should sync automatically.

## 6. Diagnose `Synced` but old image or wrong replica count

```bash
# Confirm remote desired state
git fetch origin main
git --no-pager show origin/main:helm/testbook-api/values-dev.yaml

# Compare local vs remote (useful if local edit wasn't pushed)
git diff origin/main -- helm/testbook-api/values-dev.yaml

# Render Helm manifests from LOCAL values
helm template testbook-api helm/testbook-api -f helm/testbook-api/values-dev.yaml | grep -E 'replicas:|image:'

# See Argo CD source repo, revision, chart path, values file, and synced SHA
kubectl get application testbook-api-dev -n argocd -o jsonpath='{.spec.source.repoURL}{"\n"}{.spec.source.targetRevision}{"\n"}{.spec.source.path}{"\n"}{.spec.source.helm.valueFiles}{"\n"}{.status.sync.revision}{"\n"}'

# Compare with current GitHub main SHA
git rev-parse origin/main

# See actual Deployment spec
kubectl get deployment testbook-api -n dev -o yaml

# Check whether a separate controller/HPA is affecting replicas
kubectl get hpa -n dev
```

> `Synced` means the live resources match the **manifests Argo CD rendered at its tracked revision**, not necessarily the latest file currently on your laptop. `Degraded` means resources are unhealthy. If the sync revision and `origin/main` differ, check refresh/repository access. If they match but Helm renders the wrong values, inspect `helm/testbook-api/templates/deployment.yaml`, `values.yaml`, and overrides.

## 7. Troubleshoot unhealthy pods / `ImagePullBackOff`

```bash
# Show all pods and their states
kubectl get pods -n dev

# Show deployment events and conditions
kubectl describe deployment testbook-api -n dev

# Show recent namespace events
kubectl get events -n dev --sort-by=.lastTimestamp

# Describe a failing pod (replace POD_NAME)
kubectl describe pod POD_NAME -n dev

# Application logs (when container has started)
kubectl logs deployment/testbook-api -n dev --tail=100

# Check rollout progress
kubectl rollout status deployment/testbook-api -n dev --timeout=180s

# Confirm image tag exists in ECR (replace TAG)
aws ecr describe-images --repository-name mybookapi --image-ids imageTag=TAG --region eu-north-1
```

**Interpretation:** `ImagePullBackOff` = cannot pull image (tag missing, permissions, network, etc.); `CrashLoopBackOff` = app repeatedly crashes; `Pending` = cannot schedule/start; `0/1 Running` = running but not ready. Read pod **Events** to find the actual cause. Scaling to 2 does not guarantee `2/2` if images fail to pull.

## 8. Argo CD application definition and GitOps policy

```bash
# View Argo CD Application source, destination and sync policy
kubectl get application testbook-api-dev -n argocd -o yaml

# Quick check: auto-sync is enabled if spec.syncPolicy.automated exists
kubectl get application testbook-api-dev -n argocd -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'

# Show where Argo CD runs vs where app pods run
kubectl get pods -n argocd
kubectl get pods -n dev
```

`argocd` = Argo CD control plane. `dev` = TestBook API Deployment, Service and pods. Argo CD does not build the Docker image; GitHub Actions builds/pushes it, and EKS pulls it.

## 9. Suggested live-demo terminal layout

| Terminal | Command | What students observe |
|---|---|---|
| 1 | `kubectl get applications -n argocd -w` | Sync/health transitions |
| 2 | `kubectl get deployment testbook-api -n dev -w` | Desired vs ready replica counts |
| 3 | `kubectl get pods -n dev -w` | Pods starting/terminating |
| 4 | Edit `values-dev.yaml`; `git add`, `git commit`, `git push` | Git as the source of truth |

**Demo sequence:** Start watchers → show `replicaCount: 1` in remote Git → change to `2` locally → show nothing happens before push → commit/push → wait or request refresh → observe desired replicas change to `2` and new pod appear → repeat to scale down → demonstrate image-tag update → inspect rollout and health.

## 10. Fast command reference

```bash
kubectl get applications -n argocd
kubectl get applications -n argocd -w
kubectl get deployment testbook-api -n dev
kubectl get deployment testbook-api -n dev -w
kubectl get pods -n dev -w
kubectl get deployment testbook-api -n dev -o jsonpath='{.spec.replicas}{"\n"}'
kubectl get deployment testbook-api -n dev -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
git fetch origin main
git --no-pager show origin/main:helm/testbook-api/values-dev.yaml
helm template testbook-api helm/testbook-api -f helm/testbook-api/values-dev.yaml | grep -E 'replicas:|image:'
kubectl annotate application testbook-api-dev -n argocd argocd.argoproj.io/refresh=normal --overwrite
kubectl rollout status deployment/testbook-api -n dev --timeout=180s
kubectl get events -n dev --sort-by=.lastTimestamp
```

**Safety:** Do not use `kubectl scale` for this GitOps demonstration; it changes live state directly and may be reverted by Argo CD self-healing. Do not delete pods or manually patch the Deployment to simulate GitOps.
