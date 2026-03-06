#!/usr/bin/env bash
# ==============================================================================
# installer/steps/06_sourcemod.sh — SourceMod, MetaMod and lobby plugin setup
# ==============================================================================
# Two public functions:
#   install_sourcemod      — MetaMod:Source + SourceMod + third-party plugins
#   install_lobby_plugins  — Copy/compile our .sp files + generate server configs
# ==============================================================================

install_sourcemod() {
    print_section "SourceMod & MetaMod Installation"

    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "SourceMod/MetaMod installation skipped on macOS (dev mode)."
        return 0
    fi

    local addons_dir="${CSGO_DIR}/csgo/addons"
    if [[ ! -d "${CSGO_DIR}/csgo" ]]; then
        warn "CS:GO server directory not found — run installer again after download."
        return 0
    fi
    mkdir -p "${addons_dir}"

    _install_metamod "${addons_dir}"
    _install_sourcemod_core "${addons_dir}"

    local sm_dir="${addons_dir}/sourcemod"
    _install_levels_ranks_plugin "${sm_dir}"
    _install_serverredirect_plugin "${sm_dir}"

    chown -R "${STEAM_USER}:${STEAM_USER}" "${addons_dir}" 2>/dev/null || true
    ok "SourceMod & plugins installation complete"
}

install_lobby_plugins() {
    print_section "Lobby Server Plugin Installation"

    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "Lobby plugin installation skipped on macOS (dev mode)."
        return 0
    fi

    if [[ ! -d "${CSGO_DIR}/csgo" ]]; then
        warn "CS:GO server not installed — skipping lobby plugin installation."
        return 0
    fi

    local sm_dir="${CSGO_DIR}/csgo/addons/sourcemod"
    local plugins_src="${SCRIPT_DIR}/lobby-server/sourcemod"

    if [[ ! -d "${sm_dir}" ]]; then
        warn "SourceMod not installed at ${sm_dir} — install SourceMod first."
        return 0
    fi

    mkdir -p "${sm_dir}/plugins" "${sm_dir}/scripting" "${sm_dir}/configs"

    _deploy_plugin_binaries "${sm_dir}" "${plugins_src}"
    _generate_databases_cfg "${sm_dir}"
    _deploy_server_cfg
    _generate_autoexec_cfg

    chown -R "${STEAM_USER}:${STEAM_USER}" "${CSGO_DIR}/csgo/cfg" 2>/dev/null || true
    ok "Lobby server plugins configured"
}

# ── install_sourcemod private helpers ──────────────────────────────────────────

# ── Checksum helper ────────────────────────────────────────────────────────────

_verify_sha256() {
    # Usage: _verify_sha256 <file> <expected_sha256>
    # Dies with an error message if the checksum does not match.
    local file="$1" expected="$2"
    local actual
    actual="$(sha256sum "${file}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        die "Checksum mismatch for ${file}:
  Expected: ${expected}
  Got:      ${actual}
File may be corrupted or tampered with. Aborting."
    fi
}

# ── MetaMod / SourceMod installers ─────────────────────────────────────────────

_install_metamod() {
    local addons_dir="$1"
    if [[ -d "${addons_dir}/metamod" ]]; then
        ok "MetaMod:Source already installed"; return
    fi
    info "Downloading MetaMod:Source 1.11.0-git1148..."
    local mm_url="https://mms.alliedmods.net/mmsdrop/1.11/mmsource-1.11.0-git1148-linux.tar.gz"
    local mm_file="/tmp/metamod_linux.tar.gz"
    with_retry curl -fsSL "${mm_url}" -o "${mm_file}" || true
    if [[ -f "${mm_file}" ]]; then
        _verify_sha256 "${mm_file}" "${MM_SHA256}"
        tar -xzf "${mm_file}" -C "${addons_dir}/"
        rm -f "${mm_file}"
        ok "MetaMod:Source installed (checksum verified)"
    else
        warn "MetaMod:Source download failed — install manually from https://www.sourcemm.net/"
    fi
}

_install_sourcemod_core() {
    local addons_dir="$1"
    if [[ -d "${addons_dir}/sourcemod" ]]; then
        ok "SourceMod already installed"; return
    fi
    info "Downloading SourceMod ${SM_VERSION}.0-git${SM_BUILD}..."
    local sm_url="https://sm.alliedmods.net/smdrop/${SM_VERSION}/sourcemod-${SM_VERSION}.0-git${SM_BUILD}-linux.tar.gz"
    local sm_file="/tmp/sourcemod_linux.tar.gz"

    if ! with_retry curl -fsSL "${sm_url}" -o "${sm_file}"; then
        # Pinned build unavailable — warn and fall back to latest stable.
        warn "SourceMod ${SM_VERSION}.0-git${SM_BUILD} not found on CDN."
        warn "Falling back to latest stable — checksum verification will be SKIPPED."
        local latest_url
        latest_url="$(with_retry curl -sfL "https://www.sourcemod.net/downloads.php?branch=stable" \
            | grep -oP 'https://sm\.alliedmods\.net/smdrop/[^"]+linux\.tar\.gz' | head -1 || echo "")"
        if [[ -n "${latest_url}" ]]; then
            warn "Downloading latest SourceMod from: ${latest_url}"
            with_retry curl -fsSL "${latest_url}" -o "${sm_file}"
        fi
    else
        # Pinned build: verify checksum before extraction.
        _verify_sha256 "${sm_file}" "${SM_SHA256}"
    fi

    if [[ -f "${sm_file}" ]]; then
        tar -xzf "${sm_file}" -C "${addons_dir}/"
        rm -f "${sm_file}"
        ok "SourceMod installed"
        INSTALLED_COMPONENTS+=("sourcemod")
    else
        warn "SourceMod download failed — install manually from https://www.sourcemod.net/"
    fi
}

_install_levels_ranks_plugin() {
    local sm_dir="$1"
    local vendor_smx="${SCRIPT_DIR}/vendor/sourcemod/plugins/levels_ranks.smx"
    local dst_smx="${sm_dir}/plugins/levelsranks.smx"

    # Vendor-first: copy pinned binary from repo if available.
    if [[ -f "${vendor_smx}" ]]; then
        _verify_sha256 "${vendor_smx}" "${LR_SHA256}"
        cp "${vendor_smx}" "${dst_smx}"
        ok "Levels Ranks v${LR_VERSION} installed from vendor/ (checksum verified)"
        return 0
    fi

    # Fallback: download latest release from GitHub.
    warn "vendor/sourcemod/plugins/levels_ranks.smx not found — downloading latest release."
    info "Downloading Levels Ranks plugin..."
    local api_url="https://api.github.com/repos/levelsranks/pawn-levels_ranks-core/releases/latest"
    local asset_url
    asset_url="$(with_retry curl -sfL "${api_url}" \
        | grep -oP '"browser_download_url":\s*"\K[^"]+\.zip' | head -1 || echo "")"

    if [[ -z "${asset_url}" ]]; then
        warn "Could not fetch Levels Ranks release — install manually from GitHub."
        return 0
    fi

    with_retry curl -fsSL "${asset_url}" -o /tmp/levels_ranks.zip
    if [[ -f /tmp/levels_ranks.zip ]]; then
        unzip -o -q /tmp/levels_ranks.zip -d /tmp/lr_extract/
        find /tmp/lr_extract/ -name '*.smx'          -exec cp {} "${sm_dir}/plugins/"      \; 2>/dev/null || true
        find /tmp/lr_extract/ -name '*.phrases.txt'  -exec cp {} "${sm_dir}/translations/" \; 2>/dev/null || true
        rm -rf /tmp/levels_ranks.zip /tmp/lr_extract/
        ok "Levels Ranks plugin installed (unverified — consider updating vendor/)"
    fi
}

_install_serverredirect_plugin() {
    local sm_dir="$1"
    local vendor_smx="${SCRIPT_DIR}/vendor/sourcemod/plugins/serverredirect.smx"
    local dst="${sm_dir}/plugins/serverredirect.smx"

    # Vendor-first: copy pinned binary from repo if available.
    if [[ -f "${vendor_smx}" ]]; then
        _verify_sha256 "${vendor_smx}" "${SR_SHA256}"
        cp "${vendor_smx}" "${dst}"
        ok "ServerRedirect v${SR_VERSION} installed from vendor/ (checksum verified)"
        return 0
    fi

    # Fallback: download latest release from GitHub.
    warn "vendor/sourcemod/plugins/serverredirect.smx not found — downloading latest release."
    info "Downloading ServerRedirect plugin..."
    local api_url="https://api.github.com/repos/GAMMACASE/ServerRedirect/releases/latest"
    local asset_url
    asset_url="$(with_retry curl -sfL "${api_url}" \
        | grep -oP '"browser_download_url":\s*"\K[^"]+\.smx' | head -1 || echo "")"

    if [[ -n "${asset_url}" ]]; then
        with_retry curl -fsSL "${asset_url}" -o "${dst}" \
            && ok "ServerRedirect plugin installed (unverified — consider updating vendor/)"
    else
        # Fallback to raw file in repository
        local raw="https://raw.githubusercontent.com/GAMMACASE/ServerRedirect/master/addons/sourcemod/plugins/serverredirect.smx"
        with_retry curl -fsSL "${raw}" -o "${dst}" 2>/dev/null \
            && ok "ServerRedirect plugin installed from GitHub raw (unverified)" \
            || warn "Could not download ServerRedirect — install manually."
    fi
}

# ── install_lobby_plugins private helpers ──────────────────────────────────────

_deploy_plugin_binaries() {
    local sm_dir="$1"
    local plugins_src="$2"
    local compiled=0 failed=0

    for sp_file in "${plugins_src}/scripting/"*.sp; do
        [[ -f "${sp_file}" ]] || continue
        local plugin_name
        plugin_name="$(basename "${sp_file}" .sp)"
        local smx_src="${plugins_src}/plugins/${plugin_name}.smx"
        local smx_dst="${sm_dir}/plugins/${plugin_name}.smx"

        if [[ -f "${smx_src}" ]]; then
            cp "${smx_src}" "${smx_dst}"
            ok "Copied pre-built plugin: ${plugin_name}.smx"
            (( compiled++ ))
        elif _spcomp_available "${sm_dir}"; then
            _compile_plugin "${sp_file}" "${smx_dst}" "${sm_dir}" "${plugins_src}" \
                && (( compiled++ )) || (( failed++ ))
        else
            warn "No .smx and no spcomp available for: ${plugin_name}.sp"
            (( failed++ ))
        fi
    done

    (( compiled > 0 )) && ok "${compiled} plugin(s) installed"
    (( failed  > 0 )) && warn "${failed} plugin(s) could not be installed — compile them manually."
}

_spcomp_available() {
    local sm_dir="$1"
    command -v spcomp &>/dev/null || [[ -f "${sm_dir}/scripting/spcomp" ]]
}

_compile_plugin() {
    local sp_file="$1" smx_dst="$2" sm_dir="$3" plugins_src="$4"
    local plugin_name; plugin_name="$(basename "${sp_file}" .sp)"
    local spcomp_bin
    spcomp_bin="$(command -v spcomp 2>/dev/null || echo "${sm_dir}/scripting/spcomp")"

    info "Compiling ${plugin_name}.sp..."
    if "${spcomp_bin}" "${sp_file}" -o "${smx_dst}" \
            -i "${sm_dir}/scripting/include" \
            -i "${plugins_src}/scripting/include"; then
        ok "Compiled: ${plugin_name}.smx"; return 0
    else
        warn "Failed to compile: ${plugin_name}.sp"; return 1
    fi
}

_generate_databases_cfg() {
    local sm_dir="$1"
    info "Generating SourceMod databases.cfg..."
    cat > "${sm_dir}/configs/databases.cfg" << DATABASES_CFG
"Databases"
{
    "default"
    {
        "driver"    "mysql"
        "host"      "${DB_HOST}"
        "database"  "csgo_matchmaking"
        "user"      "csgo_mm"
        "pass"      "${DB_PASS}"
        "port"      "${DB_PORT}"
    }

    "csgo_matchmaking"
    {
        "driver"    "mysql"
        "host"      "${DB_HOST}"
        "database"  "csgo_matchmaking"
        "user"      "csgo_mm"
        "pass"      "${DB_PASS}"
        "port"      "${DB_PORT}"
    }
}
DATABASES_CFG
    ok "databases.cfg written"
}

_deploy_server_cfg() {
    local cfg_dir="${CSGO_DIR}/csgo/cfg"
    mkdir -p "${cfg_dir}"
    local src="${SCRIPT_DIR}/lobby-server/cfg/server.cfg"
    if [[ -f "${src}" ]]; then
        cp "${src}" "${cfg_dir}/server.cfg"
        ok "server.cfg copied"
    else
        warn "lobby-server/cfg/server.cfg not found — generating minimal fallback."
        cat > "${cfg_dir}/server.cfg" << SERVER_CFG
// CS:GO Matchmaking Lobby Server Config — auto-generated by install.sh
hostname "CS:GO Matchmaking Lobby"
sv_password ""
rcon_password "${RCON_PASSWORD}"
mp_autoteambalance 0
mp_limitteams 0
sv_cheats 0
sv_lan 0
log on
sv_logfile 1
sv_log_onefile 1
SERVER_CFG
        ok "Minimal server.cfg generated"
    fi
}

_generate_autoexec_cfg() {
    local cfg_dir="${CSGO_DIR}/csgo/cfg"
    cat > "${cfg_dir}/autoexec.cfg" << AUTOEXEC_CFG
// CS:GO Matchmaking — auto-generated by install.sh
// Changes to this file may be overwritten when re-running the installer.

// Game Server Login Token (GSLT)
$(if [[ -n "${LOBBY_GSLT}" ]]; then echo "sv_setsteamaccount ${LOBBY_GSLT}"; fi)

// RCON password (must match RCON_PASSWORD in config.env)
rcon_password "${RCON_PASSWORD}"

exec server.cfg
AUTOEXEC_CFG
    ok "autoexec.cfg generated"
}
