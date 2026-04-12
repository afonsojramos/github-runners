# github-runners

Self-hosted GitHub Actions runner infrastructure using Actions Runner Controller (ARC) on a single-node k3s cluster. The previous Docker Compose stack is kept in `docker/` as a rollback path.

---

## Architecture

### Runtime

- **k3s** single-node cluster, installed via the official installer. Traefik is disabled.
- **ARC controller** (`gha-runner-scale-set-controller`) in the `arc-systems` namespace.
- **Runner scale sets** in `arc-runners`, each scaling `0 → 15` runners. Multiple scale sets share the namespace — one per org or repo scope.
- **Global pod cap** of 15 enforced via a `ResourceQuota` on `arc-runners`. Any single scope can burst to 15 if it's the only one busy; when multiple scopes contend it's first-come-first-served. See [`k8s/quota.yaml`](k8s/quota.yaml).
- **Listener pods** (one per scale set) live in `arc-systems`, polling GitHub's broker. Runner pods only exist while jobs are running — no idle cost.
- **Container mode**: `dind`. ARC auto-injects a privileged DinD sidecar per runner pod. CI jobs using `services:` or `docker run` talk to that sidecar — when the pod dies the daemon dies with it.
- **Local cache server**: [`falcondev-oss/github-actions-cache-server`](https://github.com/falcondev-oss/github-actions-cache-server) in `arc-cache`, backed by a 10 Gi PVC (SQLite + filesystem). In-cluster URL: `http://cache-server.arc-cache.svc.cluster.local:3000/`.

### Custom runner image

Built locally and imported into k3s's containerd. Based on [`falcondev-oss/actions-runner`](https://github.com/falcondev-oss/runner) (Ubuntu 24.04), adds Node.js 24, Playwright + Chromium, and a build toolchain (`build-essential`, `pkg-config`, `libssl-dev`, `git`, `rsync`, `zip`, `unzip`). See [`k8s/runner-image/Dockerfile`](k8s/runner-image/Dockerfile).

**Why falcondev's runner?** The official runner overwrites `ACTIONS_RESULTS_URL` with GitHub's own URL during job pickup, making it impossible to redirect cache traffic to a local server. The falcondev fork reads `CUSTOM_ACTIONS_RESULTS_URL` instead — an env var the runner process doesn't override. See [falcondev-oss/github-actions-cache-server#126](https://github.com/falcondev-oss/github-actions-cache-server/issues/126).

**Versioning**: semver tags, bump on every rebuild. kubelet caches images by tag, so reusing a tag is invisible to running pods. **Never use `:latest`** — Kubernetes forces `imagePullPolicy: Always` on it, which breaks locally-imported images.

**Cache env var**: `CUSTOM_ACTIONS_RESULTS_URL` is set on the runner container in the values files. Do **not** use `ACTIONS_CACHE_URL` or `ACTIONS_RESULTS_URL` — the runner process overwrites those.

### Custom postgres image

`FROM postgres:17` with `max_connections=300`. Hosted on a container registry because the DinD sidecar can only pull from registries (not k3s containerd). Used by parallel E2E suites that exhaust the default 100-connection pool. See [`k8s/postgres-image/Dockerfile`](k8s/postgres-image/Dockerfile).

### k3s kubelet tuning

[`k8s/k3s-config.yaml`](k8s/k3s-config.yaml) relaxes disk-pressure eviction and image GC thresholds for dev machines with limited free space. Without the eviction tuning, the node gets tainted `node.kubernetes.io/disk-pressure:NoSchedule` at <15% free disk. Without the image GC tuning, kubelet purges the custom runner image between jobs (since `minRunners: 0` makes it "unused"), causing `ImagePullBackOff`.

---

## Directory layout

```
.
├── CLAUDE.md                       # This file
├── README.md                       # Public-facing overview
├── .env                            # GitHub PATs (never commit)
├── docker/
│   ├── docker-compose.yml          # LEGACY — rollback path
│   └── Dockerfile                  # LEGACY — old myoung34-based runner
└── k8s/
    ├── runner-image/
    │   └── Dockerfile              # Custom ARC runner image
    ├── postgres-image/
    │   └── Dockerfile              # postgres:17 with max_connections=300
    ├── cache-server/
    │   └── deployment.yaml         # Namespace + PVC + Deployment + Service
    ├── k3s-config.yaml             # Kubelet tuning (disk pressure + image GC)
    ├── quota.yaml                  # ResourceQuota: 15 pod cap in arc-runners
    └── values/
        ├── org-runner.example.yaml   # Template for org-scoped runners
        ├── repo-runner.example.yaml  # Template for repo-scoped runners
        └── *.yaml                    # Actual values (gitignored)
```

---

## Operations

### Day-to-day

```bash
export KUBECONFIG=~/.kube/config

# Overall status
kubectl get pods -A | grep -E 'arc-|cache-server'
kubectl get AutoscalingRunnerSet -A
kubectl -n arc-runners get resourcequota

# Watch runners spawn
kubectl -n arc-runners get pods -w

# Listener logs (auth errors, job pickup issues)
kubectl -n arc-systems logs -l auto-scaling-runner-set-name=<runner-name> --tail=50 -f

# Controller logs
kubectl -n arc-systems logs deploy/arc-gha-rs-controller --tail=50 -f

# Cache server
kubectl -n arc-cache logs deploy/cache-server --tail=50
kubectl -n arc-cache exec deploy/cache-server -- wget -qO- http://localhost:3000
```

### Changing a scale set

Edit the values file under `k8s/values/` and re-apply:

```bash
helm upgrade <name>-runner -n arc-runners \
  -f k8s/values/<name>-runner.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

### Rebuilding the runner image

```bash
cd k8s/runner-image
NEW_TAG=x.y.z   # bump per semver
docker build -t custom-arc-runner:$NEW_TAG .
docker save custom-arc-runner:$NEW_TAG | sudo k3s ctr -n k8s.io images import -

# Update tag in values files, then helm upgrade each scale set
sed -i "s|custom-arc-runner:[0-9.]*|custom-arc-runner:$NEW_TAG|g" k8s/values/*.yaml
for f in <runner-names>; do
  helm upgrade $f -n arc-runners -f k8s/values/$f.yaml \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
done
```

Never reuse a tag. Always pass `-n k8s.io` to `k3s ctr import`.

### Adding a new runner scope

1. Copy the appropriate example: `cp k8s/values/org-runner.example.yaml k8s/values/<name>-runner.yaml`
2. Update `githubConfigUrl`, `githubConfigSecret`, and `runnerScaleSetName`.
3. Create a secret:
   ```bash
   kubectl create secret generic <name>-github-secret -n arc-runners \
     --from-literal=github_token="<PAT>"
   ```
4. Install:
   ```bash
   helm install <name>-runner -n arc-runners \
     -f k8s/values/<name>-runner.yaml \
     oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
   ```
5. In workflows, set `runs-on: <runnerScaleSetName>`.

---

## Workflow usage

```yaml
runs-on: my-runner   # matches runnerScaleSetName in the values file
```

`services:` blocks work out of the box via DinD:

```yaml
services:
  postgres:
    image: postgres:16
    env:
      POSTGRES_PASSWORD: postgres
    ports: ['5432:5432']
    options: --health-cmd pg_isready --health-interval 10s --health-retries 5
```

`actions/cache` (v4 and v5) transparently uses the local cache server via `CUSTOM_ACTIONS_RESULTS_URL` — no workflow changes needed.

---

## Configuration

- PATs live in `.env` (gitignored). Each scope needs its own PAT:
  - Org-scoped: needs `admin:org` permission
  - Repo-scoped: needs `repo` permission
- PATs are loaded into Kubernetes secrets in `arc-runners`. To rotate:
  ```bash
  kubectl -n arc-runners delete secret <name>-github-secret
  source .env
  kubectl create secret generic <name>-github-secret -n arc-runners \
    --from-literal=github_token="$MY_TOKEN"
  # Listeners auto-reload on next poll, or restart them manually.
  ```

---

## Known gotchas

1. **`:latest` tag breaks local images.** Kubelet forces `imagePullPolicy: Always` on `:latest`. Use versioned tags and bump on every rebuild.
2. **Containerd namespaces.** `k3s ctr images import` defaults to `default`, but kubelet pulls from `k8s.io`. Always pass `-n k8s.io`.
3. **Image GC purges the runner image.** With `minRunners: 0`, the image becomes "unused" between jobs. Default GC removes it at 85% disk. Mitigated via `image-gc-high-threshold=99` in k3s config.
4. **Disk-pressure taint.** k3s taints the node at <15% free disk. Tuned down in `k8s/k3s-config.yaml`. Check with `kubectl describe node | grep -E 'Taints|DiskPressure'`.
5. **Use `services:` for service containers.** `docker run --network container:$(hostname)` doesn't work in DinD on k8s. Use GitHub Actions `services:` blocks instead. Note: `services:` doesn't allow overriding CLI args (e.g. `-c max_connections=300`) — bake config into a custom image if needed.
6. **Runner image needs build tools.** The base runner image has no compiler. Native code compilation requires `build-essential`, `pkg-config`, `libssl-dev` — already baked into the custom image.
7. **Host needs `iptables`.** Docker requires `iptables-nft` on the host. k3s ships its own but the host package is needed for `docker build`.
8. **Runner pods disappear fast.** With `minRunners: 0`, pods only exist during jobs. Use `kubectl get pods -w` to catch them.
9. **VPN breaks in-cluster DNS.** VPNs that hijack port 53 (e.g. Mullvad) break CoreDNS. Disable the VPN or enable local network sharing if available.

---

## Rollback to Docker Compose

The legacy stack is in `docker/`. If ARC is broken:

```bash
cd docker && docker compose up -d --build
```

Then revert `runs-on:` values in workflows to `self-hosted`.

To tear down ARC:
```bash
helm uninstall <runner-names> -n arc-runners
helm uninstall arc -n arc-systems
kubectl delete namespace arc-runners arc-cache arc-systems
```

To remove k3s entirely:
```bash
/usr/local/bin/k3s-uninstall.sh
```

---

## First-time setup

Full cold-start sequence. Assumes Docker and `iptables-nft` are installed.

```bash
# 1. k3s + kubeconfig
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -
mkdir -p ~/.kube
sudo install -o $(id -u) -g $(id -g) -m 600 /etc/rancher/k3s/k3s.yaml ~/.kube/config
export KUBECONFIG=~/.kube/config

# 2. Kubelet tuning
sudo cp k8s/k3s-config.yaml /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s

# 3. Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 4. Build and import the runner image
cd k8s/runner-image
docker build -t custom-arc-runner:0.4.0 .
docker save custom-arc-runner:0.4.0 | sudo k3s ctr -n k8s.io images import -

# 5. Cache server
kubectl apply -f k8s/cache-server/deployment.yaml
kubectl -n arc-cache rollout status deploy/cache-server

# 6. ARC controller
helm install arc --namespace arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# 7. Secrets
kubectl create namespace arc-runners
source .env
kubectl create secret generic <name>-github-secret -n arc-runners \
  --from-literal=github_token="$MY_TOKEN"

# 8. Pod cap
kubectl apply -f k8s/quota.yaml

# 9. Scale sets (one per runner scope)
helm install <name>-runner -n arc-runners \
  -f k8s/values/<name>-runner.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

# 10. Verify
kubectl get pods -A | grep -E 'arc-|cache-server'
kubectl get AutoscalingRunnerSet -A
kubectl -n arc-runners get resourcequota
```
