#!/usr/bin/env bash
# ============================================================
# CS:GO Matchmaking - Database Backup Script
# ============================================================
# Usage: ./scripts/backup.sh [backup_dir]
# Default backup dir: ./backups/
#
# Creates a timestamped gzipped SQL dump.
# Keeps the last 30 backups (auto-prune).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.env"
BACKUP_DIR="${1:-${PROJECT_DIR}/backups}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
KEEP_BACKUPS=30

# Color codes
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

log()   { echo -e "${GREEN}[BACKUP]${NC} $*"; }
warn()  { echo -e "${YELLOW}[BACKUP]${NC} $*"; }
error() { echo -e "${RED}[BACKUP]${NC} $*" >&2; }

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source <(grep -v '^#' "$CONFIG_FILE" | grep '='); set +a
else
    error "config.env not found at $CONFIG_FILE"
    error "Set DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME manually or create config.env"
    exit 1
fi

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-csgo_mm}"
DB_PASS="${DB_PASS:-}"
DB_NAME="${DB_NAME:-csgo_matchmaking}"

BACKUP_FILE="${BACKUP_DIR}/csgo_mm_${TIMESTAMP}.sql.gz"

# Create backup directory
mkdir -p "$BACKUP_DIR"

log "Starting backup of database '${DB_NAME}'..."
log "Target: ${BACKUP_FILE}"

# Check mysqldump is available
if ! command -v mysqldump &>/dev/null; then
    error "mysqldump not found. Install mysql-client."
    exit 1
fi

# Perform backup
if mysqldump \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    --password="$DB_PASS" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --add-drop-table \
    --extended-insert \
    --complete-insert \
    "$DB_NAME" 2>/dev/null | gzip -9 > "$BACKUP_FILE"; then

    SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    log "Backup complete: ${BACKUP_FILE} (${SIZE})"
else
    error "Backup FAILED!"
    rm -f "$BACKUP_FILE"
    exit 1
fi

# Prune old backups (keep last N)
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "csgo_mm_*.sql.gz" | wc -l)
if [[ $BACKUP_COUNT -gt $KEEP_BACKUPS ]]; then
    TO_DELETE=$((BACKUP_COUNT - KEEP_BACKUPS))
    warn "Pruning ${TO_DELETE} old backup(s) (keeping last ${KEEP_BACKUPS})..."
    find "$BACKUP_DIR" -name "csgo_mm_*.sql.gz" \
        | sort \
        | head -n "$TO_DELETE" \
        | xargs rm -f
    log "Pruning complete."
fi

REMAINING=$(find "$BACKUP_DIR" -name "csgo_mm_*.sql.gz" | wc -l)
log "Done. ${REMAINING} backup(s) retained in ${BACKUP_DIR}"
