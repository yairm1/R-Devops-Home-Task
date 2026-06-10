# Traffic Flow: Browser → App

```mermaid
flowchart TD
    Browser["🌐 Browser\ngame2048.local"]

    subgraph OS["Host Machine"]
        Hosts["/etc/hosts\ngame2048.local → 127.0.0.1"]
    end

    subgraph K8S["Kubernetes Cluster (Docker Desktop)"]
        subgraph Ingress["Ingress Layer"]
            IC["Nginx Ingress Controller\n(Pod: ingress-nginx namespace)\nPort 80"]
            IR["Ingress Resource\nhost: game2048.local\npath: /"]
        end

        subgraph App["Application (game2048 namespace)"]
            SVC["Service\nClusterIP\nPort 80"]
            POD1["Pod 1\nnginx:alpine\nPort 80"]
            POD2["Pod 2\nnginx:alpine\nPort 80"]
        end

        subgraph Config["Configuration"]
            CM["ConfigMap\nnginx.conf\n(security headers + caching)"]
        end
    end

    Browser -->|"DNS lookup"| Hosts
    Hosts -->|"127.0.0.1:80"| IC
    IC -->|"matches host + path rule"| IR
    IR -->|"routes to backend Service"| SVC
    SVC -->|"load balances"| POD1
    SVC -->|"load balances"| POD2
    CM -->|"mounted at\n/etc/nginx/conf.d/default.conf"| POD1
    CM -->|"mounted at\n/etc/nginx/conf.d/default.conf"| POD2
```

## Component descriptions

| Component | Role |
|---|---|
| `/etc/hosts` | Maps `game2048.local` to `127.0.0.1` (local dev only) |
| **Nginx Ingress Controller** | Single entry point for all cluster traffic. Listens on host port 80, reads Ingress rules |
| **Ingress Resource** | Routing rule: requests for `game2048.local/` → forward to the `game2048` Service |
| **Service (ClusterIP)** | Stable internal DNS name + load balancer across all matching Pods |
| **Pod (nginx:alpine)** | Serves the 2048 static HTML/JS/CSS files |
| **ConfigMap** | Custom `nginx.conf` — adds security headers (`X-Frame-Options`, `CSP`) and caching rules; mounted into every Pod |

## How the Ingress Controller knows which Service to use

The Ingress Resource (`ingress.yaml`) declares the backend explicitly:

```yaml
rules:
  - host: game2048.local
    http:
      paths:
        - path: /
          backend:
            service:
              name: game2048   # ← resolved by _helpers.tpl fullname
              port:
                number: 80
```

The controller reads this rule and forwards matching requests directly to that Service by name within the cluster DNS.
