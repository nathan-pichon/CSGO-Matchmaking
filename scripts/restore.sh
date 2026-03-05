#!/usr/bin/env bash
# ============================================================
# CS:GO Matchmaking - Database Restore Script
# ============================================================
# Usage: ./scripts/restore.sh <backup_file.sql.gz>
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()   { echo -e "${GREEN}[RESTORE]${NC} $*"; }
warn()  { echo -e "${YELLOW}[RESTORE]${NC} $*"; }
error() { echo -e "${RED}[RESTORE]${NC} $*" >&2; }

if [[ $# -ne 1 ]]; then
    error "Usage: $0 <backup_file.sql.gz>"
    echo ""
    echo "Available backups:"
    ls -lh "${PROJECT_DIR}/backups/"*.sql.gz 2>/dev/null || echo "  (none found in ./backups/)"
    exit 1
fi

BACKUP_FILE="$1"

if [[ ! -f "$BACKUP_FILE" ]]; then
    error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    set -a; source <(grep -v '^#' "$CONFIG_FILE" | grep '='); set +a
else
    error "config.env not found"
    exit 1
fi

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-csgo_mm}"
DB_PASS="${DB_PASS:-}"
DB_NAME="${DB_NAME:-csgo_matchmaking}"

warn "⚠  WARNING: This will OVERWRITE the database '${DB_NAME}' with:"
warn "   ${BACKUP_FILE}"
warn ""
read -r -p "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    log "Restore cancelled."
    exit 0
fi

log "Restoring from: ${BACKUP_FILE}"

if ! command -v mysql &>/dev/null; then
    error "mysql client not found."
    exit 1
fi

# Stop matchmaker if running (to avoid conflicts)
if systemctl is-active --quiet csgo-matchmaker 2>/dev/null; then
    warn "Stopping csgo-matchmaker service..."
    sudo systemctl stop csgo-matchmaker
    RESTART_MATCHMAKER=true
fi

# Restore
if zcat "$BACKUP_FILE" | mysql \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    --password="$DB_PASS" \
    "$DB_NAME" 2>/dev/null; then
    log "Restore complete!"
else
    error "Restore FAILED!"
    exit 1
fi

# Restart matchmaker if we stopped it
if [[ "${RESTART_MATCHMAKER:-false}" == "true" ]]; then
    log "Restarting csgo-matchmaker service..."
    sudo systemctl start csgo-matchmaker
fi

log "Database restored successfully from ${BACKUP_FILE}"
