# Game 2048 — Kubernetes Deployment (DevOps Home Task)

A production-style Kubernetes deployment for the [2048 game](https://github.com/gabrielecirulli/2048), packaged as a Helm chart with a full CI/CD pipeline using GitHub Actions.

---

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────┐
│  Ingress (nginx controller) │
│  host: game2048.local       │
└────────────┬────────────────┘
             │ port 80
             ▼
┌─────────────────────────────┐
│  Service (ClusterIP)        │
│  port 80                    │
└────────────┬────────────────┘
             │
    ┌────────┴────────┐
    ▼                 ▼
┌────────┐       ┌────────┐
│ Pod 1  │       │ Pod 2  │   ← managed by Deployment + HPA
│ nginx  │       │ nginx  │
└────────┘       └────────┘
     ↑
ConfigMap (nginx.conf mounted)
```

---

## Helm Chart

### Why `Deployment` and not `StatefulSet`?

The 2048 game is a **stateless** application — nginx serves static HTML/JS files with no persistent storage, no stable network identity, and no ordered startup requirements. A `Deployment` is the correct choice because:

- Pods are interchangeable — any replica can serve any request
- No persistent volumes or stable hostnames are needed
- Rolling updates and horizontal scaling are straightforward

`StatefulSet` would only be appropriate for databases, message queues, or apps that require sticky identity per pod.

### Chart components

| Template | Description |
|---|---|
| `deployment.yaml` | 2 replicas, liveness & readiness probes, resource limits |
| `service.yaml` | ClusterIP service on port 80 |
| `ingress.yaml` | nginx Ingress routing to `game2048.local` |
| `hpa.yaml` | HorizontalPodAutoscaler — scales 2–5 pods at 70% CPU |
| `configmap.yaml` | Custom `nginx.conf` with security headers + caching rules |

### Key features
- **Liveness probe** — restarts the pod if nginx stops responding
- **Readiness probe** — removes pod from load balancer until it's ready
- **Resource requests/limits** — prevents noisy-neighbour issues
- **Security headers** — `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`
- **ConfigMap-mounted nginx config** — config is external to the image; change without rebuilding

### Deploy locally (Docker Desktop)

```bash
# 1. Build the image
docker build -t game2048:local .

# 2. Install the chart
helm upgrade --install game2048 ./helm/game2048
```

#### Prerequisites — one-time setup

**Nginx Ingress Controller** (single entry point for all cluster traffic):
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml
```

**Add hostnames to `/etc/hosts`:**
```bash
echo "127.0.0.1 game2048.local" | sudo tee -a /etc/hosts
echo "127.0.0.1 argocd.local"   | sudo tee -a /etc/hosts
```

**Patch ArgoCD to HTTP mode** (enables HTTP access via Ingress — fine for local dev):
```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
```

**Apply ArgoCD Ingress:**
```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: argocd.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF
```

#### Accessing the apps (no port-forward needed)

| App | URL | Notes |
|---|---|---|
| **2048 Game** | http://game2048.local | Served via nginx Ingress |
| **ArgoCD UI** | http://argocd.local | Username: `admin` |

Get the ArgoCD admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## CI/CD Pipeline (GitHub Actions)

### Git workflow

```
feature/* → dev (PR)     → pr_open.yaml
dev       → master (PR)  → pr_open.yaml
master    ← merge        → pr_accept.yaml
```

### Smart path-based triggering

Both workflows use **`dorny/paths-filter@v3`** to detect exactly what changed and skip unnecessary work:

| Changed files | Jobs that run |
|---|---|
| `Dockerfile` | helm-lint + SAST + build + scan + version bump |
| `helm/**` only | helm-lint + chart version bump only (same image redeployed) |
| `README.md` only | nothing (no deployment needed) |

This means a Helm config change (e.g. resource limits) triggers a redeployment with the **same image** but updated chart — no unnecessary Docker build.

### `pr_open.yaml` — triggered on PR to `dev`

```
detect ──→ helm-lint (if helm or Dockerfile changed)
       ├── sast       (if Dockerfile changed)
       └── build-push (if Dockerfile changed) → security-scan
```

| Job | Runs when | Behaviour |
|---|---|---|
| `detect` | always | Detects which paths changed |
| `helm-lint` | helm OR Dockerfile changed | Fails if chart is invalid |
| `sast` | Dockerfile changed | Semgrep scan, fails on ERROR severity |
| `build-push` | Dockerfile changed | Pushes `snap-game2048:v{ver}-pr{N}-g{sha}` |
| `security-scan` | Dockerfile changed | Trivy — fails on fixable HIGH/CRITICAL CVEs |

### `pr_accept.yaml` — triggered on merge to `master`

```
detect ──→ helm-lint      (if helm or Dockerfile changed)
       ├── sast            (if Dockerfile changed)
       └── compute-version (if helm or Dockerfile changed)
                └──→ build-push     (if Dockerfile changed)
                           └──→ security-scan
                                      └──→ bump-and-tag → deploy

on success → release-drafter.yml runs → creates GitHub Release
```

| Job | Runs when | Description |
|---|---|---|
| `detect` | always | Detects changed paths |
| `helm-lint` | helm OR Dockerfile changed | Helm chart validation |
| `sast` | Dockerfile changed | Semgrep scan, fails on ERROR |
| `compute-version` | helm OR Dockerfile changed | Dockerfile changed → bump appVersion + chart version; helm-only → bump chart version only |
| `build-push` | Dockerfile changed | Pushes `ghcr.io/.../game2048:{appVersion}` + `latest` |
| `security-scan` | Dockerfile changed | Trivy — blocks deploy on fixable HIGH/CRITICAL CVEs |
| `bump-and-tag` | any change (safe gate) | Updates `Chart.yaml` and pushes to master |
| `deploy` | bump-and-tag succeeded | Triggers ArgoCD sync for immediate deployment |

### `release-drafter.yml` — triggered when `pr_accept` succeeds

Automatically creates a **GitHub Release** with a categorized changelog after every successful merge to master.

- Reads PR labels to categorize changes and determine version bump
- Creates a git tag (`v{version}`) and a published GitHub Release
- Runs **after** `pr_accept` completes — ensures the release points to the final bumped commit

| PR Label | Category in release notes | Version bump |
|---|---|---|
| `feat`, `feature` | 🚀 Features | minor |
| `fix`, `bug` | 🐛 Bug Fixes | patch |
| `security`, `cve` | 🔒 Security | patch |
| `ci`, `cd` | 🔧 CI/CD | patch |
| `docs` | 📚 Documentation | patch |
| `breaking` | 💥 Breaking Changes | major |
| `chore`, `refactor` | 🧰 Maintenance | patch |
| *(no label)* | *(uncategorized)* | patch |

> Add a `skip-changelog` label to exclude a PR from release notes entirely.

### Docker build & registry

Images are built using **Docker BuildKit** via the `docker/build-push-action@v6` GitHub Actions marketplace action. BuildKit is Docker's modern build engine — it's used automatically under the hood and provides:
- Parallel layer builds (faster)
- Cache mounts
- Secure secret mounts (secrets never leaked into image layers)
- Multi-platform cross-compilation support (`linux/amd64`, `linux/arm64`)

Images are pushed to **GitHub Container Registry (ghcr.io)** — a private registry included with every GitHub account, no extra setup required.

| Image | Registry | Tag format | When |
|---|---|---|---|
| `snap-game2048` | `ghcr.io/yairm1/snap-game2048` | `v{ver}-pr{N}-g{sha}` | PR open |
| `game2048` | `ghcr.io/yairm1/game2048` | `{ver}` + `latest` | Merge to master |

### Version bumping strategy

- `Chart.yaml` is the **single source of truth** for the version (`appVersion` field)
- Each merge to `master` auto-bumps the **patch** version (e.g. `1.0.4 → 1.0.5`)
- A git tag (`v1.0.5`) is created on the exact merge commit for full traceability
- The Docker image tag comes directly from `Chart.AppVersion` — image tag ↔ git tag ↔ source commit ↔ Helm chart are all in sync

### DevSecOps tools

| Tool | Type | Gate |
|---|---|---|
| [Semgrep](https://semgrep.dev) | SAST | Fails pipeline on ERROR-severity findings |
| [Trivy](https://trivy.dev) | Image CVE scan | Blocks deploy on HIGH or CRITICAL CVEs |

#### Trivy dual-step pattern

Trivy runs **twice** per pipeline to serve two purposes:

| Step | Format | exit-code | Purpose |
|---|---|---|---|
| Step 1 | `table` | `0` | Prints human-readable CVE list in the job log (always visible, never blocks) |
| Step 2 | `sarif` | `1` | Gates the pipeline (fails on fixable HIGH/CRITICAL) + feeds GitHub Security tab |

Both steps use `ignore-unfixed: true` — CVEs with no available fix are shown but do not block the pipeline.

#### GitHub Security tab (SARIF upload)

The SARIF file produced by Trivy is uploaded to GitHub via `github/codeql-action/upload-sarif@v3`. This populates the **Security → Code scanning alerts** tab on the repository with structured vulnerability data:

```
Security → Code scanning alerts
  ⚠ HIGH   libssl CVE-2024-xxxx  (nginx:alpine)
  ⚠ HIGH   libcrypto CVE-...     (nginx:alpine)
```

> **Note:** The Security tab upload requires **GitHub Advanced Security**, which is free for public repos but a paid feature for private repos. The upload step uses `continue-on-error: true` so the pipeline is not blocked if the upload fails — but the SARIF exit-code gate still prevents a vulnerable image from being merged.

> **Note on dependency scanning:** Since this is a static HTML/JS app with no package manager (`npm`/`pip`/etc.), tools like `npm audit` or OWASP Dependency-Check are not applicable. Trivy covers OS-level package CVEs in the nginx base image.

---

## Secrets required

| Secret | Used in | Description |
|---|---|---|
| `GITHUB_TOKEN` | Both workflows | Auto-injected — used for ghcr.io push and SARIF upload |
| `ARGOCD_SERVER` | `pr_accept.yaml` | ArgoCD server hostname/IP (e.g. `argocd.example.com`) |
| `ARGOCD_TOKEN` | `pr_accept.yaml` | ArgoCD API token — generate with `argocd account generate-token` |

> **Local dev note:** When ArgoCD runs locally (Docker Desktop), the GitHub Actions runner cannot reach `localhost`. The deploy job uses `continue-on-error: true` so the pipeline still passes. ArgoCD auto-syncs within ~3 minutes regardless.
