#!/bin/bash
set -euo pipefail

# ── Load .env (if present) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

# ── Configuration ──
IMAGE="${IMAGE:-ghcr.io/youruser/custom-frappe}"
TAG="${TAG:-develop}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}"
PUSH="${PUSH:-false}"
CACHE_REF="${CACHE_REF:-${IMAGE}:buildcache}"
BUILDER="${BUILDER:-frappe-builder}"
# Default to host arch for local testing. Override with PLATFORM=linux/amd64
# if you ever need a cross-build (note: QEMU emulation of uv is unreliable —
# rely on CI for amd64 production builds).
PLATFORM="${PLATFORM:-}"

# ── Encode sites.json for Coolify runtime env ──
SITES_JSON_BASE64=$(base64 -w 0 sites.json 2>/dev/null || base64 -i sites.json)
echo ""
echo "SITES_JSON_BASE64 (paste into Coolify env vars):"
echo "$SITES_JSON_BASE64"
echo ""

# ── Ensure buildx builder with docker-container driver (needed for registry cache export) ──
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  echo "Creating buildx builder '$BUILDER' (docker-container driver)"
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap
fi
docker buildx use "$BUILDER"

# ── Register QEMU only when cross-building ──
HOST_PLATFORM="linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
if [ -n "$PLATFORM" ] && [ "$PLATFORM" != "$HOST_PLATFORM" ]; then
  echo "Cross-build target ($PLATFORM); registering QEMU emulators"
  docker run --rm --privileged tonistiigi/binfmt --install all >/dev/null
fi

# ── Login to ghcr.io early (needed for registry cache pull/push) ──
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_USER:-youruser}" --password-stdin
else
  echo "GITHUB_TOKEN not set — attempting interactive login (required for registry cache)"
  docker login ghcr.io
fi

# ── Compute tags ──
DATE_TAG="${TAG}-$(date +%Y%m%d-%H%M%S)"

# ── Build (with BuildKit cache mounts in Dockerfile + registry-backed layer cache) ──
echo "Building ${IMAGE}:${TAG} (frappe branch: ${FRAPPE_BRANCH})"

BUILDX_ARGS=(
  --secret=id=apps_json,src=apps.json
  --build-arg=FRAPPE_BRANCH="$FRAPPE_BRANCH"
  --cache-from=type=registry,ref="${CACHE_REF}"
  --cache-to=type=registry,ref="${CACHE_REF}",mode=max
  -t "${IMAGE}:${TAG}"
  -t "${IMAGE}:${DATE_TAG}"
  -t "${IMAGE}:latest"
)

# Pass GITHUB_TOKEN as a BuildKit secret so private apps in apps.json can be cloned.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  BUILDX_ARGS+=(--secret=id=github_token,env=GITHUB_TOKEN)
fi

[ -n "$PLATFORM" ] && BUILDX_ARGS+=(--platform="$PLATFORM")

if [ "$PUSH" = "true" ]; then
  BUILDX_ARGS+=(--push)
else
  # --load only works for single-platform builds. Foreign-arch images
  # still load into local docker but can't be `docker run` natively.
  BUILDX_ARGS+=(--load)
fi

docker buildx build "${BUILDX_ARGS[@]}" .

if [ "$PUSH" = "true" ]; then
  echo "Pushed ${IMAGE}:${TAG}, ${IMAGE}:${DATE_TAG}, ${IMAGE}:latest (cache: ${CACHE_REF})"
else
  echo "Built ${IMAGE}:${TAG}, ${IMAGE}:${DATE_TAG}, ${IMAGE}:latest (loaded into local docker)"
  echo "Set PUSH=true to push to ghcr.io."
fi
