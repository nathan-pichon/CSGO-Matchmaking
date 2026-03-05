#!/usr/bin/env bash
# ==============================================================================
# installer/steps/05_csgo.sh — CS:GO dedicated server download
# ==============================================================================
# Downloads CS:GO Legacy (app 740) via SteamCMD into CSGO_DIR.
# Skipped on macOS and when --update is used without forced re-download.
# ==============================================================================

download_csgo() {
    print_section "CS:GO Dedicated Server Download"

    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "CS:GO server download skipped on macOS (dev mode)."
        return 0
    fi

    local steamcmd_bin
    steamcmd_bin="$(_find_steamcmd)" \
        || die "SteamCMD not found. Package installation may have failed."

    if _csgo_already_installed; then
        if [[ "${MODE}" == "update" ]]; then
            info "Update mode: validating and updating CS:GO server files."
        elif ! confirm "Re-download/validate CS:GO server files? (This will take a long time!)"; then
            ok "CS:GO server download skipped (already installed)"
            return 0
        fi
    fi

    mkdir -p "${CSGO_DIR}"
    chown "${STEAM_USER}:${STEAM_USER}" "${CSGO_DIR}"

    warn "CS:GO server is approximately 25 GB. This download will take a long time."
    warn "Do NOT interrupt — SteamCMD will resume if re-run."
    info "Installing to: ${CSGO_DIR}"

    _run_steamcmd_download "${steamcmd_bin}"

    [[ -f "${CSGO_DIR}/srcds_run" ]] \
        || die "CS:GO server installation could not be verified: srcds_run not found."
    ok "CS:GO server verified at ${CSGO_DIR}"
    INSTALLED_COMPONENTS+=("csgo-server")
}

# ── Private helpers ────────────────────────────────────────────────────────────

_find_steamcmd() {
    for path in "$(command -v steamcmd 2>/dev/null)" \
                "/usr/games/steamcmd" \
                "/opt/steamcmd/steamcmd.sh"; do
        [[ -f "${path}" ]] && { echo "${path}"; return 0; }
    done
    return 1
}

_csgo_already_installed() {
    [[ -f "${CSGO_DIR}/srcds_run" && -d "${CSGO_DIR}/csgo" ]]
}

_run_steamcmd_download() {
    local steamcmd_bin="$1"
    local max_attempts=3

    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        info "SteamCMD download attempt ${attempt}/${max_attempts}..."
        if sudo -u "${STEAM_USER}" "${steamcmd_bin}" \
                +login anonymous \
                +force_install_dir "${CSGO_DIR}" \
                +app_update 740 validate \
                +quit; then
            ok "CS:GO server download complete"
            return 0
        fi
        warn "SteamCMD returned a non-zero exit code (attempt ${attempt})"
        (( attempt < max_attempts )) \
            && { warn "SteamCMD can be flaky. Retrying in 10 seconds..."; sleep 10; }
    done

    die "CS:GO server download failed after ${max_attempts} attempts."
}
