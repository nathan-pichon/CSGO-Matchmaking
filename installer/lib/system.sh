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

trap '_cleanup'                          EXIT
trap '_error_handler ${LINENO} "$BASH_COMMAND"' ERR
trap '_sigint_handler'                   SIGINT SIGTERM

_sigint_handler() {
    printf '\n\n'
    warn "Installation interrupted by user (Ctrl+C / SIGTERM)."
    _offer_rollback
    # Reset the signal to default so the script exits normally
    trap - SIGINT SIGTERM
    exit 130
}

# ── Prerequisite checks ────────────────────────────────────────────────────────

check_prerequisites() {
    print_section "Prerequisite Checks"

    # Bash 4+ required for associative arrays and [[ features used throughout.
    # On macOS this is normally handled by the auto-install block at the top of
    # install.sh — reaching here means something went wrong; show clear guidance.
    if (( BASH_VERSINFO[0] < 4 )); then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            die "Bash 4.0+ required (current: ${BASH_VERSION}). Run: brew install bash"
        else
            die "Bash 4.0+ required (current: ${BASH_VERSION}). Install a modern bash via your package manager."
        fi
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
            --update)   MODE="update"  ;;
            --check)    MODE="check"   ;;
            --dry-run)  DRY_RUN=true   ;;
        esac
    done
    [[ "${DRY_RUN}" == "true" ]] && warn "DRY RUN mode — wizard will run but no system changes will be made."

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

    if   (( ram_mb < MIN_RAM_MB ));  then error "RAM: ${ram_mb}MB — minimum ${MIN_RAM_MB}MB required."; (( ++failed ))
    elif (( ram_mb < WARN_RAM_MB )); then warn  "RAM: ${ram_mb}MB — ${WARN_RAM_MB}MB recommended."    ; (( ++borderline ))
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
        (( ++failed ))
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
        (( ++failed ))
    elif (( disk_gb < MIN_DISK_GB )); then
        warn "Disk: ${disk_gb}GB free — ${MIN_DISK_GB}GB recommended."
        (( ++borderline ))
    else
        ok "Disk: ${disk_gb}GB free"
    fi

    # macOS dev warning
    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "macOS is only supported for development. Do not use in production."
        (( ++borderline ))
    fi

    # Port conflicts
    info "Checking for port conflicts..."
    local port_conflicts=()
    for port in "${REQUIRED_PORTS[@]}"; do
        check_port_free "${port}" || port_conflicts+=("${port}")
    done

    if [[ ${#port_conflicts[@]} -gt 0 ]]; then
        warn "Ports already in use: ${port_conflicts[*]} — you will be asked to choose alternatives."
        (( ++borderline ))
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

# ── Cloud provider detection ────────────────────────────────────────────────────

# detect_cloud_provider
# Probes well-known instance metadata endpoints to identify the hosting provider.
# Prints one of: aws | gcp | azure | ovh | hetzner | digitalocean | bare-metal
detect_cloud_provider() {
    # AWS — IMDSv1 (no token required, fast)
    if curl -sf --max-time 2 \
            http://169.254.169.254/latest/meta-data/instance-id &>/dev/null; then
        echo "aws"; return 0
    fi
    # GCP — requires Metadata-Flavor header
    if curl -sf --max-time 2 \
            -H "Metadata-Flavor: Google" \
            http://metadata.google.internal/computeMetadata/v1/instance/id \
            &>/dev/null; then
        echo "gcp"; return 0
    fi
    # Azure — IMDS (requires Metadata: true header)
    if curl -sf --max-time 2 \
            -H "Metadata: true" \
            "http://169.254.169.254/metadata/instance?api-version=2021-02-01" \
            &>/dev/null; then
        echo "azure"; return 0
    fi
    # Hetzner Cloud — vendor file
    if [[ -f /etc/hetzner-cloud ]] \
            || grep -qi "hetzner" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        echo "hetzner"; return 0
    fi
    # DigitalOcean — vendor ID
    if grep -qi "digitalocean" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        echo "digitalocean"; return 0
    fi
    # OVH / Bare-metal — no standard metadata endpoint; check vendor string
    if grep -qi "ovh" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        echo "ovh"; return 0
    fi
    echo "bare-metal"
}

# show_cloud_firewall_notice <provider> <lobby_port> <web_port> <match_start> <match_end>
# Prints a provider-specific reminder to open ports in the cloud console.
show_cloud_firewall_notice() {
    local provider="$1"
    local lobby_port="${2:-27015}"
    local web_port="${3:-5000}"
    local match_start="${4:-27020}"
    local match_end="${5:-27029}"

    [[ "${provider}" == "bare-metal" ]] && return 0

    printf '\n'
    printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${YELLOW}" "${RESET}"
    printf '  %s⚠  Cloud Provider Detected: %s%s\n' "${YELLOW}" "${provider^^}" "${RESET}"
    printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "${YELLOW}" "${RESET}"

    printf '  The installer configures the OS-level firewall (UFW/iptables), but\n'
    printf '  %s cloud providers also have a separate network-level firewall%s\n' "${BOLD}" "${RESET}"
    printf '  (Security Groups / NSG) that you must configure in their console.\n\n'
    printf '  %sYou must open these ports in your %s console:%s\n\n' "${BOLD}" "${provider^^}" "${RESET}"
    printf '  %-12s %-10s %s\n' "Port(s)" "Protocol" "Service"
    printf '  %-12s %-10s %s\n' "────────────" "────────" "──────────────────────────"
    printf '  %-12s %-10s %s\n' "${lobby_port}" "UDP+TCP"  "CS:GO Lobby server"
    printf '  %-12s %-10s %s\n' "${web_port}"   "TCP"      "Web panel (HTTP)"
    printf '  %-12s %-10s %s\n' "${match_start}-${match_end}" "UDP+TCP" "Match servers (game + RCON)"
    printf '\n'
    printf '  %s⚠  UDP traffic must be allowed — CS:GO game data runs over UDP!%s\n\n' "${YELLOW}" "${RESET}"

    case "${provider}" in
        aws)
            printf '  %sAWS — Where to open ports:%s\n' "${BOLD}" "${RESET}"
            printf '    EC2 Console → Instances → your instance → Security tab\n'
            printf '    → Security Groups → Edit Inbound Rules\n'
            printf '    Add rules: Custom UDP / Custom TCP for each port range.\n'
            printf '    Docs: %shttps://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html%s\n\n' "${CYAN}" "${RESET}"
            printf '  %sRecommended EC2 instance types for production:%s\n' "${BOLD}" "${RESET}"
            printf '    c5.xlarge (4 vCPU, 8GB RAM)  — up to 5 simultaneous matches\n'
            printf '    c5.2xlarge (8 vCPU, 16GB RAM) — up to 10 simultaneous matches\n\n'
            ;;
        gcp)
            printf '  %sGoogle Cloud — Where to open ports:%s\n' "${BOLD}" "${RESET}"
            printf '    VPC Network → Firewall → Create Firewall Rule\n'
            printf '    Direction: Ingress | Action: Allow | Protocols: tcp/udp | Ports: all above\n'
            printf '    Docs: %shttps://cloud.google.com/vpc/docs/using-firewalls%s\n\n' "${CYAN}" "${RESET}"
            printf '  %sRecommended GCP instance types for production:%s\n' "${BOLD}" "${RESET}"
            printf '    n2-standard-4 (4 vCPU, 16GB RAM) — general purpose\n'
            printf '    c2-standard-4 (4 vCPU, 16GB RAM) — compute-optimized (lower latency)\n\n'
            ;;
        azure)
            printf '  %sAzure — Where to open ports:%s\n' "${BOLD}" "${RESET}"
            printf '    Portal → Virtual Machines → your VM → Networking\n'
            printf '    → Add Inbound Port Rule for each port range.\n'
            printf '    Docs: %shttps://docs.microsoft.com/azure/virtual-machines/windows/nsg-quickstart-portal%s\n\n' "${CYAN}" "${RESET}"
            printf '  %sRecommended Azure VM sizes for production:%s\n' "${BOLD}" "${RESET}"
            printf '    D4s_v5 (4 vCPU, 16GB RAM) or F4s_v2 (4 vCPU, 8GB, compute-optimized)\n\n'
            ;;
        hetzner)
            printf '  %sHetzner — Where to open ports:%s\n' "${BOLD}" "${RESET}"
            printf '    Cloud Console → Firewalls → Create Firewall\n'
            printf '    Add Inbound rules for TCP and UDP on the port ranges above.\n'
            printf '    Apply the firewall to your server.\n'
            printf '    Docs: %shttps://docs.hetzner.com/cloud/firewalls/getting-started/creating-a-firewall/%s\n\n' "${CYAN}" "${RESET}"
            printf '  %sRecommended Hetzner server for production:%s\n' "${BOLD}" "${RESET}"
            printf '    CPX31 (4 vCPU, 8GB RAM) or CPX41 (8 vCPU, 16GB RAM)\n\n'
            ;;
        digitalocean)
            printf '  %sDigitalOcean — Where to open ports:%s\n' "${BOLD}" "${RESET}"
            printf '    Control Panel → Networking → Firewalls → Create Firewall\n'
            printf '    Add Inbound rules: Custom TCP/UDP for each port range.\n'
            printf '    Docs: %shttps://docs.digitalocean.com/products/networking/firewalls/%s\n\n' "${CYAN}" "${RESET}"
            printf '  %sRecommended Droplet for production:%s\n' "${BOLD}" "${RESET}"
            printf '    General Purpose 8GB+ (4 vCPU) for up to 10 match slots\n\n'
            ;;
        ovh)
            printf '  %sOVH — Where to open ports:%s\n' "${BOLD}" "${RESET}"
            printf '    OVH Manager → Bare Metal Cloud → your server\n'
            printf '    Network → Firewall → Add a rule for each port.\n'
            printf '    Docs: %shttps://help.ovhcloud.com/csm/en-dedicated-servers-firewall-network%s\n\n' "${CYAN}" "${RESET}"
            printf '  %sNote about OVH Game servers:%s\n' "${BOLD}" "${RESET}"
            printf '    OVH Game servers include DDoS protection tuned for CS:GO.\n'
            printf '    Recommended: OVH Bare Metal Game or Rise series (8+ cores, 32GB+ RAM)\n\n'
            ;;
    esac

    printf '  %sIMPORTANT: Open these ports BEFORE players try to connect.%s\n' "${YELLOW}" "${RESET}"
    printf '  Players will see "Connection timed out" if UDP ports are blocked.\n'
    printf '\n'
}
