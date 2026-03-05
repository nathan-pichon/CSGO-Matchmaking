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

    ok "All systemd services configured and enabled"
    INSTALLED_COMPONENTS+=("systemd-services")
    ROLLBACK_ACTIONS+=("systemctl disable csgo-lobby csgo-matchmaker csgo-webpanel 2>/dev/null; \
        rm -f /etc/systemd/system/csgo-lobby.service \
              /etc/systemd/system/csgo-matchmaker.service \
              /etc/systemd/system/csgo-webpanel.service; \
        systemctl daemon-reload")
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
    -maxplayers_override 32 \\
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
    printf '║                  Installation Complete!                             ║\n'
    printf '╚══════════════════════════════════════════════════════════════════════╝\n'
    printf '%s\n\n' "${RESET}"
    printf '  Your CS:GO Matchmaking system is ready!\n\n'
    printf '%s=== Quick Reference ===%s\n\n' "${BOLD}" "${RESET}"

    if [[ "${OS_TYPE}" == "linux" ]]; then
        printf '  %sStart services:%s\n'  "${BOLD}" "${RESET}"
        printf '    sudo systemctl start csgo-lobby csgo-matchmaker csgo-webpanel\n\n'
        printf '  %sStop services:%s\n'   "${BOLD}" "${RESET}"
        printf '    sudo systemctl stop csgo-lobby csgo-matchmaker csgo-webpanel\n\n'
        printf '  %sView logs:%s\n'       "${BOLD}" "${RESET}"
        printf '    sudo journalctl -u csgo-matchmaker -f\n'
        printf '    sudo journalctl -u csgo-lobby -f\n'
        printf '    sudo journalctl -u csgo-webpanel -f\n\n'
    else
        printf '  %sStart matchmaker (macOS dev):%s\n' "${BOLD}" "${RESET}"
        printf '    source %s\n' "${CONFIG_FILE}"
        printf '    %s/bin/python matchmaker/matchmaker.py\n\n' "${MATCHMAKER_VENV}"
    fi

    printf '  %sConnect to lobby (from CS:GO):%s\n' "${BOLD}" "${RESET}"
    printf '    connect %s:%s\n\n' "${SERVER_IP}" "${LOBBY_PORT}"
    printf '  %sWeb panel:%s\n' "${BOLD}" "${RESET}"
    printf '    http://%s:%s\n\n' "${SERVER_IP}" "${WEB_PORT}"
    printf '  %sMatch server ports:%s\n' "${BOLD}" "${RESET}"
    printf '    %s–%s (%s slots)\n\n' "${MATCH_PORT_START}" "${match_port_end}" "${MATCH_SLOTS}"
    printf '  %sIn-game commands:%s\n' "${BOLD}" "${RESET}"
    printf '    !queue  — Join matchmaking queue\n'
    printf '    !leave  — Leave queue\n'
    printf '    !rank   — Show your ELO rank\n'
    printf '    !top    — View leaderboard\n\n'
    printf '  %sSystem management:%s\n' "${BOLD}" "${RESET}"
    printf '    ./scripts/health_check.sh    — Check system health\n'
    printf '    ./scripts/backup.sh          — Backup database\n'
    printf '    sudo ./install.sh --update   — Update installation\n\n'
    printf '  %sImportant files:%s\n' "${BOLD}" "${RESET}"
    printf '    Config:  %s\n' "${CONFIG_FILE}"
    printf '    Log:     %s\n' "${LOG_FILE}"
    printf '    CS:GO:   %s\n' "${CSGO_DIR}"
    printf '\n'

    if [[ ${#INSTALLED_COMPONENTS[@]} -gt 0 ]]; then
        printf '  %sInstalled components:%s\n' "${BOLD}" "${RESET}"
        for component in "${INSTALLED_COMPONENTS[@]}"; do
            printf '    %s✓%s %s\n' "${GREEN}" "${RESET}" "${component}"
        done
        printf '\n'
    fi

    printf '%s  To re-run this wizard:  sudo ./install.sh%s\n\n' "${DIM}" "${RESET}"
}
