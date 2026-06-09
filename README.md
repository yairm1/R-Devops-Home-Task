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

# 3. Access the app
kubectl port-forward svc/game2048-game2048 8080:80
# → open http://localhost:8080
```

---

## CI/CD Pipeline (GitHub Actions)

### Git workflow

```
feature/* → dev (PR)     → pr_open.yaml
dev       → master (PR)  → pr_open.yaml
master    ← merge        → pr_accept.yaml
```

### `pr_open.yaml` — triggered on PR to `dev`

```
helm-lint → sast → build-push (snapshot) → security-scan
```

| Job | Tool | Behaviour |
|---|---|---|
| `helm-lint` | Helm | Fails if chart is invalid |
| `sast` | Semgrep | Scans source + Dockerfile; fails on ERROR-severity findings |
| `build-push` | Docker + ghcr.io | Pushes `snapshot-pr<N>-<sha>` image |
| `security-scan` | Trivy | Scans image; **fails on HIGH or CRITICAL** |

### `pr_accept.yaml` — triggered on merge to `master`

```
helm-lint ──┐
sast        ├──→ build-push → security-scan ──→ bump-and-tag
compute-ver ┘                              └──→ deploy
```

| Job | Description |
|---|---|
| `helm-lint` | Helm chart validation |
| `sast` | Semgrep scan, fails on ERROR |
| `compute-version` | Reads `VERSION` file, bumps patch (e.g. `1.0.0 → 1.0.1`) |
| `build-push` | Pushes `ghcr.io/.../game2048:1.0.1` + `latest` |
| `security-scan` | Trivy — blocks deploy on HIGH/CRITICAL |
| `bump-and-tag` | Creates git tag `v1.0.1` on merge commit + bumps `VERSION` |
| `deploy` | `helm upgrade --install` using immutable version tag |

### Version bumping strategy

- Version is stored in the `VERSION` file at the repo root
- Each merge to `master` auto-bumps the **patch** version
- A git tag (`v1.0.1`) is created on the exact merge commit for full traceability
- Docker image is tagged with the same version — image tag ↔ git tag ↔ source commit

### DevSecOps tools

| Tool | Type | Gate |
|---|---|---|
| [Semgrep](https://semgrep.dev) | SAST | Fails pipeline on ERROR-severity findings |
| [Trivy](https://trivy.dev) | Image CVE scan | Blocks deploy on HIGH or CRITICAL CVEs |

> SARIF results are uploaded to the GitHub Security tab (requires GitHub Advanced Security for private repos).

> **Note on dependency scanning:** Since this is a static HTML/JS app with no package manager (`npm`/`pip`/etc.), tools like `npm audit` or OWASP Dependency-Check are not applicable. Trivy covers OS-level package CVEs in the nginx base image.

---

## Secrets required

| Secret | Used in | Description |
|---|---|---|
| `GITHUB_TOKEN` | Both workflows | Auto-injected — used for ghcr.io push |
| `KUBECONFIG` | `pr_accept.yaml` | Base64-encoded kubeconfig for the target cluster |
