#!/usr/bin/env bash
# ============================================================
# CS:GO Matchmaking - System Health Check
# ============================================================
# Usage: ./scripts/health_check.sh [--json]
# Returns exit code 0 if healthy, 1 if any check fails.
# --json: output as JSON (for monitoring systems)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.env"
JSON_OUTPUT=false
[[ "${1:-}" == "--json" ]] && JSON_OUTPUT=true

# Colors (disabled for JSON mode)
if [[ "$JSON_OUTPUT" == "false" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''; BOLD=''
fi

CHECKS=()
FAILURES=0

pass() { CHECKS+=("{\"check\":\"$1\",\"status\":\"ok\",\"detail\":\"$2\"}");  [[ "$JSON_OUTPUT" == "false" ]] && echo -e "  ${GREEN}✓${NC} $1: $2"; }
fail() { CHECKS+=("{\"check\":\"$1\",\"status\":\"fail\",\"detail\":\"$2\"}"); [[ "$JSON_OUTPUT" == "false" ]] && echo -e "  ${RED}✗${NC} $1: $2"; ((FAILURES++)); }
warn() { CHECKS+=("{\"check\":\"$1\",\"status\":\"warn\",\"detail\":\"$2\"}"); [[ "$JSON_OUTPUT" == "false" ]] && echo -e "  ${YELLOW}~${NC} $1: $2"; }

[[ "$JSON_OUTPUT" == "false" ]] && echo -e "\n${BOLD}CS:GO Matchmaking - Health Check${NC}\n"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    set -a; source <(grep -v '^#' "$CONFIG_FILE" | grep '='); set +a
    pass "config" "config.env loaded"
else
    fail "config" "config.env not found at $PROJECT_DIR/config.env"
fi

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-csgo_mm}"
DB_PASS="${DB_PASS:-}"
DB_NAME="${DB_NAME:-csgo_matchmaking}"

# 1. MySQL connectivity
if mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
         --password="$DB_PASS" --connect-timeout=5 \
         -e "SELECT 1;" "$DB_NAME" &>/dev/null; then
    pass "mysql" "Connected to ${DB_HOST}:${DB_PORT}/${DB_NAME}"
else
    fail "mysql" "Cannot connect to MySQL at ${DB_HOST}:${DB_PORT}"
fi

# 2. DB tables exist
if mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
         --password="$DB_PASS" -e "SHOW TABLES LIKE 'mm_players';" "$DB_NAME" 2>/dev/null \
         | grep -q mm_players; then
    # Get some stats
    PLAYER_COUNT=$(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
                         --password="$DB_PASS" -Nse "SELECT COUNT(*) FROM mm_players;" "$DB_NAME" 2>/dev/null || echo "?")
    QUEUE_COUNT=$(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
                        --password="$DB_PASS" -Nse "SELECT COUNT(*) FROM mm_queue WHERE status='waiting';" "$DB_NAME" 2>/dev/null || echo "?")
    ACTIVE_MATCHES=$(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
                           --password="$DB_PASS" -Nse "SELECT COUNT(*) FROM mm_matches WHERE status IN ('warmup','live','overtime');" "$DB_NAME" 2>/dev/null || echo "?")
    pass "db_schema" "Tables OK | Players: ${PLAYER_COUNT} | Queue: ${QUEUE_COUNT} | Active matches: ${ACTIVE_MATCHES}"
else
    fail "db_schema" "mm_players table missing — run: mysql $DB_NAME < database/schema.sql"
fi

# 3. Docker
if command -v docker &>/dev/null && docker info &>/dev/null; then
    CONTAINER_COUNT=$(docker ps --filter "name=csgo-match-" --format "{{.Names}}" | wc -l)
    pass "docker" "Docker running | ${CONTAINER_COUNT} match container(s) active"
else
    fail "docker" "Docker not running or not accessible"
fi

# 4. Matchmaker service
if systemctl is-active --quiet csgo-matchmaker 2>/dev/null; then
    pass "matchmaker" "csgo-matchmaker service is running"
elif pgrep -f "matchmaker.py" &>/dev/null; then
    warn "matchmaker" "matchmaker.py process running (not as systemd service)"
else
    fail "matchmaker" "Matchmaker daemon not running"
fi

# 5. Lobby server
if systemctl is-active --quiet csgo-lobby 2>/dev/null; then
    pass "lobby" "csgo-lobby service is running"
elif pgrep -f "srcds_run.*27015" &>/dev/null || pgrep -f "srcds_linux" &>/dev/null; then
    warn "lobby" "srcds process found (not as systemd service)"
else
    warn "lobby" "Lobby server not detected (may be started manually)"
fi

# 6. Web panel
if systemctl is-active --quiet csgo-webpanel 2>/dev/null; then
    pass "webpanel" "csgo-webpanel service is running"
elif curl -sf "http://localhost:${WEB_PORT:-5000}/api/queue/count" &>/dev/null; then
    pass "webpanel" "Web panel responding on port ${WEB_PORT:-5000}"
else
    warn "webpanel" "Web panel not responding on port ${WEB_PORT:-5000}"
fi

# 7. Disk space
DISK_AVAIL=$(df -BG "$PROJECT_DIR" | awk 'NR==2{print $4}' | tr -d 'G')
if [[ "$DISK_AVAIL" -ge 10 ]]; then
    pass "disk" "${DISK_AVAIL}GB available"
elif [[ "$DISK_AVAIL" -ge 5 ]]; then
    warn "disk" "Only ${DISK_AVAIL}GB available — consider cleanup"
else
    fail "disk" "Critically low disk space: ${DISK_AVAIL}GB"
fi

# 8. GSLT tokens available
GSLT_FREE=$(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
                  --password="$DB_PASS" -Nse "SELECT COUNT(*) FROM mm_gslt_tokens WHERE in_use=0;" "$DB_NAME" 2>/dev/null || echo "0")
GSLT_TOTAL=$(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
                   --password="$DB_PASS" -Nse "SELECT COUNT(*) FROM mm_gslt_tokens;" "$DB_NAME" 2>/dev/null || echo "0")
if [[ "$GSLT_TOTAL" -eq 0 ]]; then
    fail "gslt_tokens" "No GSLT tokens configured — add them via install.sh or INSERT INTO mm_gslt_tokens"
elif [[ "$GSLT_FREE" -eq 0 ]]; then
    warn "gslt_tokens" "All ${GSLT_TOTAL} GSLT token(s) in use — no capacity for new matches"
else
    pass "gslt_tokens" "${GSLT_FREE}/${GSLT_TOTAL} token(s) available"
fi

# 9. Port pool
PORT_FREE=$(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
                  --password="$DB_PASS" -Nse "SELECT COUNT(*) FROM mm_server_ports WHERE in_use=0;" "$DB_NAME" 2>/dev/null || echo "0")
if [[ "$PORT_FREE" -gt 0 ]]; then
    pass "port_pool" "${PORT_FREE} port slot(s) available for match servers"
else
    warn "port_pool" "No free ports in pool — check mm_server_ports table"
fi

# 10. Stale matches (stuck in warmup > 30 min)
STALE=$(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
              --password="$DB_PASS" -Nse \
              "SELECT COUNT(*) FROM mm_matches WHERE status='warmup' AND started_at < NOW() - INTERVAL 30 MINUTE;" \
              "$DB_NAME" 2>/dev/null || echo "0")
if [[ "$STALE" -eq 0 ]]; then
    pass "stale_matches" "No stale matches detected"
else
    warn "stale_matches" "${STALE} match(es) stuck in warmup for >30 min — matchmaker may need attention"
fi

# Output
[[ "$JSON_OUTPUT" == "false" ]] && echo ""

if [[ "$JSON_OUTPUT" == "true" ]]; then
    JOINED=$(IFS=,; echo "${CHECKS[*]}")
    echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"failures\":${FAILURES},\"checks\":[${JOINED}]}"
else
    if [[ $FAILURES -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All checks passed!${NC}"
    else
        echo -e "${RED}${BOLD}${FAILURES} check(s) failed!${NC}"
    fi
    echo ""
fi

exit $FAILURES
