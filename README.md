# arc-runners

Self-hosted GitHub Actions runner infrastructure using [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) on a single-node [k3s](https://k3s.io) cluster.

## Features

- **Zero idle cost** — runner pods scale from 0 and are destroyed after each job
- **Local cache server** — [falcondev-oss/github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server) backed by a 10 Gi PVC, transparent to workflows via `CUSTOM_ACTIONS_RESULTS_URL`
- **DinD container mode** — full Docker support inside jobs (`services:` blocks, `docker run`, etc.) with automatic cleanup
- **Custom runner image** — Node.js 24, Playwright + Chromium, and a build toolchain pre-installed
- **Global pod cap** — `ResourceQuota` limits total concurrent runners across all scale sets

## Architecture

```
k3s cluster
├── arc-systems        Controller + listener pods (always running)
├── arc-runners        Ephemeral runner pods (0 when idle)
└── arc-cache          Local cache server + PVC
```

Runner pods use DinD sidecars — each pod gets its own Docker daemon that dies with it. CI jobs using `services:` (postgres, redis, etc.) or `docker run` work out of the box.

The cache server intercepts `actions/cache` requests locally. This requires the [falcondev-oss/runner](https://github.com/falcondev-oss/runner) fork, which reads `CUSTOM_ACTIONS_RESULTS_URL` — the official runner overwrites the standard env vars with GitHub's URLs during job pickup.

## Directory layout

```
.
├── k8s/
│   ├── runner-image/
│   │   └── Dockerfile          # Custom ARC runner image
│   ├── postgres-image/
│   │   └── Dockerfile          # postgres:17 with max_connections=300
│   ├── cache-server/
│   │   └── deployment.yaml     # Namespace + PVC + Deployment + Service
│   ├── values/
│   │   ├── zlar-runner.yaml    # Helm values per scale set
│   │   ├── lutus-runner.yaml
│   │   └── oakslot-runner.yaml
│   ├── quota.yaml              # ResourceQuota (15 pod cap)
│   └── k3s-config.yaml         # Kubelet tuning (disk pressure + image GC)
├── docker/
│   ├── docker-compose.yml      # Legacy Docker Compose stack (rollback path)
│   └── Dockerfile              # Legacy myoung34-based runner image
├── CLAUDE.md                   # Detailed operational documentation
└── .env                        # GitHub PATs (not committed)
```

## Quick start

### Prerequisites

- Linux host with Docker installed
- `iptables-nft` package
- [Helm](https://helm.sh)

### Install

```bash
# 1. k3s
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -
mkdir -p ~/.kube
sudo install -o $(id -u) -g $(id -g) -m 600 /etc/rancher/k3s/k3s.yaml ~/.kube/config

# 2. Kubelet tuning (prevents disk-pressure taints and image GC on dev machines)
sudo cp k8s/k3s-config.yaml /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s

# 3. Build and import the runner image
cd k8s/runner-image
docker build -t custom-arc-runner:0.4.0 .
docker save custom-arc-runner:0.4.0 | sudo k3s ctr -n k8s.io images import -

# 4. Cache server
kubectl apply -f k8s/cache-server/deployment.yaml

# 5. ARC controller
helm install arc --namespace arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# 6. Secrets
kubectl create namespace arc-runners
source .env
kubectl create secret generic my-github-secret -n arc-runners \
  --from-literal=github_token="$MY_TOKEN"

# 7. Pod cap
kubectl apply -f k8s/quota.yaml

# 8. Scale sets
helm install my-runner -n arc-runners \
  -f k8s/values/my-runner.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

### Use in workflows

```yaml
runs-on: my-runner
```

`actions/cache@v4` and `actions/cache@v5` transparently use the local cache server — no workflow changes needed.

## Configuration

### Adding a runner scope

1. Copy an existing `k8s/values/*.yaml` file
2. Update `githubConfigUrl`, `githubConfigSecret`, and `runnerScaleSetName`
3. Create a Kubernetes secret with the GitHub PAT
4. `helm install` the new scale set

### Rebuilding the runner image

Always bump the tag — kubelet caches by tag and ignores rebuilt images with the same tag.

```bash
docker build -t custom-arc-runner:$NEW_TAG k8s/runner-image/
docker save custom-arc-runner:$NEW_TAG | sudo k3s ctr -n k8s.io images import -
# Update tag in k8s/values/*.yaml, then helm upgrade each scale set
```

### Cache server

The local cache server stores artifacts on a PVC and serves them to runners over the cluster network. Cache entries are automatically cleaned up after 7 days.

The `CUSTOM_ACTIONS_RESULTS_URL` env var on the runner container redirects cache traffic to the local server. Do **not** use `ACTIONS_CACHE_URL` or `ACTIONS_RESULTS_URL` — the runner process overwrites those.

## Known gotchas

See [CLAUDE.md](CLAUDE.md) for a complete list. The most common ones:

- **Never use `:latest` tag** for locally-imported images — kubelet forces `imagePullPolicy: Always`
- **Always pass `-n k8s.io`** to `k3s ctr images import`
- **VPN software** (especially Mullvad) can break in-cluster DNS by hijacking port 53
- **Disk pressure** taints the node at <15% free space — tune kubelet thresholds via `k8s/k3s-config.yaml`

## Legacy Docker Compose stack

The `docker/` directory contains the previous runner infrastructure based on [myoung34/github-runner](https://github.com/myoung34/docker-github-actions-runner). It's kept as a rollback path:

```bash
cd docker && docker compose up -d --build
```

## License

[MIT](LICENSE)
