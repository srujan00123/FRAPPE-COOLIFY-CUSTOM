#!/bin/bash
set -euo pipefail

# ── Configuration ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILES=(-f docker-compose.coolify.yml)
[ -f docker-compose.override.yml ] && COMPOSE_FILES+=(-f docker-compose.override.yml)

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ── Usage ──
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "Usage: $0 [site-name]"
  echo ""
  echo "  $0              Backup all sites from sites.json"
  echo "  $0 erp.localhost Backup a single site"
  exit 0
fi

# ── Determine sites to backup ──
if [ -n "${1:-}" ]; then
  SITES=("$1")
elif [ -n "${SITES_JSON_BASE64:-}" ]; then
  SITES=($(echo "$SITES_JSON_BASE64" | base64 -d | python -c "import json,sys; [print(s['name']) for s in json.load(sys.stdin)]" | tr -d '\r'))
elif [ -f sites.json ]; then
  SITES=($(python -c "import json; [print(s['name']) for s in json.load(open('sites.json'))]" | tr -d '\r'))
else
  echo "Error: No site specified and no sites.json or SITES_JSON_BASE64 found"
  exit 1
fi

echo "Backing up ${#SITES[@]} site(s): ${SITES[*]}"

for SITE in "${SITES[@]}"; do
  echo ""
  echo "── Backing up $SITE ──"

  # Run bench backup inside the backend container and capture the database path
  BENCH_OUTPUT=$(docker compose "${COMPOSE_FILES[@]}" exec -T backend \
    bench --site "$SITE" backup --with-files 2>&1)
  echo "$BENCH_OUTPUT"

  # Extract the backup timestamp prefix from the database filename
  BACKUP_PREFIX=$(echo "$BENCH_OUTPUT" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1 | tr -d '\r')
  if [ -z "$BACKUP_PREFIX" ]; then
    echo "Error: Could not determine backup timestamp from bench output"
    exit 1
  fi

  # Find all backup files matching this timestamp
  BACKUP_FILES=$(docker compose "${COMPOSE_FILES[@]}" exec -T backend \
    ls -1 "sites/$SITE/private/backups/" | tr -d '\r' | grep "^${BACKUP_PREFIX}")

  # Create local backup directory
  DEST="backups/$SITE/$TIMESTAMP"
  mkdir -p "$DEST"

  # Copy each backup file out
  CONTAINER=$(docker compose "${COMPOSE_FILES[@]}" ps -q backend)
  for FILE in $BACKUP_FILES; do
    FILE=$(echo "$FILE" | tr -d '\r')
    docker cp "$CONTAINER:/home/frappe/frappe-bench/sites/$SITE/private/backups/$FILE" "$DEST/"
  done

  echo "Backup saved to: $DEST"
  ls -lh "$DEST/"
done

echo ""
echo "All backups complete."
