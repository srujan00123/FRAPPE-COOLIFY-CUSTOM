#!/bin/bash
set -euo pipefail

# ── Configuration ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILES=(-f docker-compose.coolify.yml)
[ -f docker-compose.override.yml ] && COMPOSE_FILES+=(-f docker-compose.override.yml)

LOCAL=false
SKIP_BACKUP=false

# ── Parse args ──
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=true ;;
    --skip-backup) SKIP_BACKUP=true ;;
    --help|-h)
      echo "Usage: $0 [--local] [--skip-backup]"
      echo ""
      echo "Safe update: backup all sites → rebuild image → restart stack"
      echo ""
      echo "  $0              Backup → build → push → restart"
      echo "  $0 --local      Backup → build → restart (no push)"
      echo "  $0 --skip-backup Skip backup step (use with caution)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

IMAGE="${IMAGE:-ghcr.io/youruser/custom-frappe}"
TAG="${TAG:-develop}"

echo "═══════════════════════════════════════"
echo "  Update: ${IMAGE}:${TAG}"
echo "═══════════════════════════════════════"

# ── Step 1: Backup ──
if [ "$SKIP_BACKUP" = "false" ]; then
  echo ""
  echo "── Step 1: Backup all sites ──"
  bash backup.sh
else
  echo ""
  echo "── Step 1: Backup SKIPPED ──"
fi

# ── Step 2: Build ──
echo ""
echo "── Step 2: Build new image ──"
if [ "$LOCAL" = "true" ]; then
  PUSH=false bash build.sh
else
  PUSH=true bash build.sh
fi

# ── Step 3: Restart stack ──
echo ""
echo "── Step 3: Restart stack with new image ──"
docker compose "${COMPOSE_FILES[@]}" pull --ignore-buildable 2>/dev/null || true
docker compose "${COMPOSE_FILES[@]}" up -d

echo ""
echo "═══════════════════════════════════════"
echo "  Update complete!"
echo "═══════════════════════════════════════"
echo ""
echo "Monitor startup:  docker compose ${COMPOSE_FILES[*]} logs -f"
echo ""
echo "── Rollback ──"
echo "If something goes wrong, restore from backup:"
echo "  1. Find your backup:  ls -la backups/"
echo "  2. Restore:           ./restore.sh <site-name> ./backups/<site>/<timestamp>/"
echo "  3. Or revert image:   IMAGE=$IMAGE TAG=<previous-tag> docker compose ${COMPOSE_FILES[*]} up -d"
