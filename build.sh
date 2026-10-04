#!/usr/bin/env sh
# Build and push the ARMv7 image from any machine that has Docker.
#
#   ./build.sh yourdockerhubuser
#
# The iHost can then install it by searching for
#   yourdockerhubuser/ihost-sensorlog
# in the Docker page.
set -eu

USER_NAME="${1:-}"
TAG="${2:-latest}"

if [ -z "$USER_NAME" ]; then
  echo "usage: $0 <docker-hub-username-or-registry-prefix> [tag]" >&2
  exit 1
fi

IMAGE="$USER_NAME/ihost-sensorlog:$TAG"

docker buildx inspect ihost-builder >/dev/null 2>&1 \
  || docker buildx create --name ihost-builder --use

docker buildx use ihost-builder

# linux/arm/v7 is the one that matters: the iHost is a 32-bit Cortex-A7.
docker buildx build \
  --platform linux/arm/v7,linux/arm64,linux/amd64 \
  --tag "$IMAGE" \
  --push \
  .

echo
echo "Pushed $IMAGE"
echo "On the iHost: Docker -> + -> search '$USER_NAME/ihost-sensorlog'"
