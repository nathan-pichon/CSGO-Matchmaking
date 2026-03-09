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
# Label is written to /dev/tty so this is safe inside $(...) substitution.
prompt() {
    local message="$1"
    local default="${2:-}"
    local response

    if [[ -n "${default}" ]]; then
        printf '  %s%s%s [%s%s%s]: ' \
            "${BOLD}" "${message}" "${RESET}" "${DIM}" "${default}" "${RESET}" >/dev/tty
    else
        printf '  %s%s%s: ' "${BOLD}" "${message}" "${RESET}" >/dev/tty
    fi

    read -r response </dev/tty
    printf '%s\n' "${response:-${default}}"
}

# prompt_secret <message>
# Like prompt but hides the input (no echo).
# Label is written to /dev/tty so this is safe inside $(...) substitution.
prompt_secret() {
    local message="$1"
    local response

    printf '  %s%s%s: ' "${BOLD}" "${message}" "${RESET}" >/dev/tty
    read -rs response </dev/tty
    printf '\n' >/dev/tty
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

    printf '  %s%s%s %s ' "${BOLD}" "${message}" "${RESET}" "${prompt_str}" >/dev/tty
    read -r response </dev/tty
    response="${response:-${default}}"
    [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

# choose <prompt> <label1> <label2> ...
# Display a numbered menu and return the 1-based index of the chosen option.
# All display output goes to /dev/tty so this function is safe to call inside
# $(...) command substitution without swallowing the menu or the prompt.
choose() {
    local prompt_msg="$1"; shift
    local -a options=("$@")
    local i _choice

    # Write the menu directly to the terminal, bypassing any $(...) capture
    {
        printf '\n'
        for (( i=0; i < ${#options[@]}; i++ )); do
            printf '  %s%d)%s %s\n' "${BOLD}" "$(( i + 1 ))" "${RESET}" "${options[$i]}"
        done
        printf '\n'
    } >/dev/tty

    while true; do
        # Prompt and read directly from/to the terminal
        printf '  %s%s%s [%s1%s]: ' \
            "${BOLD}" "${prompt_msg}" "${RESET}" "${DIM}" "${RESET}" >/dev/tty
        read -r _choice </dev/tty
        _choice="${_choice:-1}"
        if [[ "${_choice}" =~ ^[0-9]+$ ]] && \
           (( _choice >= 1 && _choice <= ${#options[@]} )); then
            break
        fi
        printf '  \033[31m✗\033[0m  Please enter a number between 1 and %d\n' \
            "${#options[@]}" >/dev/tty
    done

    # Only the numeric result goes to stdout (captured by the caller's $(...))
    printf '%d\n' "${_choice}"
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
