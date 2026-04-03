#!/bin/bash
set -euo pipefail

# ── Configuration ──
IMAGE="${IMAGE:-ghcr.io/youruser/custom-frappe}"
TAG="${TAG:-develop}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}"
PUSH="${PUSH:-false}"

# ── Encode JSON configs ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
APPS_JSON_BASE64=$(base64 -w 0 apps.json 2>/dev/null || base64 -i apps.json)
SITES_JSON_BASE64=$(base64 -w 0 sites.json 2>/dev/null || base64 -i sites.json)
echo ""
echo "SITES_JSON_BASE64 (paste into Coolify env vars):"
echo "$SITES_JSON_BASE64"
echo ""

# ── Build ──
PLATFORM="${PLATFORM:-linux/amd64}"
echo "Building ${IMAGE}:${TAG} (frappe branch: ${FRAPPE_BRANCH}, platform: ${PLATFORM})"
docker build \
  --platform="${PLATFORM}" \
  --build-arg=APPS_JSON_BASE64="$APPS_JSON_BASE64" \
  --build-arg=FRAPPE_BRANCH="$FRAPPE_BRANCH" \
  -t "${IMAGE}:${TAG}" \
  .

# ── Version tag (for rollback) ──
DATE_TAG="${TAG}-$(date +%Y%m%d)"
docker tag "${IMAGE}:${TAG}" "${IMAGE}:${DATE_TAG}"
docker tag "${IMAGE}:${TAG}" "${IMAGE}:latest"
echo "Built ${IMAGE}:${TAG} (also tagged ${DATE_TAG}, latest)"

# ── Push ──
if [ "$PUSH" = "true" ]; then
  # Log in to ghcr.io (uses GITHUB_TOKEN env var, or prompts interactively)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_USER:-youruser}" --password-stdin
  else
    echo "GITHUB_TOKEN not set — attempting interactive login"
    docker login ghcr.io
  fi

  echo "Pushing ${IMAGE}:${TAG}, ${IMAGE}:${DATE_TAG}, and ${IMAGE}:latest"
  docker push "${IMAGE}:${TAG}"
  docker push "${IMAGE}:${DATE_TAG}"
  docker push "${IMAGE}:latest"
  echo "Pushed ${IMAGE}:${TAG}, ${IMAGE}:${DATE_TAG}, and ${IMAGE}:latest"
else
  echo "Skipping push. Run with PUSH=true to push, or:"
  echo "  docker push ${IMAGE}:${TAG}"
fi
