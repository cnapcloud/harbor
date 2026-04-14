#!/bin/bash
# Harbor multiarch build script (arm64 + amd64)
# Run from the repository root directory
# Requires: Docker Buildx

set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

VERSIONTAG="${VERSIONTAG:-v2.15.10}"
IMAGENAMESPACE="${IMAGENAMESPACE:-cnapcloud}"
REGISTRYSERVER="${REGISTRYSERVER:-}"  # e.g. registry.example.com/
TRIVYFLAG="${TRIVYFLAG:-false}"

IMAGES=(
  "harbor-log"
  "registry-photon"
  "harbor-registryctl"
  "harbor-db"
  "harbor-core"
  "harbor-portal"
  "harbor-jobservice"
  "redis-photon"
  "nginx-photon"
  "harbor-exporter"
)

if [ "$TRIVYFLAG" = "true" ]; then
  IMAGES+=("trivy-adapter-photon")
fi

echo "=== Harbor Multiarch Build ==="
echo "  VERSION     : $VERSIONTAG"
echo "  NAMESPACE   : $IMAGENAMESPACE"
echo "  REGISTRY    : ${REGISTRYSERVER:-dockerhub}"
echo "  TRIVY       : $TRIVYFLAG"
echo ""

# buildx builder 확인
docker buildx inspect multiarch-builder &>/dev/null \
  || docker buildx create --name multiarch-builder --use
docker buildx use multiarch-builder

# ── Step 1: arm64 빌드 ────────────────────────────────────────────
echo "[1/4] Compiling and building arm64..."
make compile \
  VERSIONTAG="$VERSIONTAG" \
  GOARCH=arm64

make build \
  VERSIONTAG="${VERSIONTAG}-arm64" \
  IMAGENAMESPACE="$IMAGENAMESPACE" \
  BASEIMAGENAMESPACE="$IMAGENAMESPACE" \
  BASEIMAGETAG="$VERSIONTAG" \
  ARCH=arm64 \
  BUILD_BASE=true \
  PUSHBASEIMAGE=false \
  PULL_BASE_FROM_DOCKERHUB=false \
  TRIVYFLAG="$TRIVYFLAG"

# ── Step 2: amd64 빌드 ────────────────────────────────────────────
echo "[2/4] Compiling and building amd64..."
make compile \
  VERSIONTAG="$VERSIONTAG" \
  GOARCH=amd64

make build \
  VERSIONTAG="${VERSIONTAG}-amd64" \
  IMAGENAMESPACE="$IMAGENAMESPACE" \
  BASEIMAGENAMESPACE=goharbor \
  BASEIMAGETAG=v2.15.0 \
  ARCH=amd64 \
  BUILD_BASE=false \
  PULL_BASE_FROM_DOCKERHUB=true \
  TRIVYFLAG="$TRIVYFLAG"

# ── Step 3: push ──────────────────────────────────────────────────
echo "[3/4] Pushing arch-tagged images..."
for IMAGE in "${IMAGES[@]}"; do
  docker push "${REGISTRYSERVER}${IMAGENAMESPACE}/${IMAGE}:${VERSIONTAG}-arm64"
  docker push "${REGISTRYSERVER}${IMAGENAMESPACE}/${IMAGE}:${VERSIONTAG}-amd64"
done

# ── Step 4: multi-arch manifest ───────────────────────────────────
echo "[4/4] Creating multi-arch manifests with buildx..."
for IMAGE in "${IMAGES[@]}"; do
  ARM64_TAG="${REGISTRYSERVER}${IMAGENAMESPACE}/${IMAGE}:${VERSIONTAG}-arm64"
  AMD64_TAG="${REGISTRYSERVER}${IMAGENAMESPACE}/${IMAGE}:${VERSIONTAG}-amd64"
  MANIFEST_TAG="${REGISTRYSERVER}${IMAGENAMESPACE}/${IMAGE}:${VERSIONTAG}"

  docker buildx imagetools create \
    -t "$MANIFEST_TAG" \
    "$ARM64_TAG" \
    "$AMD64_TAG"

  echo "  ✔ $MANIFEST_TAG"
done

echo ""
echo "=== Multiarch build complete ==="
