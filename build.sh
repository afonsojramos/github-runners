#!/usr/bin/env bash
set -euo pipefail

TAG=$(cat VERSION)
IMAGE="custom-arc-runner:$TAG"

echo "Building $IMAGE..."
docker build -t "$IMAGE" k8s/runner-image/

echo "Importing into k3s containerd (k8s.io namespace)..."
docker save "$IMAGE" | sudo k3s ctr -n k8s.io images import -

echo "Updating image tag in values files..."
sed -i "s|custom-arc-runner:[0-9.]*|custom-arc-runner:$TAG|g" k8s/values/*.yaml

echo ""
echo "Done: $IMAGE built and imported."
echo "Run 'helm upgrade' for each scale set to apply."
