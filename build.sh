#!/usr/bin/env bash
set -euo pipefail

TAG=$(cat VERSION)
IMAGE="custom-arc-runner:$TAG"

# Images to prebake into the runner. Each is saved as a tar and shipped in the
# runner image, then loaded into DinD by the preload-images init container at
# pod startup. This eliminates cold-start image pulls that fail under heavy
# parallel load when many runners pull the same image concurrently
# (see CLAUDE.md gotcha #13).
PRELOAD_IMAGES=(
  "ghcr.io/afonsojramos/postgres-arc:17"
)

PRELOAD_DIR="k8s/runner-image/preloaded-images"
mkdir -p "$PRELOAD_DIR"
rm -f "$PRELOAD_DIR"/*.tar

for img in "${PRELOAD_IMAGES[@]}"; do
  echo "Pulling $img for prebake..."
  docker pull "$img"
  fname=$(echo "$img" | sed 's|[/:]|_|g')
  echo "Saving as $PRELOAD_DIR/$fname.tar..."
  docker save "$img" -o "$PRELOAD_DIR/$fname.tar"
done

echo "Building $IMAGE..."
docker build -t "$IMAGE" k8s/runner-image/

echo "Importing into k3s containerd (k8s.io namespace)..."
docker save "$IMAGE" | sudo k3s ctr -n k8s.io images import -

echo "Updating image tag in values files..."
sed -i "s|custom-arc-runner:[0-9.]*|custom-arc-runner:$TAG|g" k8s/values/*.yaml

echo ""
echo "Done: $IMAGE built and imported."
echo "Preloaded images:"
for img in "${PRELOAD_IMAGES[@]}"; do
  echo "  - $img"
done
echo "Run 'helm upgrade' for each scale set to apply."
