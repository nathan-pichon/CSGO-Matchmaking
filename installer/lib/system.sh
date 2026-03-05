#!/usr/bin/env bash
# ==============================================================================
# installer/lib/system.sh — System utilities, OS detection, requirement checks
# ==============================================================================
# Provides: with_retry, spinner, trap handlers,
#           check_prerequisites, detect_os, check_requirements.
# ==============================================================================

# ── Retry wrapper ──────────────────────────────────────────────────────────────

# with_retry <command> [args...]
# Run a command up to RETRY_MAX times (default 3) with RETRY_DELAY seconds
# (default 5) between attempts.
with_retry() {
    local max_attempts="${RETRY_MAX:-3}"
    local delay="${RETRY_DELAY:-5}"
    local attempt=1

    while (( attempt <= max_attempts )); do
        if "$@"; then return 0; fi
        if (( attempt < max_attempts )); then
            warn "Attempt ${attempt}/${max_attempts} failed. Retrying in ${delay}s..."
            sleep "${delay}"
        fi
        (( attempt++ ))
    done

    error "All ${max_attempts} attempts failed for: $*"
    return 1
}

# ── Progress spinner ───────────────────────────────────────────────────────────

# spinner <pid> [message]
# Display a braille spinner next to a message while <pid> is running.
# Falls back to a plain wait when not attached to a TTY.
spinner() {
    local pid="$1"
    local message="${2:-Working...}"
    local chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    if [[ -t 1 ]]; then
        while kill -0 "${pid}" 2>/dev/null; do
            printf '\r  %s %s...' "${chars[$i]}" "${message}"
            (( i = (i + 1) % ${#chars[@]} ))
            sleep 0.1
        done
        printf '\r%*s\r' "$(( ${#message} + 8 ))" ""
    else
        wait "${pid}"
    fi
}

# ── Trap handlers ──────────────────────────────────────────────────────────────

_cleanup() {
    local exit_code=$?
    rm -rf "${TMPDIR:-/tmp}/csgo_install_$$" 2>/dev/null || true
    if [[ $exit_code -ne 0 ]]; then
        printf '\n%s' "${RED}"
        error "Installation failed at line ${BASH_LINENO[0]} (exit code: ${exit_code})"
        printf '%s' "${RESET}"
    fi
}

_error_handler() {
    local line="$1"
    local cmd="$2"
    error "Command failed at line ${line}: ${cmd}"
    _offer_rollback
}

_offer_rollback() {
    if [[ ${#ROLLBACK_ACTIONS[@]} -eq 0 ]]; then return 0; fi

    printf '\n'
    warn "The following components were installed during this run:"
    for component in "${INSTALLED_COMPONENTS[@]}"; do
        printf '    - %s\n' "${component}"
    done
    printf '\n'

    if confirm "Would you like to roll back these changes?"; then
        _perform_rollback
    fi
}

_perform_rollback() {
    print_section "Rolling Back Installation"
    local total=${#ROLLBACK_ACTIONS[@]}
    for (( i=total-1; i>=0; i-- )); do
        info "Rolling back: ${ROLLBACK_ACTIONS[$i]}"
        eval "${ROLLBACK_ACTIONS[$i]}" \
            || warn "Rollback step failed (continuing): ${ROLLBACK_ACTIONS[$i]}"
    done
    ok "Rollback complete."
}

trap '_cleanup' EXIT
trap '_error_handler ${LINENO} "$BASH_COMMAND"' ERR

# ── Prerequisite checks ────────────────────────────────────────────────────────

check_prerequisites() {
    print_section "Prerequisite Checks"

    # Bash 4+ required for associative arrays and [[ features used throughout
    if (( BASH_VERSINFO[0] < 4 )); then
        die "Bash 4.0+ required. Current: ${BASH_VERSION}. macOS users: brew install bash"
    fi
    ok "Bash ${BASH_VERSION}"

    # Must run as root
    if [[ "${EUID}" -ne 0 ]]; then
        die "Run as root or with sudo:  sudo ./install.sh"
    fi
    ok "Running as root"

    # Parse CLI flags
    for arg in "$@"; do
        case "${arg}" in
            --update) MODE="update" ;;
            --check)  MODE="check"  ;;
        esac
    done

    # Internet connectivity
    info "Checking internet connectivity..."
    if ! with_retry curl -sf --max-time 10 https://google.com -o /dev/null; then
        die "No internet access. This installer requires internet connectivity."
    fi
    ok "Internet connectivity verified"

    # Handle existing installation
    if [[ -f "${CONFIG_FILE}" ]]; then
        warn "Existing config.env found."
        if [[ "${MODE}" != "update" ]]; then
            printf '\n'
            printf '  Options:\n'
            printf '    1) Update existing installation (keep config, re-run components)\n'
            printf '    2) Fresh install (current config will be backed up)\n'
            printf '    3) Exit\n\n'
            local choice
            choice="$(prompt "Choose an option" "1")"
            case "${choice}" in
                1) MODE="update"  ;;
                2) MODE="install" ;;
                3) info "Exiting."; exit 0 ;;
                *) die "Invalid choice." ;;
            esac
        fi
    fi

    ok "Prerequisites passed"
}

# ── OS detection ───────────────────────────────────────────────────────────────

detect_os() {
    print_section "OS Detection"

    local kernel
    kernel="$(uname -s)"

    if [[ "${kernel}" == "Darwin" ]]; then
        OS_TYPE="macos"
        DISTRO="macos"
        PKG_MANAGER="brew"
        VERSION_ID="$(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
        warn "macOS detected — DEV mode only."
        warn "Production deployments must use Linux."
        warn "Skipped on macOS: systemd services, SteamCMD, full CS:GO download."
        ok "macOS ${VERSION_ID} (development mode)"
        return 0
    fi

    [[ "${kernel}" == "Linux" ]] \
        || die "Unsupported OS: ${kernel}. Only Linux and macOS are supported."

    OS_TYPE="linux"

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO="${ID:-unknown}"
        VERSION_ID="${VERSION_ID:-unknown}"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO="rhel"
        VERSION_ID="$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)"
    else
        DISTRO="unknown"
        VERSION_ID="unknown"
    fi

    case "${DISTRO}" in
        ubuntu|debian|linuxmint|pop)
            PKG_MANAGER="apt" ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="$(command -v dnf &>/dev/null && echo dnf || echo yum)" ;;
        fedora)
            PKG_MANAGER="dnf" ;;
        arch|manjaro|endeavouros)
            PKG_MANAGER="pacman" ;;
        *)
            die "Unsupported distro: ${DISTRO}. Supported: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch." ;;
    esac

    ok "Detected: ${DISTRO} ${VERSION_ID} (package manager: ${PKG_MANAGER})"
}

# ── System requirements ────────────────────────────────────────────────────────

check_requirements() {
    print_section "System Requirements"
    local borderline=0 failed=0

    # RAM
    local ram_mb=0
    if [[ "${OS_TYPE}" == "linux" ]]; then
        ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        ram_mb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
    fi

    if   (( ram_mb < MIN_RAM_MB ));  then error "RAM: ${ram_mb}MB — minimum ${MIN_RAM_MB}MB required."; (( failed++ ))
    elif (( ram_mb < WARN_RAM_MB )); then warn  "RAM: ${ram_mb}MB — ${WARN_RAM_MB}MB recommended."    ; (( borderline++ ))
    else                                  ok    "RAM: ${ram_mb}MB"
    fi

    # CPU cores
    local cpu_cores=0
    if [[ "${OS_TYPE}" == "linux" ]]; then
        cpu_cores=$(nproc)
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        cpu_cores=$(sysctl -n hw.ncpu)
    fi

    if (( cpu_cores < MIN_CPU_CORES )); then
        error "CPU Cores: ${cpu_cores} — minimum ${MIN_CPU_CORES} required."
        (( failed++ ))
    else
        ok "CPU Cores: ${cpu_cores}"
    fi

    # Disk space
    local disk_gb=0
    if [[ "${OS_TYPE}" == "linux" ]]; then
        disk_gb=$(df -BG "${SCRIPT_DIR}" | awk 'NR==2 {gsub("G",""); print $4}')
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        disk_gb=$(df -g "${SCRIPT_DIR}" | awk 'NR==2 {print $4}')
    fi

    if (( disk_gb < MIN_DISK_GB / 2 )); then
        error "Disk: ${disk_gb}GB free — minimum ${MIN_DISK_GB}GB required."
        (( failed++ ))
    elif (( disk_gb < MIN_DISK_GB )); then
        warn "Disk: ${disk_gb}GB free — ${MIN_DISK_GB}GB recommended."
        (( borderline++ ))
    else
        ok "Disk: ${disk_gb}GB free"
    fi

    # macOS dev warning
    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "macOS is only supported for development. Do not use in production."
        (( borderline++ ))
    fi

    # Port conflicts
    info "Checking for port conflicts..."
    local port_conflicts=()
    for port in "${REQUIRED_PORTS[@]}"; do
        check_port_free "${port}" || port_conflicts+=("${port}")
    done

    if [[ ${#port_conflicts[@]} -gt 0 ]]; then
        warn "Ports already in use: ${port_conflicts[*]} — you will be asked to choose alternatives."
        (( borderline++ ))
    else
        ok "Required ports (${REQUIRED_PORTS[*]}) are all available"
    fi

    # Summary table
    printf '\n  %-25s %-15s %-15s\n' "Requirement" "Detected" "Minimum"
    printf '  %-25s %-15s %-15s\n' "─────────────────────────" "───────────────" "───────────────"
    printf '  %-25s %-15s %-15s\n' "RAM" "${ram_mb}MB" "${MIN_RAM_MB}MB"
    printf '  %-25s %-15s %-15s\n' "CPU Cores" "${cpu_cores}" "${MIN_CPU_CORES}"
    printf '  %-25s %-15s %-15s\n' "Free Disk" "${disk_gb}GB" "${MIN_DISK_GB}GB"
    printf '\n'

    (( failed == 0 )) || die "System does not meet minimum requirements (${failed} failure(s))."

    if (( borderline > 0 )); then
        warn "${borderline} requirement(s) are borderline."
        confirm "System requirements are borderline. Continue anyway?" \
            || { info "Exiting."; exit 0; }
    fi

    ok "System requirements check passed"
}
