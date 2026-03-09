#!/usr/bin/env bash
# ==============================================================================
# CS:GO Matchmaking System — Installation Wizard
# ==============================================================================
# Version:  1.0.0
# License:  MIT
#
# DISCLAIMER: This installer configures a CS:GO dedicated server and
# matchmaking backend. You are responsible for complying with Valve's Steam
# Subscriber Agreement and Game Server policies. You must obtain valid Game
# Server Login Tokens (GSLTs) from your Steam account before running this
# installer. This software is provided as-is with no warranty.
#
# Usage:
#   sudo ./install.sh             Normal installation
#   sudo ./install.sh --update    Update an existing installation
#   sudo ./install.sh --check     Run system checks only (no changes)
#   sudo ./install.sh --dry-run   Run wizard + show plan, make no system changes
# ==============================================================================

set -euo pipefail

# Resolve the project root regardless of the working directory.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load shared state and library modules ──────────────────────────────────────
# shellcheck source=installer/globals.sh
source "${SCRIPT_DIR}/installer/globals.sh"
# shellcheck source=installer/lib/log.sh
source "${SCRIPT_DIR}/installer/lib/log.sh"
# shellcheck source=installer/lib/ui.sh
source "${SCRIPT_DIR}/installer/lib/ui.sh"
# shellcheck source=installer/lib/input.sh
source "${SCRIPT_DIR}/installer/lib/input.sh"
# shellcheck source=installer/lib/system.sh
source "${SCRIPT_DIR}/installer/lib/system.sh"

# ── Load installation steps ────────────────────────────────────────────────────
# shellcheck source=installer/steps/01_packages.sh
source "${SCRIPT_DIR}/installer/steps/01_packages.sh"
# shellcheck source=installer/steps/02_wizard.sh
source "${SCRIPT_DIR}/installer/steps/02_wizard.sh"
# shellcheck source=installer/steps/03_config.sh
source "${SCRIPT_DIR}/installer/steps/03_config.sh"
# shellcheck source=installer/steps/04_database.sh
source "${SCRIPT_DIR}/installer/steps/04_database.sh"
# shellcheck source=installer/steps/05_csgo.sh
source "${SCRIPT_DIR}/installer/steps/05_csgo.sh"
# shellcheck source=installer/steps/06_sourcemod.sh
source "${SCRIPT_DIR}/installer/steps/06_sourcemod.sh"
# shellcheck source=installer/steps/07_docker.sh
source "${SCRIPT_DIR}/installer/steps/07_docker.sh"
# shellcheck source=installer/steps/08_python.sh
source "${SCRIPT_DIR}/installer/steps/08_python.sh"
# shellcheck source=installer/steps/09_services.sh
source "${SCRIPT_DIR}/installer/steps/09_services.sh"

# ==============================================================================
# DRY-RUN PLAN
# ==============================================================================
_print_dry_run_plan() {
    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))

    printf '\n%s╔══ DRY RUN PLAN ══════════════════════════════════════════════════════╗%s\n' "${CYAN}${BOLD}" "${RESET}"
    printf '%s  config.env has been written — review it at:%s\n'   "${DIM}" "${RESET}"
    printf '    %s\n\n' "${CONFIG_FILE}"
    printf '%s  The following steps would run on a real install:%s\n\n' "${BOLD}" "${RESET}"

    local step=1
    printf '  %s%d.%s Install system packages\n' "${BOLD}" "$(( step++ ))" "${RESET}"
    case "${DB_BACKEND}" in
        local)    printf '       MySQL/MariaDB server + client (via %s)\n' "${PKG_MANAGER}" ;;
        docker)   printf '       mysql-client CLI only — server runs in Docker\n' ;;
        external) printf '       mysql-client CLI only — connecting to %s:%s\n' "${DB_HOST}" "${DB_PORT}" ;;
    esac
    printf '       Python 3, Docker, SourceMod build tools\n\n'

    printf '  %s%d.%s Set up MySQL database\n' "${BOLD}" "$(( step++ ))" "${RESET}"
    case "${DB_BACKEND}" in
        local)    printf '       Start local MySQL service, create database + user\n' ;;
        docker)   printf '       docker run mariadb:10.11 --name %s -p %s:3306\n' "${MYSQL_DOCKER_CONTAINER}" "${DB_PORT}" ;;
        external) printf '       Connect to %s:%s, create database + user\n' "${DB_HOST}" "${DB_PORT}" ;;
    esac
    printf '       Apply schema.sql, seed map pool and port pool\n\n'

    if [[ "${OS_TYPE}" != "macos" ]]; then
        printf '  %s%d.%s Download CS:GO dedicated server (~25 GB via SteamCMD)\n\n' "${BOLD}" "$(( step++ ))" "${RESET}"
    fi

    printf '  %s%d.%s Install SourceMod + MetaMod, compile and deploy plugins\n' "${BOLD}" "$(( step++ ))" "${RESET}"
    printf '       Lobby:  csgo_mm_queue / party / notify / admin\n'
    printf '       Match:  csgo_mm_match\n\n'

    printf '  %s%d.%s Build Docker match-server image\n' "${BOLD}" "$(( step++ ))" "${RESET}"
    printf '       FROM cm2network/csgo:sourcemod → csgo-match-server:latest\n\n'

    printf '  %s%d.%s Set up Python virtualenvs (matchmaker + web panel)\n\n' "${BOLD}" "$(( step++ ))" "${RESET}"

    printf '  %s%d.%s Configure services\n' "${BOLD}" "$(( step++ ))" "${RESET}"
    if [[ "${OS_TYPE}" == "linux" ]]; then
        printf '       systemd: csgo-lobby, csgo-matchmaker, csgo-webpanel\n\n'
    else
        printf '       launchd plist for matchmaker (macOS dev)\n\n'
    fi

    printf '  %s%d.%s Open firewall ports\n' "${BOLD}" "$(( step++ ))" "${RESET}"
    printf '       Lobby: %s/udp+tcp  Web: %s/tcp  Match: %s-%s/udp+tcp\n\n' \
        "${LOBBY_PORT}" "${WEB_PORT}" "${MATCH_PORT_START}" "${match_port_end}"

    printf '%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "${CYAN}${BOLD}" "${RESET}"
    printf '\n  %sDry run complete. No system changes were made.%s\n' "${GREEN}${BOLD}" "${RESET}"
    printf '  Review %s, then re-run without --dry-run to install.\n\n' "${CONFIG_FILE}"
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    log_raw "===== CS:GO Matchmaking Installer v${INSTALLER_VERSION} started ====="
    log_raw "Arguments: $*"
    log_raw "Working directory: ${SCRIPT_DIR}"

    print_header
    check_prerequisites "$@"
    detect_os
    check_requirements

    if [[ "${MODE}" == "check" ]]; then
        ok "System check complete (--check mode, no installation performed)."
        exit 0
    fi

    ask_db_backend       # ask local/docker/external BEFORE packages so we install the right DB tools
    install_packages
    configure_wizard
    generate_config

    if [[ "${DRY_RUN}" == "true" ]]; then
        _print_dry_run_plan
        exit 0
    fi

    setup_database
    download_csgo
    install_sourcemod
    install_lobby_plugins
    install_match_server_plugins
    build_docker_image
    setup_matchmaker
    setup_webpanel
    generate_systemd_services

    local validation_errors=0
    validate_installation || validation_errors=$?

    print_summary

    if (( validation_errors > 0 )); then
        warn "Installation completed with ${validation_errors} validation error(s)."
        warn "Check ${LOG_FILE} for details."
        exit 1
    fi

    log_raw "===== Installation completed successfully ====="
    exit 0
}

main "$@"
