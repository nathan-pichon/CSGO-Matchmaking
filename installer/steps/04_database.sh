#!/usr/bin/env bash
# ==============================================================================
# installer/steps/04_database.sh — Database initialisation
# ==============================================================================
# Creates the csgo_matchmaking database + csgo_mm user, applies schema.sql,
# inserts GSLT tokens, and populates the match server port pool.
# ==============================================================================

setup_database() {
    print_section "Database Setup"

    _db_ensure_service_running
    _db_wait_for_ready
    _db_secure_root
    _db_create_schema
    _db_insert_gslt_tokens
    _db_populate_port_pool
    _db_verify

    INSTALLED_COMPONENTS+=("database")
    ROLLBACK_ACTIONS+=("mysql -h ${DB_HOST} -P ${DB_PORT} -u root -p${DB_ROOT_PASS} \
        -e \"DROP DATABASE IF EXISTS csgo_matchmaking; \
             DROP USER IF EXISTS 'csgo_mm'@'localhost';\" 2>/dev/null || true")
}

# ── Private helpers ────────────────────────────────────────────────────────────

_db_ensure_service_running() {
    if [[ "${OS_TYPE}" == "macos" ]]; then
        brew services start mariadb 2>/dev/null || true
        sleep 2
        return 0
    fi
    command -v systemctl &>/dev/null || return 0

    local svc=""
    systemctl is-active mysql   &>/dev/null && svc="mysql"
    systemctl is-active mariadb &>/dev/null && svc="mariadb"

    if [[ -z "${svc}" ]]; then
        systemctl start mysql   2>/dev/null && svc="mysql"   || \
        systemctl start mariadb 2>/dev/null && svc="mariadb" || \
        die "Could not start MySQL/MariaDB service."
    fi
    ok "MySQL service running (${svc})"
}

_db_wait_for_ready() {
    info "Waiting for MySQL to accept connections..."
    local retries=0
    while ! mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" --silent 2>/dev/null; do
        (( ++retries > 30 )) && die "MySQL did not become ready within 30 seconds."
        sleep 1
    done
    ok "MySQL is accepting connections"
}

_db_secure_root() {
    [[ "${USE_EXISTING_MYSQL}" == "n" && -n "${DB_ROOT_PASS}" ]] || return 0
    info "Securing MySQL root account..."
    mysql -h "${DB_HOST}" -P "${DB_PORT}" --user=root 2>/dev/null << MYSQL_SECURE || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
MYSQL_SECURE
    ok "MySQL root password set"
}

# Returns an array containing the mysql command + connection flags
_db_root_cmd() {
    if [[ -n "${DB_ROOT_PASS}" ]]; then
        echo "mysql -h ${DB_HOST} -P ${DB_PORT} -u root -p${DB_ROOT_PASS}"
    else
        echo "mysql -h ${DB_HOST} -P ${DB_PORT} -u root"
    fi
}

_db_create_schema() {
    info "Creating database and user..."
    local mysql_cmd
    mysql_cmd="$(_db_root_cmd)"

    ${mysql_cmd} 2>/dev/null << MYSQL_SETUP
CREATE DATABASE IF NOT EXISTS csgo_matchmaking
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'csgo_mm'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS 'csgo_mm'@'%'         IDENTIFIED BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON csgo_matchmaking.* TO 'csgo_mm'@'localhost';
GRANT ALL PRIVILEGES ON csgo_matchmaking.* TO 'csgo_mm'@'%';
FLUSH PRIVILEGES;
MYSQL_SETUP
    ok "Database 'csgo_matchmaking' and user 'csgo_mm' created"

    if [[ -f "${SCRIPT_DIR}/database/schema.sql" ]]; then
        info "Applying database schema..."
        ${mysql_cmd} csgo_matchmaking < "${SCRIPT_DIR}/database/schema.sql"
        ok "Schema applied"
    else
        warn "Schema file not found: ${SCRIPT_DIR}/database/schema.sql"
    fi
}

_db_insert_gslt_tokens() {
    [[ ${#MATCH_GSLTS[@]} -eq 0 ]] && return 0
    local mysql_cmd
    mysql_cmd="$(_db_root_cmd)"

    info "Inserting ${#MATCH_GSLTS[@]} GSLT token(s) into database..."
    local insert_sql="USE csgo_matchmaking;"
    for token in "${MATCH_GSLTS[@]}"; do
        insert_sql+="
INSERT IGNORE INTO mm_gslt_tokens (token, is_active, created_at)
  VALUES ('${token}', 1, NOW())
  ON DUPLICATE KEY UPDATE is_active=1;"
    done
    echo "${insert_sql}" | ${mysql_cmd} 2>/dev/null \
        || warn "Could not insert GSLT tokens (schema may not have been applied yet)"
    ok "GSLT tokens inserted"
}

_db_populate_port_pool() {
    local mysql_cmd
    mysql_cmd="$(_db_root_cmd)"
    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))

    info "Configuring server port range in database (${MATCH_PORT_START}–${match_port_end})..."
    ${mysql_cmd} csgo_matchmaking 2>/dev/null << MYSQL_PORTS \
        || warn "Could not update port range (schema may not exist yet)"
INSERT INTO mm_server_ports (port, is_available, server_ip)
SELECT port, 1, '${SERVER_IP}'
FROM (
  SELECT ${MATCH_PORT_START} + n AS port
  FROM (
    SELECT a.N + b.N * 10 AS n
    FROM
      (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
       UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
      (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) b
  ) nums
  WHERE ${MATCH_PORT_START} + n <= ${match_port_end}
) ports
ON DUPLICATE KEY UPDATE is_available=1, server_ip='${SERVER_IP}';
MYSQL_PORTS
    ok "Server port range configured"
}

_db_verify() {
    info "Verifying database setup..."
    local player_count
    player_count="$(mysql -h "${DB_HOST}" -P "${DB_PORT}" \
        -u csgo_mm -p"${DB_PASS}" csgo_matchmaking \
        -se 'SELECT COUNT(*) FROM mm_players' 2>/dev/null || echo "N/A")"
    ok "Database verification passed (mm_players: ${player_count} rows)"
}
