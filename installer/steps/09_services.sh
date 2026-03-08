#!/usr/bin/env bash
# ==============================================================================
# installer/steps/09_services.sh — Systemd services, validation, final summary
# ==============================================================================
# Three public functions:
#   generate_systemd_services — write unit files (or macOS launchd plist)
#   validate_installation     — 10-point health check, returns error count
#   print_summary             — human-friendly completion screen
# ==============================================================================

generate_systemd_services() {
    print_section "Systemd Service Configuration"

    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "systemd not available on macOS."
        _generate_macos_launchd
        return 0
    fi

    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found — this system may not use systemd. Skipping."
        return 0
    fi

    _write_lobby_service
    _write_matchmaker_service
    _write_webpanel_service

    info "Reloading systemd daemon..."
    systemctl daemon-reload

    info "Enabling services (autostart on boot)..."
    systemctl enable csgo-lobby csgo-matchmaker csgo-webpanel 2>/dev/null \
        || warn "Could not enable one or more services"

    _configure_firewall

    info "Starting services..."
    # Start matchmaker and web panel immediately; lobby requires CS:GO files
    systemctl start csgo-matchmaker 2>/dev/null \
        && ok "csgo-matchmaker started" \
        || warn "csgo-matchmaker could not be started — check: journalctl -u csgo-matchmaker"
    systemctl start csgo-webpanel 2>/dev/null \
        && ok "csgo-webpanel started" \
        || warn "csgo-webpanel could not be started — check: journalctl -u csgo-webpanel"
    if [[ -f "${CSGO_DIR}/srcds_run" ]]; then
        systemctl start csgo-lobby 2>/dev/null \
            && ok "csgo-lobby started" \
            || warn "csgo-lobby could not be started — check: journalctl -u csgo-lobby"
    else
        warn "CS:GO files not found — csgo-lobby will start automatically once they are downloaded."
        info "Start it manually later with: sudo systemctl start csgo-lobby"
    fi

    ok "All systemd services configured and enabled"
    INSTALLED_COMPONENTS+=("systemd-services")
    ROLLBACK_ACTIONS+=("systemctl disable csgo-lobby csgo-matchmaker csgo-webpanel 2>/dev/null; \
        rm -f /etc/systemd/system/csgo-lobby.service \
              /etc/systemd/system/csgo-matchmaker.service \
              /etc/systemd/system/csgo-webpanel.service; \
        systemctl daemon-reload")
}

# ── Firewall configuration ─────────────────────────────────────────────────────

_configure_firewall() {
    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))
    local ports_to_open=(
        "${LOBBY_PORT}/udp"           # CS:GO Lobby server (game traffic)
        "${LOBBY_PORT}/tcp"           # CS:GO Lobby server (RCON + Steam)
        "${WEB_PORT}/tcp"             # Web panel (HTTP)
    )
    # Add match server port range
    for (( p=MATCH_PORT_START; p<=match_port_end; p++ )); do
        ports_to_open+=("${p}/udp" "${p}/tcp")
    done

    if command -v ufw &>/dev/null; then
        info "Configuring UFW firewall rules..."
        ufw allow "${LOBBY_PORT}/udp"   comment 'CSGO-MM Lobby (game)' 2>/dev/null || true
        ufw allow "${LOBBY_PORT}/tcp"   comment 'CSGO-MM Lobby (RCON)' 2>/dev/null || true
        ufw allow "${WEB_PORT}/tcp"     comment 'CSGO-MM Web Panel'    2>/dev/null || true
        if (( MATCH_SLOTS > 0 )); then
            ufw allow "${MATCH_PORT_START}:${match_port_end}/udp" \
                comment 'CSGO-MM Match Servers (game)'  2>/dev/null || true
            ufw allow "${MATCH_PORT_START}:${match_port_end}/tcp" \
                comment 'CSGO-MM Match Servers (RCON)'  2>/dev/null || true
        fi
        ok "UFW rules added (lobby: ${LOBBY_PORT}, web: ${WEB_PORT}, match: ${MATCH_PORT_START}-${match_port_end})"
        INSTALLED_COMPONENTS+=("firewall-ufw")

    elif command -v firewall-cmd &>/dev/null; then
        info "Configuring firewalld rules..."
        firewall-cmd --permanent --add-port="${LOBBY_PORT}/udp"  2>/dev/null || true
        firewall-cmd --permanent --add-port="${LOBBY_PORT}/tcp"  2>/dev/null || true
        firewall-cmd --permanent --add-port="${WEB_PORT}/tcp"    2>/dev/null || true
        if (( MATCH_SLOTS > 0 )); then
            firewall-cmd --permanent \
                --add-port="${MATCH_PORT_START}-${match_port_end}/udp" 2>/dev/null || true
            firewall-cmd --permanent \
                --add-port="${MATCH_PORT_START}-${match_port_end}/tcp" 2>/dev/null || true
        fi
        firewall-cmd --reload 2>/dev/null || true
        ok "firewalld rules added (lobby: ${LOBBY_PORT}, web: ${WEB_PORT}, match: ${MATCH_PORT_START}-${match_port_end})"
        INSTALLED_COMPONENTS+=("firewall-firewalld")

    elif command -v iptables &>/dev/null; then
        info "Configuring iptables rules..."
        # Use -C (check) before -A (append) to avoid duplicate rules on retries
        _ipt_allow() {
            local proto="$1" port="$2"
            iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null \
                || true
        }
        _ipt_allow udp "${LOBBY_PORT}"
        _ipt_allow tcp "${LOBBY_PORT}"
        _ipt_allow tcp "${WEB_PORT}"
        if (( MATCH_SLOTS > 0 )); then
            iptables -C INPUT -p udp \
                    --dport "${MATCH_PORT_START}:${match_port_end}" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p udp \
                    --dport "${MATCH_PORT_START}:${match_port_end}" -j ACCEPT 2>/dev/null || true
            iptables -C INPUT -p tcp \
                    --dport "${MATCH_PORT_START}:${match_port_end}" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p tcp \
                    --dport "${MATCH_PORT_START}:${match_port_end}" -j ACCEPT 2>/dev/null || true
        fi
        ok "iptables rules added (lobby: ${LOBBY_PORT}, web: ${WEB_PORT}, match: ${MATCH_PORT_START}-${match_port_end})"
        warn "iptables rules are not persistent. Install 'iptables-persistent' to keep them across reboots."
        INSTALLED_COMPONENTS+=("firewall-iptables")

    else
        warn "No firewall tool found (ufw / firewall-cmd / iptables)."
        warn "You must manually open these ports:"
        warn "  UDP+TCP ${LOBBY_PORT}                         (lobby server)"
        warn "  TCP     ${WEB_PORT}                           (web panel)"
        warn "  UDP+TCP ${MATCH_PORT_START}–${match_port_end} (match servers)"
    fi
}

# ── Systemd unit writers ───────────────────────────────────────────────────────

_write_lobby_service() {
    info "Generating csgo-lobby.service..."
    local csgo_bin="${CSGO_DIR}/srcds_run"
    cat > /etc/systemd/system/csgo-lobby.service << LOBBY_UNIT
[Unit]
Description=CS:GO Matchmaking Lobby Server
After=network.target mysql.service mariadb.service
Wants=mysql.service mariadb.service

[Service]
Type=simple
User=${STEAM_USER}
WorkingDirectory=${CSGO_DIR}
ExecStart=${csgo_bin} \\
    -game csgo \\
    -console \\
    -usercon \\
    +game_type 0 \\
    +game_mode 0 \\
    -tickrate 128 \\
    -maxplayers_override 64 \\
    -port ${LOBBY_PORT} \\
    +sv_setsteamaccount ${LOBBY_GSLT} \\
    +exec server.cfg \\
    +map ${SELECTED_MAPS[0]:-de_dust2}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
EnvironmentFile=-${CONFIG_FILE}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
LOBBY_UNIT
    ok "csgo-lobby.service created"
}

_write_matchmaker_service() {
    info "Generating csgo-matchmaker.service..."
    cat > /etc/systemd/system/csgo-matchmaker.service << MATCHMAKER_UNIT
[Unit]
Description=CS:GO Matchmaking System - Matchmaker
After=network.target mysql.service mariadb.service docker.service
Wants=mysql.service mariadb.service docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${MATCHMAKER_VENV}/bin/python matchmaker/matchmaker.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
EnvironmentFile=${CONFIG_FILE}
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
MATCHMAKER_UNIT
    ok "csgo-matchmaker.service created"
}

_write_webpanel_service() {
    info "Generating csgo-webpanel.service..."
    cat > /etc/systemd/system/csgo-webpanel.service << WEBPANEL_UNIT
[Unit]
Description=CS:GO Matchmaking System - Web Panel
After=network.target mysql.service mariadb.service
Wants=mysql.service mariadb.service

[Service]
Type=simple
User=root
WorkingDirectory=${SCRIPT_DIR}/web-panel
ExecStart=${WEBPANEL_VENV}/bin/gunicorn \\
    --bind 0.0.0.0:${WEB_PORT} \\
    --workers 2 \\
    --timeout 120 \\
    --access-logfile - \\
    --error-logfile - \\
    --chdir ${SCRIPT_DIR}/web-panel \\
    app:create_app()
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
EnvironmentFile=${CONFIG_FILE}

[Install]
WantedBy=multi-user.target
WEBPANEL_UNIT
    ok "csgo-webpanel.service created"
}

# ── macOS launchd (dev only) ───────────────────────────────────────────────────

_generate_macos_launchd() {
    info "Generating macOS launchd plist for matchmaker (dev mode)..."
    local plist_dir="${HOME}/Library/LaunchAgents"
    mkdir -p "${plist_dir}"
    cat > "${plist_dir}/com.csgo-matchmaking.matchmaker.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.csgo-matchmaking.matchmaker</string>
    <key>ProgramArguments</key>
    <array>
        <string>${MATCHMAKER_VENV}/bin/python</string>
        <string>${SCRIPT_DIR}/matchmaker/matchmaker.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/matchmaker.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/matchmaker-error.log</string>
</dict>
</plist>
PLIST_EOF
    ok "launchd plist written to ${plist_dir}"
    info "To start: launchctl load ${plist_dir}/com.csgo-matchmaking.matchmaker.plist"
}

# ── Post-install validation ────────────────────────────────────────────────────

validate_installation() {
    print_section "Validating Installation"
    local errors=0 warnings=0

    _validate_mysql_connection    || (( errors++ ))
    _validate_db_tables           || (( warnings++ ))
    _validate_gslt_tokens         || (( warnings++ ))
    _validate_docker_daemon       || (( errors++ ))
    _validate_docker_image        || (( warnings++ ))
    _validate_python_matchmaker   || (( warnings++ ))
    _validate_python_webpanel     || (( warnings++ ))
    _validate_ports               || (( warnings++ ))
    _validate_config_permissions
    _validate_csgo_files          || (( warnings++ ))
    _run_health_check_script      || (( warnings++ ))

    printf '\n'
    if   (( errors == 0 && warnings == 0 )); then ok "All validation checks passed!"
    elif (( errors == 0 ));                  then warn "${warnings} warning(s) found — installation is functional."
    else                                          error "${errors} error(s) and ${warnings} warning(s). See above."
    fi

    return "${errors}"
}

_validate_mysql_connection() {
    info "Checking MySQL connection..."
    if mysql -h "${DB_HOST}" -P "${DB_PORT}" -u csgo_mm -p"${DB_PASS}" \
            csgo_matchmaking -e 'SELECT 1' &>/dev/null; then
        ok "MySQL connection: OK"; return 0
    else
        error "MySQL connection failed (user: csgo_mm)"; return 1
    fi
}

_validate_db_tables() {
    info "Checking database tables..."
    local table_count
    table_count="$(mysql -h "${DB_HOST}" -P "${DB_PORT}" -u csgo_mm -p"${DB_PASS}" \
        csgo_matchmaking -se 'SHOW TABLES' 2>/dev/null | wc -l | tr -d ' ')"
    if (( table_count > 0 )); then
        ok "Database tables: ${table_count} found"; return 0
    else
        warn "No tables found in database (schema may not have been applied)"; return 1
    fi
}

_validate_gslt_tokens() {
    info "Checking GSLT tokens in database..."
    local token_count
    token_count="$(mysql -h "${DB_HOST}" -P "${DB_PORT}" -u csgo_mm -p"${DB_PASS}" \
        csgo_matchmaking -se 'SELECT COUNT(*) FROM mm_gslt_tokens' 2>/dev/null || echo "0")"
    if (( token_count > 0 )); then
        ok "GSLT tokens in DB: ${token_count}"; return 0
    else
        warn "No GSLT tokens found in database"; return 1
    fi
}

_validate_docker_daemon() {
    info "Checking Docker daemon..."
    if docker info &>/dev/null; then
        ok "Docker daemon: running"; return 0
    else
        error "Docker daemon is not running"; return 1
    fi
}

_validate_docker_image() {
    info "Checking Docker image..."
    if docker images csgo-match-server:latest --format '{{.ID}}' 2>/dev/null | grep -q .; then
        ok "Docker image csgo-match-server:latest: exists"; return 0
    else
        warn "Docker image csgo-match-server:latest not found (build may have been skipped)"; return 1
    fi
}

_validate_python_matchmaker() {
    info "Checking matchmaker Python dependencies..."
    if [[ -d "${MATCHMAKER_VENV}" ]] \
            && "${MATCHMAKER_VENV}/bin/python" -c "import docker, mysql.connector" 2>/dev/null; then
        ok "Matchmaker Python imports: OK"; return 0
    else
        warn "Matchmaker Python imports failed or venv not found"; return 1
    fi
}

_validate_python_webpanel() {
    info "Checking web panel Python dependencies..."
    if [[ -d "${WEBPANEL_VENV}" ]] \
            && "${WEBPANEL_VENV}/bin/python" -c "import flask" 2>/dev/null; then
        ok "Flask import: OK"; return 0
    else
        warn "Flask import failed or web panel venv not found"; return 1
    fi
}

_validate_ports() {
    info "Checking for port conflicts..."
    local had_conflict=0
    for port in "${LOBBY_PORT}" "${WEB_PORT}"; do
        if check_port_free "${port}"; then
            ok "Port ${port}: available"
        else
            warn "Port ${port}: already in use (service may already be running)"
            had_conflict=1
        fi
    done
    return "${had_conflict}"
}

_validate_config_permissions() {
    [[ -f "${CONFIG_FILE}" ]] || return 0
    info "Checking config.env permissions..."
    local perms
    perms="$(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null \
           || stat -f '%OLp' "${CONFIG_FILE}" 2>/dev/null)"
    if [[ "${perms}" == "600" ]]; then
        ok "config.env permissions: 600 (secure)"
    else
        warn "config.env permissions: ${perms} — correcting to 600."
        chmod 600 "${CONFIG_FILE}"
    fi
}

_validate_csgo_files() {
    [[ "${OS_TYPE}" != "linux" ]] && return 0
    info "Checking CS:GO server files..."
    if [[ -f "${CSGO_DIR}/srcds_run" ]]; then
        ok "CS:GO server: srcds_run found"; return 0
    else
        warn "CS:GO server not found (download may have been skipped)"; return 1
    fi
}

_run_health_check_script() {
    local script="${SCRIPT_DIR}/scripts/health_check.sh"
    [[ -f "${script}" ]] || return 0
    info "Running scripts/health_check.sh..."
    chmod +x "${script}"
    bash "${script}" 2>/dev/null || { warn "health_check.sh reported issues"; return 1; }
}

# ── Final summary ──────────────────────────────────────────────────────────────

print_summary() {
    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))

    printf '\n%s' "${GREEN}"
    printf '╔══════════════════════════════════════════════════════════════════════╗\n'
    printf '║           CS:GO Matchmaking — Installation Complete!                ║\n'
    printf '╚══════════════════════════════════════════════════════════════════════╝\n'
    printf '%s\n' "${RESET}"

    # ── Installed components ────────────────────────────────────────────────────
    if [[ ${#INSTALLED_COMPONENTS[@]} -gt 0 ]]; then
        printf '%s  Installed components:%s\n' "${BOLD}" "${RESET}"
        for component in "${INSTALLED_COMPONENTS[@]}"; do
            printf '    %s✓%s %s\n' "${GREEN}" "${RESET}" "${component}"
        done
        printf '\n'
    fi

    # ── Access URLs ─────────────────────────────────────────────────────────────
    printf '%s=== Access URLs ===%s\n\n' "${BOLD}" "${RESET}"
    printf '  %sWeb panel (players):%s\n'   "${BOLD}" "${RESET}"
    printf '    http://%s:%s\n\n'           "${SERVER_IP}" "${WEB_PORT}"
    printf '  %sAdmin panel:%s\n'           "${BOLD}" "${RESET}"
    printf '    http://%s:%s/admin/\n\n'    "${SERVER_IP}" "${WEB_PORT}"
    printf '  %sLobby server (from CS:GO):%s\n' "${BOLD}" "${RESET}"
    printf '    connect %s:%s\n\n'          "${SERVER_IP}" "${LOBBY_PORT}"

    # ── Admin first login ───────────────────────────────────────────────────────
    printf '%s=== Admin Panel — First Login ===%s\n\n' "${BOLD}" "${RESET}"
    if [[ -n "${SUPER_ADMIN_STEAM_ID:-}" ]]; then
        printf '  %s✓ Super-admin Steam ID configured: %s%s%s\n\n' \
            "${GREEN}" "${BOLD}" "${SUPER_ADMIN_STEAM_ID}" "${RESET}"
        printf '  Steps to access the admin panel:\n'
        printf '    1. Open:  http://%s:%s\n' "${SERVER_IP}" "${WEB_PORT}"
        printf '    2. Click %s"Login through Steam"%s (top right corner)\n' "${BOLD}" "${RESET}"
        printf '    3. Sign in with Steam account matching: %s%s%s\n' "${BOLD}" "${SUPER_ADMIN_STEAM_ID}" "${RESET}"
        printf '    4. Click the %s"⚙ Admin"%s button that appears in the navbar\n\n' "${BOLD}" "${RESET}"
    else
        printf '  %s⚠  No super-admin Steam ID was configured!%s\n' "${YELLOW}" "${RESET}"
        printf '  The admin panel will be inaccessible until you set one.\n\n'
        printf '  Fix:\n'
        printf '    1. Find your Steam ID at: https://steamid.io\n'
        printf '    2. Edit: %s\n' "${CONFIG_FILE}"
        printf '       Set:  SUPER_ADMIN_STEAM_ID=STEAM_0:0:XXXXXXXX\n'
        printf '    3. sudo systemctl restart csgo-webpanel\n'
        printf '    4. Open http://%s:%s and click "Login through Steam"\n\n' "${SERVER_IP}" "${WEB_PORT}"
    fi

    # ── Service status ──────────────────────────────────────────────────────────
    printf '%s=== Service Status ===%s\n\n' "${BOLD}" "${RESET}"
    if [[ "${OS_TYPE}" == "linux" ]]; then
        for svc in csgo-webpanel csgo-matchmaker csgo-lobby; do
            local svc_status
            svc_status="$(systemctl is-active "${svc}" 2>/dev/null || echo 'inactive')"
            if [[ "${svc_status}" == "active" ]]; then
                printf '  %s●%s %-22s %srunning%s\n' "${GREEN}" "${RESET}" "${svc}" "${GREEN}" "${RESET}"
            else
                printf '  %s○%s %-22s %s%s%s\n' "${RED}" "${RESET}" "${svc}" "${YELLOW}" "${svc_status}" "${RESET}"
            fi
        done
        printf '\n'
        printf '  %sStart all:%s  sudo systemctl start csgo-lobby csgo-matchmaker csgo-webpanel\n' "${BOLD}" "${RESET}"
        printf '  %sStop all:%s   sudo systemctl stop  csgo-lobby csgo-matchmaker csgo-webpanel\n' "${BOLD}" "${RESET}"
        printf '  %sView logs:%s\n' "${BOLD}" "${RESET}"
        printf '    sudo journalctl -u csgo-webpanel   -f    # Web panel logs\n'
        printf '    sudo journalctl -u csgo-matchmaker -f    # Matchmaker logs\n'
        printf '    sudo journalctl -u csgo-lobby      -f    # Lobby server logs\n\n'
        if [[ ! -f "${CSGO_DIR}/srcds_run" ]]; then
            printf '  %s⚠ CS:GO server files not yet downloaded — csgo-lobby is not running.%s\n' "${YELLOW}" "${RESET}"
            printf '    To download CS:GO (~25 GB):\n'
            printf '      sudo -u steam steamcmd +login anonymous \\\n'
            printf '        +force_install_dir %s \\\n' "${CSGO_DIR}"
            printf '        +app_update 740 validate +quit\n'
            printf '    Then start the lobby: sudo systemctl start csgo-lobby\n\n'
        fi
    else
        printf '  %sStart matchmaker (macOS dev):%s\n' "${BOLD}" "${RESET}"
        printf '    source %s && %s/bin/python matchmaker/matchmaker.py\n\n' \
            "${CONFIG_FILE}" "${MATCHMAKER_VENV}"
    fi

    # ── Network summary ─────────────────────────────────────────────────────────
    printf '%s=== Network ===%s\n\n' "${BOLD}" "${RESET}"
    printf '  %-30s %s\n' "Lobby server port:"    "${LOBBY_PORT} (UDP+TCP)"
    printf '  %-30s %s\n' "Web panel port:"       "${WEB_PORT} (TCP)"
    printf '  %-30s %s-%s (%s slots)\n' "Match server ports:" \
        "${MATCH_PORT_START}" "${match_port_end}" "${MATCH_SLOTS}"
    printf '\n'

    # ── In-game commands ────────────────────────────────────────────────────────
    printf '%s=== In-Game Commands ===%s\n\n' "${BOLD}" "${RESET}"
    printf '  !queue      — Join matchmaking queue\n'
    printf '  !leave      — Leave queue\n'
    printf '  !status     — View queue position & estimated wait\n'
    printf '  !rank       — Show your ELO rating and rank\n'
    printf '  !top        — View top 5 players on the leaderboard\n'
    printf '  !lastmatch  — Show stats from your last match\n'
    printf '  !ff         — Start a surrender vote (in-match)\n'
    printf '  !pause      — Request a tactical timeout (in-match)\n'
    printf '  !report     — Report a player (in-match)\n\n'

    # ── System management ───────────────────────────────────────────────────────
    printf '%s=== System Management ===%s\n\n' "${BOLD}" "${RESET}"
    printf '  %-42s %s\n' "Health check:"     "./scripts/health_check.sh"
    printf '  %-42s %s\n' "Database backup:"  "./scripts/backup.sh"
    printf '  %-42s %s\n' "Update install:"   "sudo ./install.sh --update"
    printf '  %-42s %s\n' "Configuration:"    "${CONFIG_FILE}"
    printf '  %-42s %s\n' "Install log:"      "${LOG_FILE}"
    printf '\n'

    printf '%s  To re-run the setup wizard at any time: sudo ./install.sh%s\n\n' "${DIM}" "${RESET}"
}
