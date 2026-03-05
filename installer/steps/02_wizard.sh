#!/usr/bin/env bash
# ==============================================================================
# installer/steps/02_wizard.sh — Interactive configuration wizard
# ==============================================================================
# Populates all configuration variables through a guided 9-step interview.
# In --update mode it pre-fills every field from the existing config.env.
# ==============================================================================

configure_wizard() {
    print_section "Configuration Wizard"
    info "Press Enter to accept the default value shown in [brackets]."
    printf '\n'

    _wizard_load_existing_config
    _wizard_step_server_ip
    _wizard_step_database
    _wizard_step_rcon
    _wizard_step_match_gslts
    _wizard_step_lobby_gslt
    _wizard_step_ports
    _wizard_step_webpanel
    _wizard_step_maps
    _wizard_step_matchmaking_settings
    _wizard_print_summary
}

# ── Step helpers ───────────────────────────────────────────────────────────────

_wizard_load_existing_config() {
    [[ "${MODE}" != "update" || ! -f "${CONFIG_FILE}" ]] && return 0

    info "Loading existing configuration as defaults..."
    set -o allexport
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}" 2>/dev/null || true
    set +o allexport
    # Restore defaults for any missing keys
    DB_HOST="${DB_HOST:-localhost}"
    DB_PORT="${DB_PORT:-3306}"
    LOBBY_PORT="${LOBBY_PORT:-27015}"
    MATCH_PORT_START="${MATCH_PORT_START:-27020}"
    WEB_PORT="${WEB_PORT:-5000}"
    PLAYERS_PER_TEAM="${PLAYERS_PER_TEAM:-5}"
    MAX_ELO_SPREAD="${MAX_ELO_SPREAD:-200}"
    READY_CHECK_TIMEOUT="${READY_CHECK_TIMEOUT:-30}"
    ok "Existing configuration loaded"
}

_wizard_step_server_ip() {
    print_step "1" "Server IP Address"
    info "Detecting your public IP address..."
    local detected_ip
    detected_ip="$(with_retry curl -sf --max-time 5 https://api.ipify.org \
                   || with_retry curl -sf --max-time 5 https://ifconfig.me \
                   || echo "")"
    [[ -n "${detected_ip}" ]] && info "Detected public IP: ${detected_ip}" \
                               || warn "Could not auto-detect public IP."

    local ip_default="${SERVER_IP:-${detected_ip:-127.0.0.1}}"
    while true; do
        SERVER_IP="$(prompt "Enter server IP or hostname" "${ip_default}")"
        validate_ip "${SERVER_IP}" && { ok "Server IP: ${SERVER_IP}"; break; } \
            || error "Invalid IP/hostname: '${SERVER_IP}'. Please try again."
    done
}

_wizard_step_database() {
    print_step "2" "MySQL / Database Setup"
    if confirm "Use an existing MySQL instance (remote or pre-configured)?"; then
        USE_EXISTING_MYSQL="y"
        DB_HOST="$(prompt "MySQL host" "${DB_HOST:-localhost}")"
        while true; do
            DB_PORT="$(prompt "MySQL port" "${DB_PORT:-3306}")"
            validate_port "${DB_PORT}" && break || error "Invalid port number."
        done
        DB_ROOT_PASS="$(prompt_secret "MySQL root password (for creating DB/user)")"
    else
        USE_EXISTING_MYSQL="n"
        [[ -z "${DB_ROOT_PASS:-}" ]] \
            && DB_ROOT_PASS="$(generate_password 20)" \
            && info "Generated MySQL root password"
        DB_HOST="localhost"
        DB_PORT="3306"
    fi

    if [[ -z "${DB_PASS:-}" ]]; then
        DB_PASS="$(generate_password 24)"
        ok "Generated database password (saved to config.env)"
    else
        local custom_db_pass
        custom_db_pass="$(prompt "Database password for csgo_mm (leave empty to keep current)" "${DB_PASS}")"
        [[ -n "${custom_db_pass}" ]] && DB_PASS="${custom_db_pass}"
    fi
    ok "Database: csgo_matchmaking  User: csgo_mm @ ${DB_HOST}:${DB_PORT}"
}

_wizard_step_rcon() {
    print_step "3" "RCON Password"
    [[ -z "${RCON_PASSWORD:-}" ]] \
        && RCON_PASSWORD="$(generate_hex_password 16)" \
        && info "Auto-generated RCON password."
    local custom_rcon
    custom_rcon="$(prompt "RCON password (leave empty to use generated)" "${RCON_PASSWORD}")"
    RCON_PASSWORD="${custom_rcon:-${RCON_PASSWORD}}"
    ok "RCON password configured"
}

_wizard_step_match_gslts() {
    print_step "4" "Game Server Login Tokens (GSLT) — Match Servers"
    printf '\n'
    printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${YELLOW}" "${RESET}"
    printf '  %s GSLT Setup Instructions%s\n' "${BOLD}" "${RESET}"
    printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "${YELLOW}" "${RESET}"
    printf '  Game Server Login Tokens (GSLT) are required for each match server.\n\n'
    printf '  1. Go to: %shttps://steamcommunity.com/dev/managegameservers%s\n' "${CYAN}" "${RESET}"
    printf '  2. Create tokens with App ID: %s730%s (CS:GO Legacy)\n' "${BOLD}" "${RESET}"
    printf '  3. Recommend 10 tokens for up to 10 simultaneous matches.\n'
    printf '  4. Each token = 1 match server slot. Tokens are free (max 1000/account).\n\n'
    printf '  %sNote: Tokens expire after 1 year of disuse.%s\n\n' "${DIM}" "${RESET}"

    local num_tokens=0
    while (( num_tokens < 1 || num_tokens > 1000 )); do
        local token_input
        token_input="$(prompt "How many GSLT tokens will you add?" "10")"
        [[ "${token_input}" =~ ^[0-9]+$ ]] && (( token_input >= 1 && token_input <= 1000 )) \
            && num_tokens="${token_input}" \
            || error "Enter a number between 1 and 1000."
    done

    MATCH_GSLTS=()
    local i
    for (( i=1; i<=num_tokens; i++ )); do
        while true; do
            local token
            token="$(prompt "Paste GSLT token ${i} of ${num_tokens}")"
            token="${token^^}"
            if [[ -z "${token}" ]]; then
                warn "Skipping token ${i} (empty)."; break
            elif validate_gslt "${token}"; then
                MATCH_GSLTS+=("${token}"); ok "Token ${i} accepted."; break
            else
                error "Invalid GSLT format (expected 20–40 uppercase alphanumeric chars)."
                confirm "Skip this token?" && { warn "Token ${i} skipped."; break; }
            fi
        done
    done

    [[ ${#MATCH_GSLTS[@]} -gt 0 ]] \
        || die "At least one GSLT token is required."
    ok "${#MATCH_GSLTS[@]} GSLT token(s) configured for match servers"
}

_wizard_step_lobby_gslt() {
    print_step "5" "Lobby Server GSLT"
    info "The lobby server requires its own dedicated GSLT token."
    while true; do
        local lobby_token
        lobby_token="$(prompt "Paste GSLT token for the lobby server")"
        lobby_token="${lobby_token^^}"
        if validate_gslt "${lobby_token}"; then
            LOBBY_GSLT="${lobby_token}"
            ok "Lobby server GSLT configured"; break
        else
            error "Invalid GSLT token format."
            confirm "Skip lobby GSLT (server will run without VAC)?" && {
                warn "No GSLT for lobby server — server will not be VAC-secured."
                LOBBY_GSLT=""; break
            }
        fi
    done
}

_wizard_step_ports() {
    print_step "6" "Port Configuration"

    # Lobby port
    while true; do
        local lport
        lport="$(prompt "Lobby server port" "${LOBBY_PORT}")"
        validate_port "${lport}" || { error "Invalid port number."; continue; }
        check_port_free "${lport}" || {
            warn "Port ${lport} appears to be in use."
            confirm "Use it anyway?" || continue
        }
        LOBBY_PORT="${lport}"
        ok "Lobby port: ${LOBBY_PORT}"; break
    done

    # Match server port range start
    while true; do
        local mstart
        mstart="$(prompt "Match server port range start" "${MATCH_PORT_START}")"
        validate_port "${mstart}" && { MATCH_PORT_START="${mstart}"; break; } \
            || error "Invalid port number."
    done

    # Number of match slots
    while true; do
        local mslots
        mslots="$(prompt "Number of match server slots" "${MATCH_SLOTS}")"
        [[ "${mslots}" =~ ^[0-9]+$ ]] && (( mslots >= 1 && mslots <= 50 )) \
            && { MATCH_SLOTS="${mslots}"; break; } \
            || error "Enter a number between 1 and 50."
    done

    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))
    ok "Match server ports: ${MATCH_PORT_START}–${match_port_end}"

    # Warn about busy ports in the range
    local port_busy=0
    for (( i=0; i<MATCH_SLOTS; i++ )); do
        check_port_free "$(( MATCH_PORT_START + i ))" || (( port_busy++ ))
    done
    (( port_busy == 0 )) \
        || warn "${port_busy} match server port(s) are in use. Proceeding anyway."
}

_wizard_step_webpanel() {
    print_step "7" "Web Panel"

    # Port
    while true; do
        local wport
        wport="$(prompt "Web panel port" "${WEB_PORT}")"
        validate_port "${wport}" || { error "Invalid port number."; continue; }
        check_port_free "${wport}" || {
            warn "Port ${wport} appears to be in use."
            confirm "Use it anyway?" || continue
        }
        WEB_PORT="${wport}"; ok "Web panel port: ${WEB_PORT}"; break
    done

    FLASK_SECRET_KEY="$(generate_password 48)"

    # Discord webhook
    if confirm "Enable Discord notifications?"; then
        while true; do
            local webhook
            webhook="$(prompt "Paste Discord webhook URL")"
            if [[ "${webhook}" =~ ^https://discord\.com/api/webhooks/ ]]; then
                DISCORD_WEBHOOK_URL="${webhook}"; ok "Discord webhook configured"; break
            else
                error "Invalid URL. Must start with: https://discord.com/api/webhooks/"
                confirm "Skip Discord integration?" && { DISCORD_WEBHOOK_URL=""; break; }
            fi
        done
    else
        DISCORD_WEBHOOK_URL=""; ok "Discord notifications disabled"
    fi
}

_wizard_step_maps() {
    print_step "8" "Map Pool Selection"
    SELECTED_MAPS=("${ALL_MAPS[@]}")
    local map_selected=()
    for (( i=0; i<${#ALL_MAPS[@]}; i++ )); do map_selected[$i]=1; done

    while true; do
        printf '\n  Current map pool:\n'
        for (( i=0; i<${#ALL_MAPS[@]}; i++ )); do
            local check_mark
            [[ "${map_selected[$i]}" -eq 1 ]] \
                && check_mark="${GREEN}[✓]${RESET}" \
                || check_mark="${DIM}[ ]${RESET}"
            printf '    %s%d. %s %s%s\n' "${BOLD}" "$(( i+1 ))" "${check_mark}" "${ALL_MAPS[$i]}" "${RESET}"
        done
        printf '\n'
        local map_toggle
        map_toggle="$(prompt "Toggle map numbers (comma-separated), or Enter to keep")"
        [[ -z "${map_toggle}" ]] && break

        IFS=', ' read -ra toggle_nums <<< "${map_toggle}"
        for num in "${toggle_nums[@]}"; do
            if [[ "${num}" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#ALL_MAPS[@]} )); then
                local idx=$(( num - 1 ))
                (( map_selected[$idx] = map_selected[$idx] == 1 ? 0 : 1 ))
            else
                warn "Invalid map number: ${num}"
            fi
        done
    done

    SELECTED_MAPS=()
    for (( i=0; i<${#ALL_MAPS[@]}; i++ )); do
        [[ "${map_selected[$i]}" -eq 1 ]] && SELECTED_MAPS+=("${ALL_MAPS[$i]}")
    done

    if [[ ${#SELECTED_MAPS[@]} -eq 0 ]]; then
        warn "No maps selected — defaulting to de_dust2."
        SELECTED_MAPS=("de_dust2")
    fi
    ok "Map pool: ${SELECTED_MAPS[*]}"
}

_wizard_step_matchmaking_settings() {
    print_step "9" "Matchmaking Settings"

    while true; do
        local ppt
        ppt="$(prompt "Players per team" "${PLAYERS_PER_TEAM}")"
        [[ "${ppt}" =~ ^[0-9]+$ ]] && (( ppt >= 1 && ppt <= 10 )) \
            && { PLAYERS_PER_TEAM="${ppt}"; break; } \
            || error "Enter a number between 1 and 10."
    done

    while true; do
        local elo
        elo="$(prompt "Max ELO spread (initial)" "${MAX_ELO_SPREAD}")"
        [[ "${elo}" =~ ^[0-9]+$ ]] && (( elo > 0 )) \
            && { MAX_ELO_SPREAD="${elo}"; break; } \
            || error "Enter a positive number."
    done

    while true; do
        local rct
        rct="$(prompt "Ready check timeout (seconds)" "${READY_CHECK_TIMEOUT}")"
        [[ "${rct}" =~ ^[0-9]+$ ]] && (( rct >= 10 && rct <= 300 )) \
            && { READY_CHECK_TIMEOUT="${rct}"; break; } \
            || error "Enter a number between 10 and 300."
    done

    ok "Players per team: ${PLAYERS_PER_TEAM}  Max ELO: ${MAX_ELO_SPREAD}  Ready timeout: ${READY_CHECK_TIMEOUT}s"
}

_wizard_print_summary() {
    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))
    print_section "Configuration Summary"
    printf '  %-35s %s\n' "Server IP:"          "${SERVER_IP}"
    printf '  %-35s %s\n' "Lobby Port:"         "${LOBBY_PORT}"
    printf '  %-35s %s-%s (%s slots)\n' "Match Server Ports:" \
        "${MATCH_PORT_START}" "${match_port_end}" "${MATCH_SLOTS}"
    printf '  %-35s %s\n' "Web Panel Port:"     "${WEB_PORT}"
    printf '  %-35s %s\n' "Database Host:"      "${DB_HOST}:${DB_PORT}"
    printf '  %-35s %s\n' "Database Name:"      "csgo_matchmaking"
    printf '  %-35s %s\n' "Database User:"      "csgo_mm"
    printf '  %-35s %s\n' "Match GSLT Tokens:"  "${#MATCH_GSLTS[@]} configured"
    printf '  %-35s %s\n' "Lobby GSLT:"         "${LOBBY_GSLT:0:8}... (truncated)"
    printf '  %-35s %s\n' "Map Pool:"           "${SELECTED_MAPS[*]}"
    printf '  %-35s %s\n' "Players Per Team:"   "${PLAYERS_PER_TEAM}"
    printf '  %-35s %s\n' "Max ELO Spread:"     "${MAX_ELO_SPREAD}"
    printf '  %-35s %s\n' "Ready Timeout:"      "${READY_CHECK_TIMEOUT}s"
    printf '  %-35s %s\n' "Discord Webhook:"    "${DISCORD_WEBHOOK_URL:-(disabled)}"
    printf '\n'

    confirm "Proceed with installation?" \
        || { info "Installation cancelled by user."; exit 0; }
}
