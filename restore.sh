#!/bin/bash
set -euo pipefail

# ── Configuration ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILES=(-f docker-compose.coolify.yml)
[ -f docker-compose.override.yml ] && COMPOSE_FILES+=(-f docker-compose.override.yml)

# Load DB password from .env if not already set
if [ -z "${SERVICE_PASSWORD_DB:-}" ] && [ -f .env ]; then
  SERVICE_PASSWORD_DB=$(grep -E '^SERVICE_PASSWORD_DB=' .env | cut -d= -f2-)
fi
DB_ROOT_PASSWORD="${SERVICE_PASSWORD_DB:?Set SERVICE_PASSWORD_DB in .env or environment}"

# ── Usage ──
if [ $# -lt 2 ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "Usage: $0 <site-name> <backup-directory>"
  echo ""
  echo "  $0 erp.localhost ./backups/erp.localhost/20260212_120000/"
  echo ""
  echo "The backup directory should contain:"
  echo "  - *-database.sql.gz"
  echo "  - *-files.tar or *-files.tar.gz        (public files)"
  echo "  - *-private-files.tar or *.tar.gz       (private files)"
  echo ""
  echo "Requires SERVICE_PASSWORD_DB in .env or environment."
  exit 1
fi

SITE="$1"
BACKUP_PATH="$2"

# ── Validate backup directory ──
if [ ! -d "$BACKUP_PATH" ]; then
  echo "Error: Backup directory not found: $BACKUP_PATH"
  exit 1
fi

DB_FILE=$(ls "$BACKUP_PATH"/*-database.sql.gz 2>/dev/null | head -1)
if [ -z "$DB_FILE" ]; then
  echo "Error: No *-database.sql.gz found in $BACKUP_PATH"
  exit 1
fi

# Match both .tar and .tar.gz (bench may produce either)
FILES_FILE=$(ls "$BACKUP_PATH"/*-files.tar* 2>/dev/null | grep -v private | head -1)
PRIVATE_FILES_FILE=$(ls "$BACKUP_PATH"/*-private-files.tar* 2>/dev/null | head -1)

echo "── Restoring $SITE ──"
echo "  Database: $(basename "$DB_FILE")"
[ -n "$FILES_FILE" ] && echo "  Public files: $(basename "$FILES_FILE")"
[ -n "$PRIVATE_FILES_FILE" ] && echo "  Private files: $(basename "$PRIVATE_FILES_FILE")"

# ── Copy backup files into the container ──
CONTAINER=$(docker compose "${COMPOSE_FILES[@]}" ps -q backend)
RESTORE_DIR="/home/frappe/frappe-bench/sites/$SITE/private/backups"

docker compose "${COMPOSE_FILES[@]}" exec -T backend mkdir -p "$RESTORE_DIR"

echo ""
echo "Copying backup files into container..."
docker cp "$DB_FILE" "$CONTAINER:$RESTORE_DIR/"
[ -n "$FILES_FILE" ] && docker cp "$FILES_FILE" "$CONTAINER:$RESTORE_DIR/"
[ -n "$PRIVATE_FILES_FILE" ] && docker cp "$PRIVATE_FILES_FILE" "$CONTAINER:$RESTORE_DIR/"

# ── Build restore command (runs inside container, no MSYS path conversion) ──
DB_BASENAME=$(basename "$DB_FILE")
RESTORE_CMD="bench --site '$SITE' restore '$RESTORE_DIR/$DB_BASENAME'"
RESTORE_CMD="$RESTORE_CMD --mariadb-root-password \"\$DB_ROOT_PASSWORD\""
[ -n "$FILES_FILE" ] && RESTORE_CMD="$RESTORE_CMD --with-public-files '$RESTORE_DIR/$(basename "$FILES_FILE")'"
[ -n "$PRIVATE_FILES_FILE" ] && RESTORE_CMD="$RESTORE_CMD --with-private-files '$RESTORE_DIR/$(basename "$PRIVATE_FILES_FILE")'"

# ── Restore (pass DB password as env var to avoid quoting issues) ──
echo ""
echo "Restoring database and files..."
docker compose "${COMPOSE_FILES[@]}" exec -T -e DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" backend bash -c "$RESTORE_CMD"

# ── Migrate ──
echo ""
echo "Running migrate to ensure consistency..."
docker compose "${COMPOSE_FILES[@]}" exec -T backend bench --site "$SITE" migrate

echo ""
echo "Restore complete for $SITE."
