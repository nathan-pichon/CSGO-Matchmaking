#!/usr/bin/env bash
# ==============================================================================
# installer/lib/input.sh — Interactive input helpers and validators
# ==============================================================================
# Provides: prompt, prompt_secret, confirm,
#           validate_ip, validate_port, validate_gslt, check_port_free,
#           generate_password, generate_hex_password.
# ==============================================================================

# prompt <message> [default]
# Print a styled prompt and return the user's input (or the default).
prompt() {
    local message="$1"
    local default="${2:-}"
    local response

    if [[ -n "${default}" ]]; then
        printf '  %s%s%s [%s%s%s]: ' "${BOLD}" "${message}" "${RESET}" "${DIM}" "${default}" "${RESET}"
    else
        printf '  %s%s%s: ' "${BOLD}" "${message}" "${RESET}"
    fi

    read -r response
    printf '%s\n' "${response:-${default}}"
}

# prompt_secret <message>
# Like prompt but hides the input (no echo).
prompt_secret() {
    local message="$1"
    local response

    printf '  %s%s%s: ' "${BOLD}" "${message}" "${RESET}"
    read -rs response
    printf '\n'
    printf '%s\n' "${response}"
}

# confirm <message> [default]
# Ask a yes/no question; returns 0 for yes, 1 for no.
# default: "y" (default yes) or "n" (default no). Defaults to "y".
confirm() {
    local message="${1:-Continue?}"
    local default="${2:-y}"
    local prompt_str response

    if [[ "${default,,}" == "y" ]]; then prompt_str="[Y/n]"; else prompt_str="[y/N]"; fi

    printf '  %s%s%s %s ' "${BOLD}" "${message}" "${RESET}" "${prompt_str}"
    read -r response
    response="${response:-${default}}"
    [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

# ── Validators ─────────────────────────────────────────────────────────────────

# validate_ip <value>  — accepts IPv4 addresses and hostnames
validate_ip() {
    local ip="$1"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a parts
        read -ra parts <<< "${ip}"
        for part in "${parts[@]}"; do
            (( part <= 255 )) || return 1
        done
        return 0
    fi
    # Also accept valid hostnames
    [[ "${ip}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

# validate_port <value>
validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# validate_gslt <token>
# GSLT tokens are 20–40 uppercase alphanumeric characters.
validate_gslt() {
    [[ "$1" =~ ^[A-Z0-9]{20,40}$ ]]
}

# check_port_free <port>
# Returns 0 if the port is not in use, 1 otherwise.
check_port_free() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ! ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v netstat &>/dev/null; then
        ! netstat -tlnp 2>/dev/null | grep -q ":${port} "
    else
        return 0  # Cannot check — assume free
    fi
}

# ── Password generators ────────────────────────────────────────────────────────

# generate_password [length=24]
generate_password() {
    local length="${1:-24}"
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "${length}" 2>/dev/null || \
        openssl rand -base64 "${length}" | tr -dc 'A-Za-z0-9' | head -c "${length}"
}

# generate_hex_password [length=16]
generate_hex_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${length}" 2>/dev/null || \
        openssl rand -hex "${length}"
}
