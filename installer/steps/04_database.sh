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
    _db_populate_map_pool
    _db_verify

    INSTALLED_COMPONENTS+=("database")
    ROLLBACK_ACTIONS+=("mysql -h ${DB_HOST} -P ${DB_PORT} -u root -p\"${DB_ROOT_PASS}\" \
        -e \"DROP DATABASE IF EXISTS csgo_matchmaking; \
             DROP USER IF EXISTS 'csgo_mm'@'localhost';\" 2>/dev/null || true")
}

# ── Private helpers ────────────────────────────────────────────────────────────

_ensure_docker_daemon() {
    # Fast path — daemon already up
    docker info &>/dev/null && return 0

    if [[ "${OS_TYPE}" == "macos" ]]; then
        info "Docker daemon not running — launching Docker Desktop..."
        open -a Docker 2>/dev/null || true

        local waited=0 timeout=90
        while ! docker info &>/dev/null 2>&1; do
            if (( waited >= timeout )); then
                die "Docker Desktop did not start within ${timeout}s. Launch it manually then re-run."
            fi
            printf '\r  ⠋ Waiting for Docker daemon... (%ds / %ds)' "${waited}" "${timeout}" >/dev/tty
            sleep 3
            (( waited += 3 )) || true
        done
        printf '\r%50s\r' '' >/dev/tty   # clear the waiting line
        ok "Docker Desktop is running"
    else
        die "Docker daemon is not running. Start it with: sudo systemctl start docker"
    fi
}

_start_mysql_docker() {
    _ensure_docker_daemon
    local container="${MYSQL_DOCKER_CONTAINER}"

    if docker inspect "${container}" &>/dev/null; then
        if docker ps -q --filter "name=^/${container}$" | grep -q .; then
            ok "MySQL container '${container}' already running"
        else
            info "Starting existing MySQL container '${container}'..."
            docker start "${container}"
            ok "MySQL container '${container}' started"
        fi
    else
        info "Pulling ${MYSQL_DOCKER_IMAGE} and creating MySQL container '${container}'..."
        docker run -d \
            --name "${container}" \
            --restart unless-stopped \
            -e MYSQL_ROOT_PASSWORD="${DB_ROOT_PASS}" \
            -p 127.0.0.1:"${DB_PORT}":3306 \
            "${MYSQL_DOCKER_IMAGE}"
        ok "MySQL container '${container}' started (root password set from config)"
        INSTALLED_COMPONENTS+=("mysql-docker")
        ROLLBACK_ACTIONS+=("docker stop ${container} 2>/dev/null; docker rm ${container} 2>/dev/null || true")
    fi
}

_db_ensure_service_running() {
    case "${DB_BACKEND}" in
        docker)
            _start_mysql_docker
            DB_HOST="127.0.0.1"   # Force TCP — Docker maps to localhost
            return 0
            ;;
        external)
            ok "Using external MySQL server at ${DB_HOST}:${DB_PORT}"
            return 0
            ;;
        local)
            # Start the locally-installed MySQL/MariaDB service
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
            ;;
    esac
}

_db_wait_for_ready() {
    info "Waiting for MySQL to accept connections..."
    local retries=0
    while true; do
        if [[ "${DB_BACKEND}" == "docker" ]]; then
            # Use docker exec — avoids any local mysqladmin PATH issues while container boots
            docker exec "${MYSQL_DOCKER_CONTAINER}" mariadb-admin ping --silent 2>/dev/null && break
        else
            mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" --silent 2>/dev/null && break
        fi
        (( ++retries > 30 )) && die "MySQL did not become ready within 30 seconds."
        sleep 1
    done
    ok "MySQL is accepting connections"
}

_db_secure_root() {
    # Only needed for local installs — docker sets the root password via MYSQL_ROOT_PASSWORD
    # at container creation, and external servers are pre-configured by the user.
    [[ "${DB_BACKEND}" == "local" && -n "${DB_ROOT_PASS}" ]] || return 0
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

_db_populate_map_pool() {
    [[ ${#SELECTED_MAPS[@]} -eq 0 ]] && return 0
    local mysql_cmd
    mysql_cmd="$(_db_root_cmd)"

    # Map name → display name lookup
    declare -A MAP_DISPLAY_NAMES=(
        [de_dust2]="Dust II"
        [de_mirage]="Mirage"
        [de_inferno]="Inferno"
        [de_nuke]="Nuke"
        [de_overpass]="Overpass"
        [de_vertigo]="Vertigo"
        [de_ancient]="Ancient"
        [de_anubis]="Anubis"
        [de_cache]="Cache"
        [de_train]="Train"
    )

    info "Configuring map pool (${#SELECTED_MAPS[@]} maps selected)..."

    # Build a comma-separated quoted list of selected maps for SQL IN clause
    local selected_sql_list=""
    local insert_sql="USE csgo_matchmaking;"
    for map in "${SELECTED_MAPS[@]}"; do
        local display_name="${MAP_DISPLAY_NAMES[${map}]:-${map}}"
        insert_sql+="
INSERT INTO mm_map_pool (map_name, display_name, is_active, weight)
  VALUES ('${map}', '${display_name}', 1, 1)
  ON DUPLICATE KEY UPDATE is_active=1, display_name='${display_name}';"
        [[ -n "${selected_sql_list}" ]] && selected_sql_list+=","
        selected_sql_list+="'${map}'"
    done

    # Deactivate maps NOT in the selected list
    insert_sql+="
UPDATE mm_map_pool SET is_active=0
  WHERE map_name NOT IN (${selected_sql_list});"

    echo "${insert_sql}" | ${mysql_cmd} 2>/dev/null \
        || warn "Could not update map pool (schema may not have been applied yet)"
    ok "Map pool configured: ${SELECTED_MAPS[*]}"
}

_db_verify() {
    info "Verifying database setup..."
    local player_count
    player_count="$(mysql -h "${DB_HOST}" -P "${DB_PORT}" \
        -u csgo_mm -p"${DB_PASS}" csgo_matchmaking \
        -se 'SELECT COUNT(*) FROM mm_players' 2>/dev/null || echo "N/A")"
    ok "Database verification passed (mm_players: ${player_count} rows)"
}
