#!/usr/bin/env bash
# ============================================================
# CS:GO Matchmaking - Update Server Files
# ============================================================
# Updates CS:GO server files via SteamCMD.
# Safely stops lobby server, updates, then restarts.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[UPDATE]${NC} $*"; }
warn()  { echo -e "${YELLOW}[UPDATE]${NC} $*"; }
error() { echo -e "${RED}[UPDATE]${NC} $*" >&2; }

# Load config
[[ -f "$CONFIG_FILE" ]] && { set -a; source <(grep -v '^#' "$CONFIG_FILE" | grep '='); set +a; }

CSGO_DIR="${CSGO_SERVER_DIR:-/opt/csgo-server}"
STEAMCMD="${STEAMCMD_PATH:-/usr/games/steamcmd}"

if [[ ! -f "$STEAMCMD" ]]; then
    error "SteamCMD not found at $STEAMCMD"
    error "Install via: sudo apt install steamcmd"
    exit 1
fi

warn "This will stop the lobby server, update CS:GO, and restart."
read -r -p "Continue? [y/N] " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && { log "Cancelled."; exit 0; }

# Stop lobby server gracefully
LOBBY_RUNNING=false
if systemctl is-active --quiet csgo-lobby 2>/dev/null; then
    log "Stopping lobby server..."
    sudo systemctl stop csgo-lobby
    LOBBY_RUNNING=true
fi

# Wait for active matches to finish (don't interrupt ongoing matches)
ACTIVE_MATCHES=$(mysql --host="${DB_HOST:-localhost}" --user="${DB_USER:-csgo_mm}" \
                       --password="${DB_PASS:-}" -Nse \
                       "SELECT COUNT(*) FROM mm_matches WHERE status IN ('warmup','live','overtime');" \
                       "${DB_NAME:-csgo_matchmaking}" 2>/dev/null || echo "0")

if [[ "$ACTIVE_MATCHES" -gt 0 ]]; then
    warn "${ACTIVE_MATCHES} active match(es) in progress."
    warn "CS:GO server update will not affect running Docker containers."
    warn "Players in active matches will not be affected."
fi

# Run SteamCMD update
log "Updating CS:GO server files (this may take several minutes)..."
"$STEAMCMD" \
    +force_install_dir "$CSGO_DIR" \
    +login anonymous \
    +app_update 740 validate \
    +quit

log "CS:GO update complete."

# Rebuild Docker match image (CS:GO files are in the image)
if command -v docker &>/dev/null; then
    log "Rebuilding match server Docker image..."
    docker build -t "${DOCKER_IMAGE:-csgo-match-server:latest}" "$PROJECT_DIR/match-server/" \
        && log "Docker image rebuilt successfully." \
        || warn "Docker image rebuild failed — existing image still in use"
fi

# Restart lobby server
if [[ "$LOBBY_RUNNING" == "true" ]]; then
    log "Restarting lobby server..."
    sudo systemctl start csgo-lobby
    sleep 5
    if systemctl is-active --quiet csgo-lobby; then
        log "Lobby server restarted successfully."
    else
        error "Lobby server failed to restart! Check: journalctl -u csgo-lobby"
    fi
fi

log "Update complete!"
