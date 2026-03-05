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
#   sudo ./install.sh           Normal installation
#   sudo ./install.sh --update  Update an existing installation
#   sudo ./install.sh --check   Run system checks only (no changes)
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

    install_packages
    configure_wizard
    generate_config
    setup_database
    download_csgo
    install_sourcemod
    install_lobby_plugins
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
