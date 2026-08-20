# Kubernetes Application Deployment — Project 3

A React + Vite application containerized with Docker and deployed to a **self-managed Kubernetes cluster** running on a single AWS EC2 instance, with a full CI/CD pipeline via GitHub Actions.

Repo: [github.com/ParthVaishnavDev/k8s-demo-app](https://github.com/ParthVaishnavDev/k8s-demo-app)

---

## Table of Contents

1. [Architecture](#architecture)
2. [Technologies Used](#technologies-used)
3. [AWS Resources](#aws-resources)
4. [Local Setup](#local-setup)
5. [Containerization](#containerization)
6. [Kubernetes Cluster Setup](#kubernetes-cluster-setup)
7. [Deployment Walkthrough](#deployment-walkthrough)
8. [Kubernetes Commands Reference](#kubernetes-commands-reference)
9. [CI/CD Pipeline](#cicd-pipeline)
10. [Troubleshooting Notes](#troubleshooting-notes)
11. [Lessons Learned](#lessons-learned)
12. [Possible Improvements](#possible-improvements)

---

## Architecture

```
Developer (Cursor / local machine)
        |
        v
      GitHub  ──────────────► GitHub Actions
                                    |
                                    v
                              Docker Build
                                    |
                                    v
                          Trivy Security Scan
                                    |
                                    v
                               AWS ECR
                                    |
                                    v
                    ┌───────────────────────────┐
                    │        AWS EC2             │
                    │   (self-managed K8s node)  │
                    │                             │
                    │   kubeadm control-plane     │
                    │   + Calico (pod networking) │
                    │                             │
                    │        Deployment           │
                    │             |                │
                    │      ┌──────┼──────┐         │
                    │     Pod    Pod    Pod         │
                    │      └──────┼──────┘         │
                    │             |                │
                    │         Service (NodePort)   │
                    │             |                │
                    │     ingress-nginx Controller │
                    │             |                │
                    │          Ingress             │
                    └─────────────┼───────────────┘
                                  |
                                  v
                              Internet
                                  |
                                  v
                                User
```

**Request flow:** `User → EC2 Public IP:NodePort → Ingress → Service → Pod (nginx serving React build)`

---

## Technologies Used

| Category | Tool |
|---|---|
| Frontend | React (Vite scaffold) |
| Containerization | Docker (multi-stage build) |
| Container Registry | AWS ECR |
| Orchestration | Kubernetes (self-managed via `kubeadm`) |
| Container Runtime | containerd |
| Pod Networking | Calico |
| Ingress Controller | ingress-nginx (bare-metal) |
| CI/CD | GitHub Actions |
| Security Scanning | Trivy |
| Infrastructure | AWS EC2, VPC, ECR (provisioned via AWS CLI) |
| Web Server | nginx (serving static build) |

---

## AWS Resources

All resources were created from scratch for this project — no reuse of infrastructure from other projects.

| Resource | ID / Value |
|---|---|
| VPC | `vpc-07a5db59d55fa318c` (CIDR `10.0.0.0/16`) |
| Internet Gateway | `igw-03070948592cedefa` |
| Subnet | `subnet-06d39dff391f2b76d` (CIDR `10.0.1.0/24`, `ap-south-1a`) |
| Route Table | `rtb-0ee429765007d07f3` (route `0.0.0.0/0 → IGW`) |
| Security Group | `sg-0e66314b2200775b3` |
| EC2 Instance | `t3.medium`, Ubuntu 22.04, 20GB gp3 EBS |
| ECR Repository | `k8s-demo-app` |

### Security Group Rules

| Port | Source | Purpose |
|---|---|---|
| 22 | `0.0.0.0/0` | SSH access |
| 6443 | `0.0.0.0/0` | Kubernetes API server |
| 2379–2380 | `10.0.0.0/16` (VPC-internal only) | etcd |
| 10250–10252 | `10.0.0.0/16` (VPC-internal only) | kubelet, scheduler, controller-manager |
| 30000–32767 | `0.0.0.0/0` | NodePort range (app + Ingress access) |
| 80 / 443 | `0.0.0.0/0` | HTTP / HTTPS |

**Why `t3.medium` instead of a free-tier instance:** `kubeadm` enforces a minimum of 2 vCPUs to initialize the control plane — smaller instance types fail the preflight check.

---

## Local Setup

```bash
git clone https://github.com/ParthVaishnavDev/k8s-demo-app.git
cd k8s-demo-app
npm install
npm run dev
```

Standard Vite + React scaffold (`npm create vite`), no modifications to the base app logic — the focus of this project is the deployment pipeline, not the application itself.

---

## Containerization

A **multi-stage Dockerfile** keeps the final image lightweight — build tooling and `node_modules` never ship in the runtime image.

```dockerfile
# ---- Stage 1: Build ----
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- Stage 2: Serve ----
FROM nginx:alpine
RUN rm -rf /usr/share/nginx/html/*
COPY --from=builder /app/dist /usr/share/nginx/html
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
```

**Why a custom entrypoint script:** since this is a static SPA, a Kubernetes ConfigMap can't influence already-compiled JavaScript. `entrypoint.sh` generates a `config.json` file from environment variables at **container startup** (not build time), which the frontend can fetch at runtime — the correct pattern for injecting runtime config into a static frontend.

```sh
#!/bin/sh
cat <<CONFIG > /usr/share/nginx/html/config.json
{
  "appName": "$APP_NAME",
  "appVersion": "$APP_VERSION",
  "environment": "$ENVIRONMENT"
}
CONFIG
exec nginx -g "daemon off;"
```

**Build & test locally:**
```bash
docker build -t k8s-demo-app:v1 .
docker run -d -p 8080:80 --name k8s-demo-test k8s-demo-app:v1
```

---

## Kubernetes Cluster Setup

Kubernetes was installed manually on a single EC2 node (control plane + worker combined) using `kubeadm` — a deliberate choice over a managed service like EKS, to understand what the managed control plane actually abstracts away.

### 1. System prerequisites
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

### 2. Container runtime (containerd)
```bash
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### 3. kubeadm, kubelet, kubectl (v1.30)
```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

### 4. Initialize the control plane
```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$(hostname -I | awk '{print $1}')

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 5. Remove control-plane taint (single-node cluster)
```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```
By default, the control-plane node refuses to schedule regular workloads. With only one node in this cluster, that taint must be removed or nothing would ever run.

### 6. Pod networking (Calico)
```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```
Kubernetes has no built-in pod-to-pod networking — a CNI plugin is required. Calico was used here.

### 7. Verify
```bash
kubectl get nodes
kubectl get pods -n kube-system
```

---

## Deployment Walkthrough

### ECR authentication & image push
```bash
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.ap-south-1.amazonaws.com
docker tag k8s-demo-app:v1 <account-id>.dkr.ecr.ap-south-1.amazonaws.com/k8s-demo-app:v1
docker push <account-id>.dkr.ecr.ap-south-1.amazonaws.com/k8s-demo-app:v1
```

### Image pull secret
Since ECR is a private registry, kubelet needs credentials to pull from it:
```bash
kubectl create secret docker-registry ecr-secret \
  --docker-server=<account-id>.dkr.ecr.ap-south-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region ap-south-1)
```
**Note:** this token expires after 12 hours. The CI/CD pipeline (below) refreshes it automatically on every deploy.

### ConfigMap
```bash
kubectl create configmap app-config \
  --from-literal=APP_NAME="K8s Demo App" \
  --from-literal=APP_VERSION="1.0.0" \
  --from-literal=ENVIRONMENT="production"
```

### Secret (demonstrating the pattern)
```bash
kubectl create secret generic app-secret \
  --from-literal=API_KEY="demo-fake-api-key-12345"
```

### Deployment (`k8s/deployment.yaml`)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: k8s-demo-app
  labels:
    app: k8s-demo-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: k8s-demo-app
  template:
    metadata:
      labels:
        app: k8s-demo-app
    spec:
      imagePullSecrets:
        - name: ecr-secret
      containers:
        - name: k8s-demo-app
          image: <account-id>.dkr.ecr.ap-south-1.amazonaws.com/k8s-demo-app:v3
          imagePullPolicy: Always
          ports:
            - containerPort: 80
          envFrom:
            - configMapRef:
                name: app-config
            - secretRef:
                name: app-secret
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
            failureThreshold: 3
```

### Service (`k8s/service.yaml`)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: k8s-demo-app-service
spec:
  type: NodePort
  selector:
    app: k8s-demo-app
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
```

### Ingress (`k8s/ingress.yaml`)
Requires the `ingress-nginx` controller (bare-metal manifest, since this isn't a cloud-LB-backed cluster):
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/baremetal/deploy.yaml
```
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k8s-demo-app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: k8s-demo-app-service
                port:
                  number: 80
```

Apply everything:
```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
```

App is reachable at: `http://<ec2-public-ip>:<ingress-nodeport>` (ingress-nginx assigns its own NodePort for HTTP, visible via `kubectl get svc -n ingress-nginx`).

---

## Kubernetes Commands Reference

```bash
# Cluster state
kubectl get nodes
kubectl get pods -o wide
kubectl get svc
kubectl get ingress

# Scaling
kubectl scale deployment k8s-demo-app --replicas=3

# Self-healing demo
kubectl delete pod <pod-name>          # watch it get replaced automatically
kubectl get pods -l app=k8s-demo-app -w

# Rolling update
kubectl set image deployment/k8s-demo-app k8s-demo-app=<new-image>:<tag>
kubectl rollout status deployment/k8s-demo-app

# Rollback
kubectl rollout undo deployment/k8s-demo-app
kubectl rollout history deployment/k8s-demo-app

# Debugging
kubectl describe pod <pod-name>
kubectl logs <pod-name>
kubectl exec -it <pod-name> -- sh

# Config/Secret verification
kubectl get configmap app-config -o yaml
kubectl get secret app-secret -o jsonpath='{.data.API_KEY}' | base64 -d
```

---

## CI/CD Pipeline

`.github/workflows/deploy.yml` — triggers on every push to `main`:

1. **Checkout code**
2. **Configure AWS credentials** (via GitHub Secrets — reusing the existing IAM user rather than provisioning a separate service account, a deliberate scope decision for this portfolio project)
3. **Login to ECR**
4. **Build & push Docker image**, tagged with the Git commit SHA for full traceability, plus a `latest` tag
5. **Trivy vulnerability scan** (CRITICAL/HIGH severities reported, non-blocking)
6. **Deploy via SSH** — connects to the EC2 instance and:
   - Refreshes the `ecr-secret` image pull secret (works around the 12-hour ECR token expiry without needing an IAM instance role)
   - Updates the Deployment's image to the newly built tag
   - Waits for rollout to complete

### Required GitHub Secrets

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | ECR auth |
| `AWS_SECRET_ACCESS_KEY` | ECR auth |
| `EC2_HOST` | Current EC2 public IP (updated manually on stop/start — no Elastic IP used) |
| `EC2_SSH_KEY` | Base64-encoded EC2 private key (see [Troubleshooting](#troubleshooting-notes) for why base64) |

---

## Troubleshooting Notes

Real issues hit and resolved during this project (kept here instead of a separate drill, since they surfaced organically):

- **PEM key "invalid format" on SSH** — caused by PowerShell's `>` redirect writing UTF-16 with BOM instead of ASCII. Fixed by recreating the key pair with `Out-File -Encoding ascii`.
- **PowerShell JSON quoting for `--block-device-mappings`** — nested double quotes with backslash escapes aren't interpreted the way they are in bash. Fixed by passing the JSON via a `file://` reference instead of inline.
- **`icacls` lockout** — granting read-only permissions to the key file also revoked the current user's own write access, blocking deletion. Fixed by re-granting full control before deleting.
- **YAML "Invalid workflow file" on a heredoc inside a `run:` block** — GitHub Actions' YAML parser is sensitive to indentation on multi-line heredoc terminators. Fixed by collapsing the SSH deploy command into a single-line string with `&&`-chained commands instead of a heredoc.
- **`entrypoint.sh: not found` in CI build** — files created directly on the EC2 instance were never pushed to GitHub, so the CI runner's checkout didn't have them. Root cause: editing the same repo from two unsynced clones (EC2 + local Cursor). Fixed by committing and pushing from EC2, then merging into the local clone.
- **Git merge conflicts across two clones** — resolved with `git checkout --ours <file>` to keep the actively-tested EC2 version during merge.
- **SSH key `error in libcrypto` inside the GitHub Actions runner** — pasting the PEM directly into a GitHub Secret introduced line-ending corruption. Fixed by base64-encoding the key locally, storing the encoded string as the secret, and decoding it (`base64 -d`) inside the workflow step.
- **Kubernetes Secrets are not encryption** — verified directly: `kubectl get secret ... | base64 -d` trivially recovers plaintext. Anyone with `kubectl get secret` access can read it. Production systems need etcd encryption-at-rest, tighter RBAC, and/or an external secrets manager (AWS Secrets Manager, Vault) on top of native Secrets.

---

## Lessons Learned

- **Multi-stage Docker builds** meaningfully shrink final image size by separating build-time tooling from the runtime image.
- **Runtime vs. build-time configuration** for static frontends requires a different pattern than backend apps — ConfigMaps can't reach compiled JS, so config has to be injected via a startup script that runs before the web server starts.
- **`kubeadm` has real minimum hardware requirements** (2 vCPU minimum) — unlike a plain Docker host, which will happily run on anything.
- **Self-managed Kubernetes needs a CNI plugin explicitly installed** (Calico here) — pod-to-pod networking isn't automatic like it is on EKS.
- **A single-node cluster needs its control-plane taint removed** or no workloads will ever schedule.
- **ECR image pull secrets expire every 12 hours** — a real operational gap that a proper production setup solves with an IAM instance role instead of manually recreated secrets (deferred here as a scope decision, documented in CI/CD refresh logic instead).
- **PowerShell and bash handle quoting, redirects, and encoding very differently** — several of the hardest bugs in this project were pure PowerShell quirks (UTF-16 file writes, nested-quote JSON parsing) rather than AWS or Kubernetes issues.
- **GitHub Secrets can silently corrupt multi-line values** — base64-encoding sensitive multi-line content before storing it as a secret avoids an entire class of encoding bugs.
- **Working across two unsynced Git clones causes real friction** — establishing one "source of truth" clone (local, in this case) for edits avoids repeated merge-conflict cycles.

---

## Possible Improvements

- Replace the manually-managed EC2 IP with an **Elastic IP** for a stable CI/CD target.
- Replace the shared-IAM-user CI/CD credentials with a **dedicated least-privilege service account**, following the same pattern used for the ECR-push IAM user in Project 1.
- Replace manual ECR secret refresh with an **IAM instance role** attached to the EC2 node, eliminating stored credentials entirely.
- Migrate from this self-managed single-node cluster to **AWS EKS**, to compare the operational overhead of self-managed vs. managed Kubernetes directly.
- Add **HTTPS via cert-manager + Let's Encrypt** once a real domain is attached.
- Add **Horizontal Pod Autoscaling (HPA)** based on CPU/memory metrics.
- Move `kubectl apply` in CI/CD to run against a **kubeconfig with restricted RBAC**, rather than full cluster-admin over SSH.
