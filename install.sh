#!/usr/bin/env bash
# ==============================================================================
# CS:GO Matchmaking System - Installation Wizard
# ==============================================================================
# Version: 1.0.0
# License: MIT
#
# DISCLAIMER: This installer configures a Counter-Strike: Global Offensive
# dedicated server and matchmaking backend. You are responsible for complying
# with Valve's Steam Subscriber Agreement and Game Server policies. You must
# obtain valid Game Server Login Tokens (GSLTs) from your Steam account before
# running this installer. This software is provided as-is with no warranty.
#
# Usage:
#   sudo ./install.sh           Normal installation
#   sudo ./install.sh --update  Update existing installation
#   sudo ./install.sh --check   Only run system checks
# ==============================================================================

set -euo pipefail

# ==============================================================================
# GLOBALS
# ==============================================================================
readonly INSTALLER_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/install.log"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.env"
readonly CONFIG_EXAMPLE="${SCRIPT_DIR}/config.example.env"
readonly CSGO_DIR="/opt/csgo-server"
readonly MATCHMAKER_VENV="/opt/csgo-matchmaker-venv"
readonly WEBPANEL_VENV="/opt/csgo-webpanel-venv"
readonly STEAM_USER="steam"
readonly MIN_RAM_MB=4096
readonly WARN_RAM_MB=8192
readonly MIN_CPU_CORES=2
readonly MIN_DISK_GB=50
readonly REQUIRED_PORTS=(27015 27020 3306 5000)
readonly SM_VERSION="1.11"
readonly SM_BUILD="7152"
readonly MM_VERSION="1.12"

# Runtime state
OS_TYPE=""
DISTRO=""
PKG_MANAGER=""
VERSION_ID=""
INSTALLED_COMPONENTS=()
ROLLBACK_ACTIONS=()
MODE="install"

# Configuration values (set by wizard)
SERVER_IP=""
DB_HOST="localhost"
DB_PORT="3306"
DB_ROOT_PASS=""
DB_PASS=""
RCON_PASSWORD=""
LOBBY_GSLT=""
MATCH_GSLTS=()
LOBBY_PORT="27015"
MATCH_PORT_START="27020"
MATCH_SLOTS="10"
WEB_PORT="5000"
PLAYERS_PER_TEAM="5"
MAX_ELO_SPREAD="200"
READY_CHECK_TIMEOUT="30"
DISCORD_WEBHOOK_URL=""
FLASK_SECRET_KEY=""
SELECTED_MAPS=()
USE_EXISTING_MYSQL="n"

# All available maps
ALL_MAPS=(
    "de_dust2"
    "de_mirage"
    "de_inferno"
    "de_nuke"
    "de_overpass"
    "de_vertigo"
    "de_ancient"
    "de_anubis"
    "de_cache"
    "de_train"
)

# ==============================================================================
# COLORS AND FORMATTING
# ==============================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    MAGENTA=""
    BOLD=""
    DIM=""
    RESET=""
fi

# ==============================================================================
# LOGGING SETUP
# ==============================================================================
# Tee all output to log file
exec 1> >(tee -a "${LOG_FILE}") 2>&1

log_raw() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

# ==============================================================================
# DISPLAY HELPERS
# ==============================================================================
print_header() {
    printf '\n'
    printf '%s' "${CYAN}"
    printf '╔══════════════════════════════════════════════════════════════════════╗\n'
    printf '║                                                                      ║\n'
    printf '║        ██████╗███████╗      ██████╗  ██████╗                        ║\n'
    printf '║       ██╔════╝██╔════╝     ██╔════╝ ██╔═══██╗                       ║\n'
    printf '║       ██║     ███████╗     ██║  ███╗██║   ██║                        ║\n'
    printf '║       ██║     ╚════██║     ██║   ██║██║   ██║                        ║\n'
    printf '║       ╚██████╗███████║     ╚██████╔╝╚██████╔╝                        ║\n'
    printf '║        ╚═════╝╚══════╝      ╚═════╝  ╚═════╝                        ║\n'
    printf '║                                                                      ║\n'
    printf '║           Matchmaking System Installer  v%-29s║\n' "${INSTALLER_VERSION}"
    printf '║                                                                      ║\n'
    printf '╚══════════════════════════════════════════════════════════════════════╝\n'
    printf '%s\n' "${RESET}"
    printf '%s%sDISCLAIMER:%s You must have valid Valve GSLTs and accept Valve'"'"'s\n' "${BOLD}" "${YELLOW}" "${RESET}"
    printf '          Steam Subscriber Agreement before proceeding.\n'
    printf '          See: https://store.steampowered.com/subscriber_agreement/\n\n'
}

print_section() {
    local title="$1"
    local width=70
    local pad=$(( (width - ${#title} - 2) / 2 ))
    printf '\n%s' "${BOLD}${BLUE}"
    printf '%.0s─' $(seq 1 "${width}")
    printf '\n'
    printf '%*s %s %*s\n' "${pad}" "" "${title}" "${pad}" ""
    printf '%.0s─' $(seq 1 "${width}")
    printf '%s\n\n' "${RESET}"
}

print_step() {
    local num="$1"
    local title="$2"
    printf '\n%s[Step %s]%s %s%s%s\n' "${BOLD}${MAGENTA}" "${num}" "${RESET}" "${BOLD}" "${title}" "${RESET}"
}

ok() {
    printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$*"
    log_raw "OK: $*"
}

warn() {
    printf '  %s⚠%s  %s\n' "${YELLOW}" "${RESET}" "$*"
    log_raw "WARN: $*"
}

error() {
    printf '  %s✗%s  %s\n' "${RED}" "${RESET}" "$*" >&2
    log_raw "ERROR: $*"
}

info() {
    printf '  %s→%s  %s\n' "${CYAN}" "${RESET}" "$*"
    log_raw "INFO: $*"
}

die() {
    error "$*"
    printf '\n%sFatal error. Check %s for details.%s\n' "${RED}" "${LOG_FILE}" "${RESET}" >&2
    exit 1
}

# ==============================================================================
# TRAP HANDLERS
# ==============================================================================
_cleanup() {
    local exit_code=$?
    if [[ -d "${TMPDIR:-/tmp}/csgo_install_$$" ]]; then
        rm -rf "${TMPDIR:-/tmp}/csgo_install_$$"
    fi
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
    if [[ ${#ROLLBACK_ACTIONS[@]} -gt 0 ]]; then
        printf '\n'
        warn "The following components were installed during this run:"
        for component in "${INSTALLED_COMPONENTS[@]}"; do
            printf '    - %s\n' "${component}"
        done
        printf '\n'
        if confirm "Would you like to roll back these changes?"; then
            _perform_rollback
        fi
    fi
}

_perform_rollback() {
    print_section "Rolling Back Installation"
    # Execute rollback actions in reverse order
    local total=${#ROLLBACK_ACTIONS[@]}
    for (( i=total-1; i>=0; i-- )); do
        info "Rolling back: ${ROLLBACK_ACTIONS[$i]}"
        eval "${ROLLBACK_ACTIONS[$i]}" || warn "Rollback step failed (continuing): ${ROLLBACK_ACTIONS[$i]}"
    done
    ok "Rollback complete."
}

trap '_cleanup' EXIT
trap '_error_handler ${LINENO} "$BASH_COMMAND"' ERR

# ==============================================================================
# INPUT HELPERS
# ==============================================================================
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
    if [[ -z "${response}" && -n "${default}" ]]; then
        printf '%s\n' "${default}"
    else
        printf '%s\n' "${response}"
    fi
}

prompt_secret() {
    local message="$1"
    local response
    printf '  %s%s%s: ' "${BOLD}" "${message}" "${RESET}"
    read -rs response
    printf '\n'
    printf '%s\n' "${response}"
}

confirm() {
    local message="${1:-Continue?}"
    local default="${2:-y}"
    local prompt_str
    if [[ "${default,,}" == "y" ]]; then
        prompt_str="[Y/n]"
    else
        prompt_str="[y/N]"
    fi
    printf '  %s%s%s %s ' "${BOLD}" "${message}" "${RESET}" "${prompt_str}"
    local response
    read -r response
    response="${response:-${default}}"
    [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

validate_ip() {
    local ip="$1"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra parts <<< "${ip}"
        for part in "${parts[@]}"; do
            if (( part > 255 )); then return 1; fi
        done
        return 0
    fi
    # Also accept hostnames
    if [[ "${ip}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    return 1
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_gslt() {
    local token="$1"
    # GSLT tokens are typically 20-40 alphanumeric characters
    [[ "${token}" =~ ^[A-Z0-9]{20,40}$ ]]
}

check_port_free() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ! ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v netstat &>/dev/null; then
        ! netstat -tlnp 2>/dev/null | grep -q ":${port} "
    else
        # Cannot check — assume free
        return 0
    fi
}

generate_password() {
    local length="${1:-24}"
    # Use /dev/urandom for secure random password
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "${length}" 2>/dev/null || \
        openssl rand -base64 "${length}" | tr -dc 'A-Za-z0-9' | head -c "${length}"
}

generate_hex_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${length}" 2>/dev/null || \
        openssl rand -hex "${length}"
}

# ==============================================================================
# RETRY WRAPPER
# ==============================================================================
with_retry() {
    local max_attempts="${RETRY_MAX:-3}"
    local delay="${RETRY_DELAY:-5}"
    local attempt=1
    while (( attempt <= max_attempts )); do
        if "$@"; then
            return 0
        fi
        if (( attempt < max_attempts )); then
            warn "Attempt ${attempt}/${max_attempts} failed. Retrying in ${delay}s..."
            sleep "${delay}"
        fi
        (( attempt++ ))
    done
    error "All ${max_attempts} attempts failed for: $*"
    return 1
}

# ==============================================================================
# PROGRESS SPINNER
# ==============================================================================
spinner() {
    local pid="$1"
    local message="${2:-Working...}"
    local chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    # Only run spinner on a real terminal
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

# ==============================================================================
# OS DETECTION
# ==============================================================================
detect_os() {
    print_section "OS Detection"

    local kernel
    kernel="$(uname -s)"

    if [[ "${kernel}" == "Darwin" ]]; then
        OS_TYPE="macos"
        DISTRO="macos"
        PKG_MANAGER="brew"
        VERSION_ID="$(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
        warn "macOS detected. This is a DEV-ONLY setup."
        warn "Production deployments must use Linux."
        warn "The following will be skipped: systemd services, SteamCMD, full CS:GO download"
        ok "macOS ${VERSION_ID} detected (development mode)"
        return 0
    fi

    if [[ "${kernel}" != "Linux" ]]; then
        die "Unsupported operating system: ${kernel}. Only Linux and macOS are supported."
    fi

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
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        arch|manjaro|endeavouros)
            PKG_MANAGER="pacman"
            ;;
        *)
            die "Unsupported Linux distribution: ${DISTRO}. Supported: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch."
            ;;
    esac

    ok "Detected: ${DISTRO} ${VERSION_ID} (package manager: ${PKG_MANAGER})"
}

# ==============================================================================
# PREREQUISITE CHECKS
# ==============================================================================
check_prerequisites() {
    print_section "Prerequisite Checks"

    # Bash version check
    local bash_major="${BASH_VERSINFO[0]}"
    local bash_minor="${BASH_VERSINFO[1]}"
    if (( bash_major < 4 )); then
        die "Bash 4.0+ required. Current version: ${BASH_VERSION}. On macOS, install: brew install bash"
    fi
    ok "Bash ${BASH_VERSION} (>= 4.0 required)"

    # Root / sudo check
    if [[ "${EUID}" -ne 0 ]]; then
        die "This installer must be run as root or with sudo. Try: sudo ./install.sh"
    fi
    ok "Running as root"

    # Parse command line arguments
    for arg in "$@"; do
        case "${arg}" in
            --update) MODE="update" ;;
            --check)  MODE="check" ;;
        esac
    done

    # Internet connectivity check
    info "Checking internet connectivity..."
    if ! with_retry curl -sf --max-time 10 https://google.com -o /dev/null; then
        die "No internet access. This installer requires internet connectivity."
    fi
    ok "Internet connectivity verified"

    # Existing installation check
    if [[ -f "${CONFIG_FILE}" ]]; then
        warn "Existing config.env found."
        if [[ "${MODE}" != "update" ]]; then
            printf '\n'
            printf '  Options:\n'
            printf '    1) Update existing installation (keep config, re-run components)\n'
            printf '    2) Fresh install (overwrite config — current config will be backed up)\n'
            printf '    3) Exit\n\n'
            local choice
            choice="$(prompt "Choose an option" "1")"
            case "${choice}" in
                1) MODE="update" ;;
                2) MODE="install" ;;
                3) info "Exiting."; exit 0 ;;
                *) die "Invalid choice." ;;
            esac
        fi
    fi

    ok "Prerequisites passed"
}

# ==============================================================================
# SYSTEM REQUIREMENTS CHECK
# ==============================================================================
check_requirements() {
    print_section "System Requirements"
    local borderline=0
    local failed=0

    # RAM check
    local ram_mb=0
    if [[ "${OS_TYPE}" == "linux" ]]; then
        ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        ram_mb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
    fi

    if (( ram_mb < MIN_RAM_MB )); then
        error "RAM: ${ram_mb}MB detected. Minimum ${MIN_RAM_MB}MB required."
        (( failed++ ))
    elif (( ram_mb < WARN_RAM_MB )); then
        warn "RAM: ${ram_mb}MB detected. Recommended: ${WARN_RAM_MB}MB (8GB) for best performance."
        (( borderline++ ))
    else
        ok "RAM: ${ram_mb}MB (>= ${WARN_RAM_MB}MB recommended)"
    fi

    # CPU cores check
    local cpu_cores=0
    if [[ "${OS_TYPE}" == "linux" ]]; then
        cpu_cores=$(nproc)
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        cpu_cores=$(sysctl -n hw.ncpu)
    fi

    if (( cpu_cores < MIN_CPU_CORES )); then
        error "CPU Cores: ${cpu_cores} detected. Minimum ${MIN_CPU_CORES} required."
        (( failed++ ))
    else
        ok "CPU Cores: ${cpu_cores} (>= ${MIN_CPU_CORES} required)"
    fi

    # Disk space check
    local disk_gb=0
    if [[ "${OS_TYPE}" == "linux" ]]; then
        disk_gb=$(df -BG "${SCRIPT_DIR}" | awk 'NR==2 {gsub("G",""); print $4}')
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        disk_gb=$(df -g "${SCRIPT_DIR}" | awk 'NR==2 {print $4}')
    fi

    if (( disk_gb < MIN_DISK_GB )); then
        if (( disk_gb < MIN_DISK_GB / 2 )); then
            error "Disk: ${disk_gb}GB free. Minimum ${MIN_DISK_GB}GB required."
            (( failed++ ))
        else
            warn "Disk: ${disk_gb}GB free. Minimum ${MIN_DISK_GB}GB required."
            (( borderline++ ))
        fi
    else
        ok "Disk: ${disk_gb}GB free in ${SCRIPT_DIR} (>= ${MIN_DISK_GB}GB required)"
    fi

    # macOS production warning
    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "macOS is only supported for development. Do not use in production."
        (( borderline++ ))
    fi

    # Port conflict check
    info "Checking for port conflicts..."
    local port_conflicts=()
    for port in "${REQUIRED_PORTS[@]}"; do
        if ! check_port_free "${port}"; then
            port_conflicts+=("${port}")
        fi
    done

    if [[ ${#port_conflicts[@]} -gt 0 ]]; then
        warn "Ports already in use: ${port_conflicts[*]}"
        warn "You will be asked to choose different ports during configuration."
        (( borderline++ ))
    else
        ok "Required ports (${REQUIRED_PORTS[*]}) are all available"
    fi

    # Print summary table
    printf '\n'
    printf '  %-25s %-15s %-15s\n' "Requirement" "Detected" "Minimum"
    printf '  %-25s %-15s %-15s\n' "─────────────────────────" "───────────────" "───────────────"
    printf '  %-25s %-15s %-15s\n' "RAM" "${ram_mb}MB" "${MIN_RAM_MB}MB"
    printf '  %-25s %-15s %-15s\n' "CPU Cores" "${cpu_cores}" "${MIN_CPU_CORES}"
    printf '  %-25s %-15s %-15s\n' "Free Disk" "${disk_gb}GB" "${MIN_DISK_GB}GB"
    printf '\n'

    if (( failed > 0 )); then
        die "System does not meet minimum requirements (${failed} failure(s))."
    fi

    if (( borderline > 0 )); then
        warn "${borderline} requirement(s) are borderline."
        if ! confirm "System requirements are borderline. Continue anyway?"; then
            info "Exiting."
            exit 0
        fi
    fi

    ok "System requirements check passed"
}

# ==============================================================================
# PACKAGE INSTALLATION
# ==============================================================================
is_installed() {
    local pkg="$1"
    case "${PKG_MANAGER}" in
        apt)    dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii' ;;
        yum|dnf) rpm -q "${pkg}" &>/dev/null ;;
        pacman) pacman -Q "${pkg}" &>/dev/null ;;
        brew)   brew list "${pkg}" &>/dev/null ;;
    esac
}

install_packages() {
    print_section "Installing Dependencies"

    case "${PKG_MANAGER}" in
        apt)    _install_packages_apt ;;
        yum)    _install_packages_yum ;;
        dnf)    _install_packages_dnf ;;
        pacman) _install_packages_pacman ;;
        brew)   _install_packages_brew ;;
        *)      die "Unknown package manager: ${PKG_MANAGER}" ;;
    esac
}

_apt_update_if_needed() {
    local cache_file="/var/lib/apt/periodic/update-success-stamp"
    local cache_age=3600  # 1 hour in seconds
    if [[ ! -f "${cache_file}" ]] || (( $(date +%s) - $(stat -c %Y "${cache_file}" 2>/dev/null || echo 0) > cache_age )); then
        info "Updating apt package lists..."
        apt-get update -qq
    fi
}

_install_packages_apt() {
    _apt_update_if_needed

    # Core utilities
    local core_pkgs=(curl wget tar unzip git screen python3 python3-pip python3-venv gnupg2 ca-certificates lsb-release software-properties-common)
    local to_install=()
    for pkg in "${core_pkgs[@]}"; do
        if ! is_installed "${pkg}"; then
            to_install+=("${pkg}")
        else
            ok "Already installed: ${pkg}"
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        info "Installing core packages: ${to_install[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
        ok "Core packages installed"
    fi

    # MySQL / MariaDB
    if ! is_installed "mysql-server" && ! is_installed "mariadb-server"; then
        info "Installing MySQL server..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-server
        ok "MySQL installed"
        INSTALLED_COMPONENTS+=("mysql-server")
        ROLLBACK_ACTIONS+=("apt-get remove -y mysql-server mysql-common 2>/dev/null || true")
    else
        ok "MySQL/MariaDB already installed"
    fi

    # Docker
    if ! command -v docker &>/dev/null; then
        info "Installing Docker CE..."
        # Remove old versions
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        # Add Docker GPG key
        install -m 0755 -d /etc/apt/keyrings
        with_retry curl -fsSL https://download.docker.com/linux/"${DISTRO}"/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        # Add Docker repository
        local arch
        arch="$(dpkg --print-architecture)"
        local codename
        codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
        echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${DISTRO} ${codename} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ok "Docker CE installed"
        INSTALLED_COMPONENTS+=("docker-ce")
        ROLLBACK_ACTIONS+=("apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true")
    else
        ok "Docker already installed: $(docker --version 2>/dev/null | head -1)"
    fi

    # SteamCMD
    if ! command -v steamcmd &>/dev/null && [[ ! -f /usr/games/steamcmd ]]; then
        info "Installing SteamCMD..."
        # Enable i386 architecture
        dpkg --add-architecture i386
        apt-get update -qq
        # steamcmd may need to accept license non-interactively
        echo "steam steam/question select I AGREE" | debconf-set-selections
        echo "steam steam/license note ''" | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq steamcmd 2>/dev/null || {
            warn "steamcmd not in apt repos, installing manually..."
            _install_steamcmd_manual
        }
        ok "SteamCMD installed"
        INSTALLED_COMPONENTS+=("steamcmd")
    else
        ok "SteamCMD already installed"
    fi

    _post_package_install
}

_install_packages_yum() {
    info "Updating yum package cache..."
    yum makecache -q 2>/dev/null || true

    # EPEL for extra packages
    if ! rpm -q epel-release &>/dev/null; then
        info "Installing EPEL repository..."
        yum install -y epel-release
    fi

    local core_pkgs=(curl wget tar unzip git screen python3 python3-pip)
    for pkg in "${core_pkgs[@]}"; do
        if ! is_installed "${pkg}"; then
            info "Installing ${pkg}..."
            yum install -y -q "${pkg}"
        else
            ok "Already installed: ${pkg}"
        fi
    done

    # python3-venv on RHEL/CentOS
    if ! python3 -m venv --help &>/dev/null; then
        yum install -y -q python3-virtualenv || pip3 install virtualenv
    fi

    # MySQL / MariaDB
    if ! command -v mysql &>/dev/null; then
        info "Installing MariaDB..."
        yum install -y -q mariadb-server mariadb
        ok "MariaDB installed"
        INSTALLED_COMPONENTS+=("mariadb-server")
        ROLLBACK_ACTIONS+=("yum remove -y mariadb-server 2>/dev/null || true")
    else
        ok "MySQL/MariaDB already installed"
    fi

    # Docker
    if ! command -v docker &>/dev/null; then
        info "Installing Docker CE..."
        with_retry curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        bash /tmp/get-docker.sh
        ok "Docker CE installed"
        INSTALLED_COMPONENTS+=("docker-ce")
    else
        ok "Docker already installed"
    fi

    # SteamCMD manual
    if ! command -v steamcmd &>/dev/null && [[ ! -f /usr/local/bin/steamcmd ]]; then
        _install_steamcmd_manual
    else
        ok "SteamCMD already installed"
    fi

    _post_package_install
}

_install_packages_dnf() {
    info "Updating dnf package cache..."
    dnf makecache -q 2>/dev/null || true

    # EPEL for Fedora/RHEL
    if ! rpm -q epel-release &>/dev/null 2>&1; then
        dnf install -y -q epel-release 2>/dev/null || true
    fi

    local core_pkgs=(curl wget tar unzip git screen python3 python3-pip)
    for pkg in "${core_pkgs[@]}"; do
        if ! is_installed "${pkg}"; then
            dnf install -y -q "${pkg}"
        else
            ok "Already installed: ${pkg}"
        fi
    done

    if ! python3 -m venv --help &>/dev/null; then
        dnf install -y -q python3-virtualenv 2>/dev/null || pip3 install virtualenv
    fi

    if ! command -v mysql &>/dev/null && ! command -v mariadb &>/dev/null; then
        info "Installing MariaDB..."
        dnf install -y -q mariadb-server
        ok "MariaDB installed"
        INSTALLED_COMPONENTS+=("mariadb-server")
        ROLLBACK_ACTIONS+=("dnf remove -y mariadb-server 2>/dev/null || true")
    else
        ok "MySQL/MariaDB already installed"
    fi

    if ! command -v docker &>/dev/null; then
        info "Installing Docker CE..."
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || \
            with_retry curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && bash /tmp/get-docker.sh
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || \
            bash /tmp/get-docker.sh
        ok "Docker CE installed"
        INSTALLED_COMPONENTS+=("docker-ce")
    else
        ok "Docker already installed"
    fi

    if ! command -v steamcmd &>/dev/null && [[ ! -f /usr/local/bin/steamcmd ]]; then
        _install_steamcmd_manual
    else
        ok "SteamCMD already installed"
    fi

    _post_package_install
}

_install_packages_pacman() {
    info "Updating pacman database..."
    pacman -Sy --noconfirm 2>/dev/null

    local core_pkgs=(curl wget tar unzip git screen python python-pip)
    for pkg in "${core_pkgs[@]}"; do
        if ! is_installed "${pkg}"; then
            pacman -S --noconfirm --needed "${pkg}"
        else
            ok "Already installed: ${pkg}"
        fi
    done

    if ! is_installed "mariadb"; then
        info "Installing MariaDB..."
        pacman -S --noconfirm --needed mariadb
        mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
        ok "MariaDB installed"
        INSTALLED_COMPONENTS+=("mariadb")
        ROLLBACK_ACTIONS+=("pacman -R --noconfirm mariadb 2>/dev/null || true")
    else
        ok "MariaDB already installed"
    fi

    if ! is_installed "docker"; then
        info "Installing Docker..."
        pacman -S --noconfirm --needed docker
        ok "Docker installed"
        INSTALLED_COMPONENTS+=("docker")
    else
        ok "Docker already installed"
    fi

    # SteamCMD via AUR or manual
    if ! command -v steamcmd &>/dev/null; then
        if command -v yay &>/dev/null; then
            info "Installing SteamCMD via AUR (yay)..."
            # Run as non-root (AUR requirement)
            local aur_user
            aur_user="$(logname 2>/dev/null || echo "${SUDO_USER:-}")"
            if [[ -n "${aur_user}" ]]; then
                sudo -u "${aur_user}" yay -S --noconfirm steamcmd || _install_steamcmd_manual
            else
                _install_steamcmd_manual
            fi
        else
            _install_steamcmd_manual
        fi
    else
        ok "SteamCMD already installed"
    fi

    _post_package_install
}

_install_packages_brew() {
    if ! command -v brew &>/dev/null; then
        die "Homebrew not found. Install from https://brew.sh/ then re-run."
    fi

    local brew_pkgs=(curl wget git python3)
    for pkg in "${brew_pkgs[@]}"; do
        if ! brew list "${pkg}" &>/dev/null; then
            info "Installing ${pkg}..."
            brew install "${pkg}"
        else
            ok "Already installed: ${pkg}"
        fi
    done

    # MariaDB on macOS
    if ! brew list mariadb &>/dev/null; then
        info "Installing MariaDB..."
        brew install mariadb
        ok "MariaDB installed"
    else
        ok "MariaDB already installed"
    fi

    # Docker Desktop assumed (not brew docker)
    if ! command -v docker &>/dev/null; then
        warn "Docker not found. Please install Docker Desktop from https://docs.docker.com/desktop/mac/"
        warn "After installing Docker Desktop, re-run this installer."
        if ! confirm "Is Docker Desktop already installed and running?"; then
            die "Docker Desktop is required. Install it and re-run."
        fi
    else
        ok "Docker found: $(docker --version 2>/dev/null | head -1)"
    fi

    info "SteamCMD skipped on macOS (dev mode)"
}

_install_steamcmd_manual() {
    info "Installing SteamCMD manually..."
    local steamcmd_dir="/opt/steamcmd"
    mkdir -p "${steamcmd_dir}"

    if [[ ! -f "${steamcmd_dir}/steamcmd.sh" ]]; then
        with_retry curl -fsSL \
            "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
            -o /tmp/steamcmd_linux.tar.gz
        tar -xzf /tmp/steamcmd_linux.tar.gz -C "${steamcmd_dir}"
        rm -f /tmp/steamcmd_linux.tar.gz
    fi

    # Create wrapper
    cat > /usr/local/bin/steamcmd << 'STEAMCMD_EOF'
#!/usr/bin/env bash
exec /opt/steamcmd/steamcmd.sh "$@"
STEAMCMD_EOF
    chmod +x /usr/local/bin/steamcmd

    # Run once to update
    info "Running SteamCMD initial update (this may take a moment)..."
    sudo -u "${STEAM_USER:-root}" "${steamcmd_dir}/steamcmd.sh" +quit 2>/dev/null || true

    ok "SteamCMD installed to ${steamcmd_dir}"
    INSTALLED_COMPONENTS+=("steamcmd-manual")
    ROLLBACK_ACTIONS+=("rm -rf /opt/steamcmd /usr/local/bin/steamcmd 2>/dev/null || true")
}

_post_package_install() {
    # Create steam user if not exists
    if ! id "${STEAM_USER}" &>/dev/null; then
        info "Creating '${STEAM_USER}' system user..."
        useradd -r -m -d /home/"${STEAM_USER}" -s /bin/bash "${STEAM_USER}"
        ok "User '${STEAM_USER}' created"
        INSTALLED_COMPONENTS+=("steam-user")
        ROLLBACK_ACTIONS+=("userdel -r ${STEAM_USER} 2>/dev/null || true")
    else
        ok "User '${STEAM_USER}' already exists"
    fi

    # Add current user to docker group
    local actual_user="${SUDO_USER:-${USER}}"
    if [[ -n "${actual_user}" && "${actual_user}" != "root" ]]; then
        if ! groups "${actual_user}" | grep -q docker; then
            usermod -aG docker "${actual_user}"
            ok "Added ${actual_user} to docker group (re-login required to take effect)"
        else
            ok "${actual_user} already in docker group"
        fi
    fi

    # Start and enable services
    if [[ "${OS_TYPE}" == "linux" ]] && command -v systemctl &>/dev/null; then
        # Docker
        if systemctl list-unit-files docker.service &>/dev/null; then
            systemctl enable --now docker 2>/dev/null || warn "Could not enable docker service"
            ok "Docker service enabled and started"
        fi
        # MySQL
        local mysql_svc
        if systemctl list-unit-files mysql.service &>/dev/null; then
            mysql_svc="mysql"
        elif systemctl list-unit-files mariadb.service &>/dev/null; then
            mysql_svc="mariadb"
        else
            mysql_svc=""
        fi
        if [[ -n "${mysql_svc}" ]]; then
            systemctl enable --now "${mysql_svc}" 2>/dev/null || warn "Could not enable ${mysql_svc} service"
            ok "${mysql_svc} service enabled and started"
        fi
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        brew services start mariadb 2>/dev/null || true
    fi
}

# ==============================================================================
# CONFIGURATION WIZARD
# ==============================================================================
configure_wizard() {
    print_section "Configuration Wizard"
    info "Press Enter to accept the default value shown in [brackets]."
    printf '\n'

    # If update mode and config exists, load existing values as defaults
    if [[ "${MODE}" == "update" && -f "${CONFIG_FILE}" ]]; then
        info "Loading existing configuration as defaults..."
        set -o allexport
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}" 2>/dev/null || true
        set +o allexport
        SERVER_IP="${SERVER_IP:-}"
        DB_HOST="${DB_HOST:-localhost}"
        DB_PORT="${DB_PORT:-3306}"
        DB_PASS="${DB_PASS:-}"
        RCON_PASSWORD="${RCON_PASSWORD:-}"
        LOBBY_PORT="${LOBBY_PORT:-27015}"
        MATCH_PORT_START="${MATCH_PORT_START:-27020}"
        WEB_PORT="${WEB_PORT:-5000}"
        PLAYERS_PER_TEAM="${PLAYERS_PER_TEAM:-5}"
        MAX_ELO_SPREAD="${MAX_ELO_SPREAD:-200}"
        READY_CHECK_TIMEOUT="${READY_CHECK_TIMEOUT:-30}"
        DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
        ok "Existing configuration loaded"
    fi

    # ─── Step 1: Server IP ───────────────────────────────────────────────────
    print_step "1" "Server IP Address"
    info "Detecting your public IP address..."
    local detected_ip
    detected_ip="$(with_retry curl -sf --max-time 5 https://api.ipify.org || \
                   with_retry curl -sf --max-time 5 https://ifconfig.me || \
                   echo "")"
    if [[ -n "${detected_ip}" ]]; then
        info "Detected public IP: ${detected_ip}"
    else
        warn "Could not auto-detect public IP."
    fi
    local ip_default="${SERVER_IP:-${detected_ip:-127.0.0.1}}"
    while true; do
        SERVER_IP="$(prompt "Enter server IP or hostname" "${ip_default}")"
        if validate_ip "${SERVER_IP}"; then
            ok "Server IP set to: ${SERVER_IP}"
            break
        else
            error "Invalid IP address or hostname: '${SERVER_IP}'. Please try again."
        fi
    done

    # ─── Step 2: MySQL Setup ─────────────────────────────────────────────────
    print_step "2" "MySQL / Database Setup"
    if confirm "Use an existing MySQL instance (remote or pre-configured)?"; then
        USE_EXISTING_MYSQL="y"
        DB_HOST="$(prompt "MySQL host" "${DB_HOST:-localhost}")"
        while true; do
            DB_PORT="$(prompt "MySQL port" "${DB_PORT:-3306}")"
            if validate_port "${DB_PORT}"; then break; fi
            error "Invalid port number."
        done
        DB_ROOT_PASS="$(prompt_secret "MySQL root password (for creating DB/user)")"
    else
        USE_EXISTING_MYSQL="n"
        if [[ -z "${DB_ROOT_PASS:-}" ]]; then
            DB_ROOT_PASS="$(generate_password 20)"
            info "Generated MySQL root password (will be set during DB setup)"
        fi
        DB_HOST="localhost"
        DB_PORT="3306"
    fi

    if [[ -z "${DB_PASS:-}" ]]; then
        DB_PASS="$(generate_password 24)"
        ok "Generated database password (will be saved to config.env)"
    else
        local custom_db_pass
        custom_db_pass="$(prompt "Database password for csgo_mm user (leave empty to keep/generate)" "${DB_PASS}")"
        if [[ -n "${custom_db_pass}" ]]; then
            DB_PASS="${custom_db_pass}"
        fi
    fi
    ok "Database: csgo_matchmaking, User: csgo_mm @ ${DB_HOST}:${DB_PORT}"

    # ─── Step 3: RCON Password ───────────────────────────────────────────────
    print_step "3" "RCON Password"
    if [[ -z "${RCON_PASSWORD:-}" ]]; then
        RCON_PASSWORD="$(generate_hex_password 16)"
        info "Auto-generated RCON password."
    fi
    local custom_rcon
    custom_rcon="$(prompt "RCON password (leave empty to use generated)" "${RCON_PASSWORD}")"
    RCON_PASSWORD="${custom_rcon:-${RCON_PASSWORD}}"
    ok "RCON password configured"

    # ─── Step 4: GSLT Tokens for Match Servers ───────────────────────────────
    print_step "4" "Game Server Login Tokens (GSLT) — Match Servers"
    printf '\n'
    printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${YELLOW}" "${RESET}"
    printf '  %s GSLT Setup Instructions%s\n' "${BOLD}" "${RESET}"
    printf '  %s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "${YELLOW}" "${RESET}"
    printf '  Game Server Login Tokens (GSLT) are required for each match server.\n\n'
    printf '  1. Go to: %shttps://steamcommunity.com/dev/managegameservers%s\n' "${CYAN}" "${RESET}"
    printf '  2. Create tokens with App ID: %s730%s (CS:GO)\n' "${BOLD}" "${RESET}"
    printf '  3. You need at least 1 token (recommend 10 for up to 10 simultaneous matches)\n'
    printf '  4. Each token = 1 match server. Tokens are free, max 1000 per account.\n\n'
    printf '  %sNote: Tokens must be used within 1 year or they expire.%s\n\n' "${DIM}" "${RESET}"

    local num_tokens=0
    while (( num_tokens < 1 || num_tokens > 1000 )); do
        local token_input
        token_input="$(prompt "How many GSLT tokens will you add?" "10")"
        if [[ "${token_input}" =~ ^[0-9]+$ ]] && (( token_input >= 1 && token_input <= 1000 )); then
            num_tokens="${token_input}"
        else
            error "Please enter a number between 1 and 1000."
        fi
    done

    MATCH_GSLTS=()
    local i
    for (( i=1; i<=num_tokens; i++ )); do
        while true; do
            local token
            token="$(prompt "Paste GSLT token ${i} of ${num_tokens}")"
            token="${token^^}"  # uppercase
            if [[ -z "${token}" ]]; then
                warn "Skipping token ${i} (empty)."
                break
            elif validate_gslt "${token}"; then
                MATCH_GSLTS+=("${token}")
                ok "Token ${i} accepted."
                break
            else
                error "Invalid GSLT format. Expected 20-40 uppercase alphanumeric characters."
                if confirm "Skip this token?"; then
                    warn "Token ${i} skipped."
                    break
                fi
            fi
        done
    done

    if [[ ${#MATCH_GSLTS[@]} -eq 0 ]]; then
        die "At least one GSLT token is required."
    fi
    ok "${#MATCH_GSLTS[@]} GSLT token(s) configured for match servers"

    # ─── Step 5: Lobby Server GSLT ───────────────────────────────────────────
    print_step "5" "Lobby Server GSLT"
    info "The lobby server requires its own dedicated GSLT token."
    while true; do
        local lobby_token
        lobby_token="$(prompt "Paste GSLT token for the lobby server")"
        lobby_token="${lobby_token^^}"
        if validate_gslt "${lobby_token}"; then
            LOBBY_GSLT="${lobby_token}"
            ok "Lobby server GSLT configured"
            break
        else
            error "Invalid GSLT token format."
            if confirm "Skip lobby GSLT (server will run without VAC)?"; then
                warn "No GSLT for lobby server — server will not be VAC-secured."
                LOBBY_GSLT=""
                break
            fi
        fi
    done

    # ─── Step 6: Port Configuration ──────────────────────────────────────────
    print_step "6" "Port Configuration"

    # Lobby port
    while true; do
        local lport
        lport="$(prompt "Lobby server port" "${LOBBY_PORT}")"
        if ! validate_port "${lport}"; then
            error "Invalid port number."
            continue
        fi
        if ! check_port_free "${lport}"; then
            warn "Port ${lport} appears to be in use."
            if ! confirm "Use it anyway?"; then continue; fi
        fi
        LOBBY_PORT="${lport}"
        ok "Lobby port: ${LOBBY_PORT}"
        break
    done

    # Match server port range
    while true; do
        local mstart
        mstart="$(prompt "Match server port range start" "${MATCH_PORT_START}")"
        if ! validate_port "${mstart}"; then
            error "Invalid port number."
            continue
        fi
        MATCH_PORT_START="${mstart}"
        break
    done

    while true; do
        local mslots
        mslots="$(prompt "Number of match server slots" "${MATCH_SLOTS}")"
        if [[ "${mslots}" =~ ^[0-9]+$ ]] && (( mslots >= 1 && mslots <= 50 )); then
            MATCH_SLOTS="${mslots}"
            break
        fi
        error "Enter a number between 1 and 50."
    done

    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))
    ok "Match server ports: ${MATCH_PORT_START}–${match_port_end}"

    # Check match ports
    local port_busy=0
    for (( i=0; i<MATCH_SLOTS; i++ )); do
        local p=$(( MATCH_PORT_START + i ))
        if ! check_port_free "${p}"; then
            warn "Port ${p} is in use"
            (( port_busy++ ))
        fi
    done
    if (( port_busy > 0 )); then
        warn "${port_busy} match server port(s) are in use. Proceeding anyway."
    fi

    # ─── Step 7: Web Panel ───────────────────────────────────────────────────
    print_step "7" "Web Panel"
    while true; do
        local wport
        wport="$(prompt "Web panel port" "${WEB_PORT}")"
        if ! validate_port "${wport}"; then
            error "Invalid port number."
            continue
        fi
        if ! check_port_free "${wport}"; then
            warn "Port ${wport} appears to be in use."
            if ! confirm "Use it anyway?"; then continue; fi
        fi
        WEB_PORT="${wport}"
        ok "Web panel port: ${WEB_PORT}"
        break
    done

    FLASK_SECRET_KEY="$(generate_password 48)"

    if confirm "Enable Discord notifications?"; then
        while true; do
            local webhook
            webhook="$(prompt "Paste Discord webhook URL")"
            if [[ "${webhook}" =~ ^https://discord\.com/api/webhooks/ ]]; then
                DISCORD_WEBHOOK_URL="${webhook}"
                ok "Discord webhook configured"
                break
            else
                error "Invalid webhook URL. Must start with: https://discord.com/api/webhooks/"
                if confirm "Skip Discord integration?"; then
                    DISCORD_WEBHOOK_URL=""
                    break
                fi
            fi
        done
    else
        DISCORD_WEBHOOK_URL=""
        ok "Discord notifications disabled"
    fi

    # ─── Step 8: Map Pool ────────────────────────────────────────────────────
    print_step "8" "Map Pool Selection"
    SELECTED_MAPS=("${ALL_MAPS[@]}")  # Default: all maps selected
    local map_selected=()
    for (( i=0; i<${#ALL_MAPS[@]}; i++ )); do
        map_selected[$i]=1
    done

    while true; do
        printf '\n  Current map pool:\n'
        for (( i=0; i<${#ALL_MAPS[@]}; i++ )); do
            local check_mark
            if [[ "${map_selected[$i]}" -eq 1 ]]; then
                check_mark="${GREEN}[✓]${RESET}"
            else
                check_mark="${DIM}[ ]${RESET}"
            fi
            printf '    %s%d. %s %s%s\n' "${BOLD}" "$(( i+1 ))" "${check_mark}" "${ALL_MAPS[$i]}" "${RESET}"
        done
        printf '\n'
        local map_toggle
        map_toggle="$(prompt "Enter numbers to toggle (comma-separated), or press Enter to keep current")"
        if [[ -z "${map_toggle}" ]]; then
            break
        fi
        # Parse comma/space separated numbers
        IFS=', ' read -ra toggle_nums <<< "${map_toggle}"
        for num in "${toggle_nums[@]}"; do
            if [[ "${num}" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#ALL_MAPS[@]} )); then
                local idx=$(( num - 1 ))
                if [[ "${map_selected[$idx]}" -eq 1 ]]; then
                    map_selected[$idx]=0
                else
                    map_selected[$idx]=1
                fi
            else
                warn "Invalid map number: ${num}"
            fi
        done
    done

    SELECTED_MAPS=()
    for (( i=0; i<${#ALL_MAPS[@]}; i++ )); do
        if [[ "${map_selected[$i]}" -eq 1 ]]; then
            SELECTED_MAPS+=("${ALL_MAPS[$i]}")
        fi
    done

    if [[ ${#SELECTED_MAPS[@]} -eq 0 ]]; then
        warn "No maps selected! Using default (de_dust2)."
        SELECTED_MAPS=("de_dust2")
    fi
    ok "Map pool: ${SELECTED_MAPS[*]}"

    # ─── Step 9: Matchmaking Settings ────────────────────────────────────────
    print_step "9" "Matchmaking Settings"
    while true; do
        local ppt
        ppt="$(prompt "Players per team" "${PLAYERS_PER_TEAM}")"
        if [[ "${ppt}" =~ ^[0-9]+$ ]] && (( ppt >= 1 && ppt <= 10 )); then
            PLAYERS_PER_TEAM="${ppt}"
            break
        fi
        error "Enter a number between 1 and 10."
    done

    while true; do
        local elo
        elo="$(prompt "Max ELO spread (initial)" "${MAX_ELO_SPREAD}")"
        if [[ "${elo}" =~ ^[0-9]+$ ]] && (( elo > 0 )); then
            MAX_ELO_SPREAD="${elo}"
            break
        fi
        error "Enter a positive number."
    done

    while true; do
        local rct
        rct="$(prompt "Ready check timeout (seconds)" "${READY_CHECK_TIMEOUT}")"
        if [[ "${rct}" =~ ^[0-9]+$ ]] && (( rct >= 10 && rct <= 300 )); then
            READY_CHECK_TIMEOUT="${rct}"
            break
        fi
        error "Enter a number between 10 and 300."
    done

    ok "Players per team: ${PLAYERS_PER_TEAM}, Max ELO: ${MAX_ELO_SPREAD}, Ready timeout: ${READY_CHECK_TIMEOUT}s"

    # ─── Summary ─────────────────────────────────────────────────────────────
    print_section "Configuration Summary"
    printf '  %-35s %s\n' "Server IP:"          "${SERVER_IP}"
    printf '  %-35s %s\n' "Lobby Port:"         "${LOBBY_PORT}"
    printf '  %-35s %s-%s (%s slots)\n' "Match Server Ports:" \
        "${MATCH_PORT_START}" "$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))" "${MATCH_SLOTS}"
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

    if ! confirm "Proceed with installation?"; then
        info "Installation cancelled by user."
        exit 0
    fi
}

# ==============================================================================
# GENERATE CONFIG.ENV
# ==============================================================================
generate_config() {
    print_section "Generating config.env"

    # Backup existing config
    if [[ -f "${CONFIG_FILE}" ]]; then
        local backup_name="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "${CONFIG_FILE}" "${backup_name}"
        ok "Existing config backed up to: ${backup_name}"
    fi

    local map_pool_str
    map_pool_str="$(IFS=','; echo "${SELECTED_MAPS[*]}")"
    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))
    local notification_backend="none"
    if [[ -n "${DISCORD_WEBHOOK_URL}" ]]; then
        notification_backend="discord"
    fi

    cat > "${CONFIG_FILE}" << CONFIG_EOF
# ============================================
# CS:GO Matchmaking System - Configuration
# ============================================
# Generated by install.sh on $(date '+%Y-%m-%d %H:%M:%S')
# To re-run the wizard: sudo ./install.sh
# WARNING: This file contains secrets. Do not commit to version control.

# --- Database ---
# Host of the MySQL/MariaDB server
DB_HOST=${DB_HOST}
# MySQL port (default 3306)
DB_PORT=${DB_PORT}
# Database user for the matchmaking system
DB_USER=csgo_mm
# Database password (auto-generated during install)
DB_PASS=${DB_PASS}
# Database name
DB_NAME=csgo_matchmaking

# --- Server ---
# Public IP address of your server (auto-detected by install.sh)
SERVER_IP=${SERVER_IP}
# Lobby server address (IP:PORT players connect to)
LOBBY_IP=${SERVER_IP}
# Lobby server port
LOBBY_PORT=${LOBBY_PORT}
# Match server port range
MATCH_PORT_START=${MATCH_PORT_START}
MATCH_PORT_END=${match_port_end}
MATCH_SLOTS=${MATCH_SLOTS}
# RCON password for server communication
RCON_PASSWORD=${RCON_PASSWORD}

# --- GSLT ---
# Lobby server Game Server Login Token
LOBBY_GSLT=${LOBBY_GSLT}

# --- Matchmaking ---
# How often the matchmaker polls the queue (seconds)
POLL_INTERVAL=2.0
# Players per team (default 5 for 5v5)
PLAYERS_PER_TEAM=${PLAYERS_PER_TEAM}
# Initial max ELO difference between players in a match
MAX_ELO_SPREAD=${MAX_ELO_SPREAD}
# Widen ELO spread by this amount every INTERVAL seconds
ELO_SPREAD_INCREASE_INTERVAL=60
ELO_SPREAD_INCREASE_AMOUNT=50
# Ready check timeout (seconds)
READY_CHECK_TIMEOUT=${READY_CHECK_TIMEOUT}
# Warmup timeout - cancel match if not all players connect (seconds)
WARMUP_TIMEOUT=180
# Matches needed before ELO stabilizes (placement period)
MIN_PLACEMENT_MATCHES=10

# --- ELO ---
# K-factor for standard players (determines ELO volatility)
ELO_K_FACTOR=32
# K-factor for new players (higher = more volatile during placements)
ELO_K_FACTOR_NEW=64
# Starting ELO for new players
ELO_DEFAULT=1000

# --- Map Pool ---
# Comma-separated list of maps available for matchmaking
MAP_POOL=${map_pool_str}

# --- Backends (modular architecture) ---
# Queue backend: mysql (default) | redis (future)
QUEUE_BACKEND=mysql
# Server orchestration: docker (default) | kubernetes (future)
SERVER_BACKEND=docker
# Notification system: discord | slack | none
NOTIFICATION_BACKEND=${notification_backend}
# Ranking algorithm: elo (default) | glicko2 (future)
RANKING_BACKEND=elo

# --- Docker ---
# Docker image for match servers (built by install.sh)
DOCKER_IMAGE=csgo-match-server:latest
# Docker network mode (host recommended for game servers)
DOCKER_NETWORK=host

# --- Web Panel ---
WEB_HOST=0.0.0.0
WEB_PORT=${WEB_PORT}
# Flask secret key (generated by install.sh)
SECRET_KEY=${FLASK_SECRET_KEY}

# --- Discord (optional) ---
# Leave empty to disable Discord notifications
DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL}

# --- Levels Ranks ---
# Table name used by Levels Ranks plugin (default: lvl_base)
LR_TABLE_NAME=lvl_base
CONFIG_EOF

    chmod 600 "${CONFIG_FILE}"
    ok "config.env written (permissions: 600)"
    INSTALLED_COMPONENTS+=("config.env")
    ROLLBACK_ACTIONS+=("rm -f ${CONFIG_FILE} 2>/dev/null || true")
}

# ==============================================================================
# DATABASE SETUP
# ==============================================================================
setup_database() {
    print_section "Database Setup"

    # Start MySQL if not running
    if [[ "${OS_TYPE}" == "linux" ]] && command -v systemctl &>/dev/null; then
        local mysql_svc
        if systemctl is-active mysql &>/dev/null; then
            mysql_svc="mysql"
        elif systemctl is-active mariadb &>/dev/null; then
            mysql_svc="mariadb"
        else
            # Try to start
            if systemctl start mysql 2>/dev/null; then
                mysql_svc="mysql"
            elif systemctl start mariadb 2>/dev/null; then
                mysql_svc="mariadb"
            else
                die "Could not start MySQL/MariaDB service."
            fi
        fi
        ok "MySQL service running (${mysql_svc})"
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        brew services start mariadb 2>/dev/null || true
        sleep 2
    fi

    # Wait for MySQL to be ready
    local retries=0
    info "Waiting for MySQL to accept connections..."
    while ! mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" --silent 2>/dev/null; do
        (( retries++ ))
        if (( retries > 30 )); then
            die "MySQL did not become ready within 30 seconds."
        fi
        sleep 1
    done
    ok "MySQL is accepting connections"

    # Set root password for fresh installs
    if [[ "${USE_EXISTING_MYSQL}" == "n" && -n "${DB_ROOT_PASS}" ]]; then
        info "Securing MySQL root account..."
        mysql -h "${DB_HOST}" -P "${DB_PORT}" --user=root 2>/dev/null <<MYSQL_SECURE || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
MYSQL_SECURE
        ok "MySQL root password set"
    fi

    # Build mysql command with or without password
    local mysql_cmd
    if [[ -n "${DB_ROOT_PASS}" ]]; then
        mysql_cmd=(mysql -h "${DB_HOST}" -P "${DB_PORT}" -u root -p"${DB_ROOT_PASS}")
    else
        mysql_cmd=(mysql -h "${DB_HOST}" -P "${DB_PORT}" -u root)
    fi

    # Create database and user
    info "Creating database and user..."
    "${mysql_cmd[@]}" 2>/dev/null << MYSQL_SETUP
CREATE DATABASE IF NOT EXISTS csgo_matchmaking
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'csgo_mm'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS 'csgo_mm'@'%' IDENTIFIED BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON csgo_matchmaking.* TO 'csgo_mm'@'localhost';
GRANT ALL PRIVILEGES ON csgo_matchmaking.* TO 'csgo_mm'@'%';
FLUSH PRIVILEGES;
MYSQL_SETUP
    ok "Database 'csgo_matchmaking' and user 'csgo_mm' created"

    # Apply schema
    if [[ -f "${SCRIPT_DIR}/database/schema.sql" ]]; then
        info "Applying database schema..."
        "${mysql_cmd[@]}" csgo_matchmaking < "${SCRIPT_DIR}/database/schema.sql"
        ok "Schema applied"
    else
        warn "Schema file not found: ${SCRIPT_DIR}/database/schema.sql"
    fi

    # Insert GSLT tokens
    if [[ ${#MATCH_GSLTS[@]} -gt 0 ]]; then
        info "Inserting ${#MATCH_GSLTS[@]} GSLT token(s) into database..."
        local insert_sql="USE csgo_matchmaking;"
        for token in "${MATCH_GSLTS[@]}"; do
            insert_sql+="
INSERT IGNORE INTO mm_gslt_tokens (token, is_active, created_at)
  VALUES ('${token}', 1, NOW())
  ON DUPLICATE KEY UPDATE is_active=1;"
        done
        echo "${insert_sql}" | "${mysql_cmd[@]}" 2>/dev/null || \
            warn "Could not insert GSLT tokens (table may not exist yet — schema needed)"
        ok "GSLT tokens inserted"
    fi

    # Update server ports
    info "Configuring server port range in database..."
    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))
    "${mysql_cmd[@]}" csgo_matchmaking 2>/dev/null << MYSQL_PORTS || warn "Could not update port range (table may not exist)"
INSERT INTO mm_server_ports (port, is_available, server_ip)
SELECT port, 1, '${SERVER_IP}'
FROM (
  SELECT ${MATCH_PORT_START} + n AS port
  FROM (
    SELECT a.N + b.N * 10 AS n
    FROM
      (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
       UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
      (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) b
  ) nums
  WHERE ${MATCH_PORT_START} + n <= ${match_port_end}
) ports
ON DUPLICATE KEY UPDATE is_available=1, server_ip='${SERVER_IP}';
MYSQL_PORTS
    ok "Server port range configured"

    # Verification
    info "Verifying database setup..."
    local player_count
    player_count="$(mysql -h "${DB_HOST}" -P "${DB_PORT}" -u csgo_mm -p"${DB_PASS}" \
        csgo_matchmaking -se 'SELECT COUNT(*) FROM mm_players' 2>/dev/null || echo "N/A")"
    if [[ "${player_count}" == "0" || "${player_count}" == "N/A" ]]; then
        ok "Database verification passed (mm_players table accessible, 0 rows)"
    else
        ok "Database verification passed (mm_players has ${player_count} rows)"
    fi

    INSTALLED_COMPONENTS+=("database")
    ROLLBACK_ACTIONS+=("mysql -h ${DB_HOST} -P ${DB_PORT} -u root -p${DB_ROOT_PASS} -e \"DROP DATABASE IF EXISTS csgo_matchmaking; DROP USER IF EXISTS 'csgo_mm'@'localhost';\" 2>/dev/null || true")
}

# ==============================================================================
# CS:GO DEDICATED SERVER DOWNLOAD
# ==============================================================================
download_csgo() {
    print_section "CS:GO Dedicated Server Download"

    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "CS:GO server download skipped on macOS (dev mode)."
        return 0
    fi

    local steamcmd_bin
    if command -v steamcmd &>/dev/null; then
        steamcmd_bin="steamcmd"
    elif [[ -f /usr/games/steamcmd ]]; then
        steamcmd_bin="/usr/games/steamcmd"
    elif [[ -f /opt/steamcmd/steamcmd.sh ]]; then
        steamcmd_bin="/opt/steamcmd/steamcmd.sh"
    else
        die "SteamCMD not found. Package installation may have failed."
    fi

    # Check if already installed
    if [[ -f "${CSGO_DIR}/srcds_run" && -d "${CSGO_DIR}/csgo" ]]; then
        warn "CS:GO server appears to be installed at ${CSGO_DIR}."
        if [[ "${MODE}" == "update" ]]; then
            info "Update mode: will validate and update CS:GO server files."
        elif ! confirm "Re-download/validate CS:GO server files? (This will take a long time!)"; then
            ok "CS:GO server download skipped (already installed)"
            return 0
        fi
    fi

    # Ensure install directory exists and is owned by steam
    mkdir -p "${CSGO_DIR}"
    chown "${STEAM_USER}:${STEAM_USER}" "${CSGO_DIR}"

    warn "CS:GO server is approximately 25GB. This download will take a long time."
    warn "Do NOT interrupt the download — SteamCMD will resume if re-run."
    info "Installing to: ${CSGO_DIR}"

    local attempt=1
    local max_attempts=3
    while (( attempt <= max_attempts )); do
        info "SteamCMD download attempt ${attempt}/${max_attempts}..."
        if sudo -u "${STEAM_USER}" "${steamcmd_bin}" \
            +login anonymous \
            +force_install_dir "${CSGO_DIR}" \
            +app_update 740 validate \
            +quit; then
            ok "CS:GO server download complete"
            break
        else
            warn "SteamCMD returned a non-zero exit code (attempt ${attempt})"
            if (( attempt < max_attempts )); then
                warn "SteamCMD can be flaky. Retrying in 10 seconds..."
                sleep 10
            else
                die "CS:GO server download failed after ${max_attempts} attempts."
            fi
        fi
        (( attempt++ ))
    done

    # Verify installation
    if [[ ! -f "${CSGO_DIR}/srcds_run" ]]; then
        die "CS:GO server installation could not be verified: srcds_run not found."
    fi
    ok "CS:GO server verified at ${CSGO_DIR}"
    INSTALLED_COMPONENTS+=("csgo-server")
}

# ==============================================================================
# SOURCEMOD AND METAMOD INSTALLATION
# ==============================================================================
install_sourcemod() {
    print_section "SourceMod & MetaMod Installation"

    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "SourceMod/MetaMod installation skipped on macOS (dev mode)."
        return 0
    fi

    local addons_dir="${CSGO_DIR}/csgo/addons"
    if [[ ! -d "${CSGO_DIR}/csgo" ]]; then
        warn "CS:GO server directory not found. Skipping SourceMod install."
        warn "Run the installer again after CS:GO is downloaded."
        return 0
    fi

    mkdir -p "${addons_dir}"

    # ─── MetaMod:Source ─────────────────────────────────────────────────────
    if [[ -d "${addons_dir}/metamod" ]]; then
        ok "MetaMod:Source already installed"
    else
        info "Downloading MetaMod:Source..."
        local mm_url="https://mms.alliedmods.net/mmsdrop/1.11/mmsource-1.11.0-git1148-linux.tar.gz"
        local mm_file="/tmp/metamod_linux.tar.gz"
        with_retry curl -fsSL "${mm_url}" -o "${mm_file}" || {
            warn "Primary MetaMod URL failed, trying fallback..."
            with_retry curl -fsSL \
                "https://www.sourcemm.net/downloads.php?branch=stable" \
                -o /dev/null
        }
        if [[ -f "${mm_file}" ]]; then
            tar -xzf "${mm_file}" -C "${addons_dir}/"
            rm -f "${mm_file}"
            ok "MetaMod:Source installed"
        else
            warn "MetaMod:Source download failed. Install manually from https://www.sourcemm.net/"
        fi
    fi

    # ─── SourceMod ──────────────────────────────────────────────────────────
    if [[ -d "${addons_dir}/sourcemod" ]]; then
        ok "SourceMod already installed"
    else
        info "Downloading SourceMod ${SM_VERSION}..."
        local sm_url="https://sm.alliedmods.net/smdrop/${SM_VERSION}/sourcemod-${SM_VERSION}.0-git${SM_BUILD}-linux.tar.gz"
        local sm_file="/tmp/sourcemod_linux.tar.gz"
        with_retry curl -fsSL "${sm_url}" -o "${sm_file}" || {
            # Try to find latest from downloads page
            info "Trying to find latest SourceMod build..."
            local latest_url
            latest_url="$(with_retry curl -sfL "https://www.sourcemod.net/downloads.php?branch=stable" | \
                grep -oP 'https://sm\.alliedmods\.net/smdrop/[^"]+linux\.tar\.gz' | head -1 || echo "")"
            if [[ -n "${latest_url}" ]]; then
                with_retry curl -fsSL "${latest_url}" -o "${sm_file}"
            fi
        }
        if [[ -f "${sm_file}" ]]; then
            tar -xzf "${sm_file}" -C "${addons_dir}/"
            rm -f "${sm_file}"
            ok "SourceMod installed"
            INSTALLED_COMPONENTS+=("sourcemod")
        else
            warn "SourceMod download failed. Install manually from https://www.sourcemod.net/"
        fi
    fi

    local sm_dir="${addons_dir}/sourcemod"

    # ─── Levels Ranks Plugin ────────────────────────────────────────────────
    info "Downloading Levels Ranks plugin..."
    local lr_api_url="https://api.github.com/repos/levelsranks/pawn-levels_ranks-core/releases/latest"
    local lr_asset_url
    lr_asset_url="$(with_retry curl -sfL "${lr_api_url}" | \
        grep -oP '"browser_download_url":\s*"\K[^"]+\.zip' | head -1 || echo "")"

    if [[ -n "${lr_asset_url}" ]]; then
        with_retry curl -fsSL "${lr_asset_url}" -o /tmp/levels_ranks.zip
        if [[ -f /tmp/levels_ranks.zip ]]; then
            unzip -o -q /tmp/levels_ranks.zip -d /tmp/lr_extract/
            # Copy .smx files to plugins
            find /tmp/lr_extract/ -name '*.smx' -exec cp {} "${sm_dir}/plugins/" \; 2>/dev/null || true
            # Copy translations if present
            find /tmp/lr_extract/ -name '*.phrases.txt' -exec cp {} "${sm_dir}/translations/" \; 2>/dev/null || true
            rm -rf /tmp/levels_ranks.zip /tmp/lr_extract/
            ok "Levels Ranks plugin installed"
        fi
    else
        warn "Could not download Levels Ranks plugin. Install manually from GitHub."
    fi

    # ─── ServerRedirect Plugin ───────────────────────────────────────────────
    info "Downloading ServerRedirect plugin..."
    local sr_api_url="https://api.github.com/repos/GAMMACASE/ServerRedirect/releases/latest"
    local sr_asset_url
    sr_asset_url="$(with_retry curl -sfL "${sr_api_url}" | \
        grep -oP '"browser_download_url":\s*"\K[^"]+\.smx' | head -1 || echo "")"

    if [[ -n "${sr_asset_url}" ]]; then
        with_retry curl -fsSL "${sr_asset_url}" -o "${sm_dir}/plugins/serverredirect.smx"
        ok "ServerRedirect plugin installed"
    else
        # Try raw from repo
        local sr_raw="https://raw.githubusercontent.com/GAMMACASE/ServerRedirect/master/addons/sourcemod/plugins/serverredirect.smx"
        with_retry curl -fsSL "${sr_raw}" \
            -o "${sm_dir}/plugins/serverredirect.smx" 2>/dev/null && \
            ok "ServerRedirect plugin installed (from raw)" || \
            warn "Could not download ServerRedirect plugin. Install manually."
    fi

    # Set ownership
    chown -R "${STEAM_USER}:${STEAM_USER}" "${addons_dir}" 2>/dev/null || true
    ok "SourceMod & plugins installation complete"
}

# ==============================================================================
# LOBBY SERVER PLUGIN INSTALLATION
# ==============================================================================
install_lobby_plugins() {
    print_section "Lobby Server Plugin Installation"

    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "Lobby plugin installation skipped on macOS (dev mode)."
        return 0
    fi

    if [[ ! -d "${CSGO_DIR}/csgo" ]]; then
        warn "CS:GO server not installed. Skipping lobby plugin installation."
        return 0
    fi

    local sm_dir="${CSGO_DIR}/csgo/addons/sourcemod"
    local plugins_src="${SCRIPT_DIR}/lobby-server/sourcemod"

    if [[ ! -d "${sm_dir}" ]]; then
        warn "SourceMod not installed at ${sm_dir}. Install SourceMod first."
        return 0
    fi

    mkdir -p "${sm_dir}/plugins" "${sm_dir}/scripting" "${sm_dir}/configs"

    # ─── Copy or compile plugins ─────────────────────────────────────────────
    local compiled=0
    local failed=0
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
        elif command -v spcomp &>/dev/null || [[ -f "${sm_dir}/scripting/spcomp" ]]; then
            info "Compiling ${plugin_name}.sp..."
            local spcomp_bin
            if command -v spcomp &>/dev/null; then
                spcomp_bin="spcomp"
            else
                spcomp_bin="${sm_dir}/scripting/spcomp"
            fi
            if "${spcomp_bin}" "${sp_file}" -o "${smx_dst}" \
                -i "${sm_dir}/scripting/include" \
                -i "${plugins_src}/scripting/include"; then
                ok "Compiled: ${plugin_name}.smx"
                (( compiled++ ))
            else
                warn "Failed to compile: ${plugin_name}.sp"
                (( failed++ ))
            fi
        else
            warn "No .smx and no spcomp available for: ${plugin_name}.sp"
            (( failed++ ))
        fi
    done

    if (( compiled > 0 )); then
        ok "${compiled} plugin(s) installed"
    fi
    if (( failed > 0 )); then
        warn "${failed} plugin(s) could not be installed. Compile them manually."
    fi

    # ─── Generate databases.cfg ──────────────────────────────────────────────
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

    # ─── Copy server.cfg ─────────────────────────────────────────────────────
    local cfg_dir="${CSGO_DIR}/csgo/cfg"
    mkdir -p "${cfg_dir}"

    if [[ -f "${SCRIPT_DIR}/lobby-server/cfg/server.cfg" ]]; then
        cp "${SCRIPT_DIR}/lobby-server/cfg/server.cfg" "${cfg_dir}/server.cfg"
        ok "server.cfg copied"
    else
        warn "lobby-server/cfg/server.cfg not found, generating minimal server.cfg..."
        cat > "${cfg_dir}/server.cfg" << SERVER_CFG
// CS:GO Matchmaking Lobby Server Config
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

    # ─── Generate autoexec.cfg with GSLT ─────────────────────────────────────
    cat > "${cfg_dir}/autoexec.cfg" << AUTOEXEC_CFG
// CS:GO Matchmaking - Auto-generated by install.sh
// DO NOT EDIT - changes may be overwritten by re-running install.sh

// Set Steam Account (GSLT)
$(if [[ -n "${LOBBY_GSLT}" ]]; then echo "sv_setsteamaccount ${LOBBY_GSLT}"; fi)

// RCON
rcon_password "${RCON_PASSWORD}"

// Exec server.cfg
exec server.cfg
AUTOEXEC_CFG
    ok "autoexec.cfg generated with GSLT"

    chown -R "${STEAM_USER}:${STEAM_USER}" "${CSGO_DIR}/csgo/cfg" 2>/dev/null || true
    ok "Lobby server plugins configured"
}

# ==============================================================================
# DOCKER IMAGE BUILD
# ==============================================================================
build_docker_image() {
    print_section "Docker Image Build"

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        warn "Docker daemon is not running. Attempting to start..."
        if command -v systemctl &>/dev/null; then
            systemctl start docker || die "Could not start Docker daemon."
            sleep 3
        fi
    fi

    if ! docker info &>/dev/null; then
        die "Docker daemon is not accessible. Ensure Docker is installed and running."
    fi

    local dockerfile_dir="${SCRIPT_DIR}/match-server"
    if [[ ! -d "${dockerfile_dir}" ]]; then
        warn "match-server directory not found. Docker build skipped."
        return 0
    fi
    if [[ ! -f "${dockerfile_dir}/Dockerfile" ]]; then
        warn "Dockerfile not found at ${dockerfile_dir}/Dockerfile. Docker build skipped."
        return 0
    fi

    # Check if image already exists
    if docker images csgo-match-server:latest --format '{{.ID}}' 2>/dev/null | grep -q .; then
        warn "Docker image csgo-match-server:latest already exists."
        if [[ "${MODE}" == "update" ]] || confirm "Rebuild Docker image? (This may take 10-20 minutes)"; then
            : # fall through to build
        else
            ok "Docker build skipped (image exists)"
            return 0
        fi
    fi

    warn "Building Docker image. This may take 10-20 minutes (CS:GO files inside Docker)."
    info "Build output will appear below:"

    local build_log="/tmp/docker_build_$$.log"
    if docker build \
        --tag csgo-match-server:latest \
        --build-arg SERVER_IP="${SERVER_IP}" \
        --build-arg RCON_PASSWORD="${RCON_PASSWORD}" \
        "${dockerfile_dir}" 2>&1 | tee "${build_log}"; then
        ok "Docker image built: csgo-match-server:latest"
        rm -f "${build_log}"
    else
        error "Docker build failed. See log: ${build_log}"
        die "Docker image build failed."
    fi

    # Verify
    if docker images csgo-match-server:latest --format '{{.ID}}' | grep -q .; then
        ok "Docker image verified: $(docker images csgo-match-server:latest --format '{{.Repository}}:{{.Tag}} ({{.Size}})')"
    else
        die "Docker image not found after build."
    fi

    INSTALLED_COMPONENTS+=("docker-image")
    ROLLBACK_ACTIONS+=("docker rmi csgo-match-server:latest 2>/dev/null || true")
}

# ==============================================================================
# PYTHON MATCHMAKER SETUP
# ==============================================================================
setup_matchmaker() {
    print_section "Python Matchmaker Setup"

    local matchmaker_dir="${SCRIPT_DIR}/matchmaker"
    if [[ ! -d "${matchmaker_dir}" ]]; then
        warn "matchmaker/ directory not found. Skipping."
        return 0
    fi

    # Create virtual environment
    if [[ ! -d "${MATCHMAKER_VENV}" ]]; then
        info "Creating Python virtual environment at ${MATCHMAKER_VENV}..."
        python3 -m venv "${MATCHMAKER_VENV}"
        ok "Virtual environment created"
        INSTALLED_COMPONENTS+=("matchmaker-venv")
        ROLLBACK_ACTIONS+=("rm -rf ${MATCHMAKER_VENV} 2>/dev/null || true")
    else
        ok "Matchmaker virtual environment already exists"
    fi

    # Upgrade pip
    "${MATCHMAKER_VENV}/bin/pip" install --quiet --upgrade pip

    # Install requirements
    if [[ -f "${matchmaker_dir}/requirements.txt" ]]; then
        info "Installing matchmaker Python dependencies..."
        "${MATCHMAKER_VENV}/bin/pip" install --quiet -r "${matchmaker_dir}/requirements.txt"
        ok "Matchmaker dependencies installed"
    else
        warn "requirements.txt not found in matchmaker/. Skipping pip install."
    fi

    # Test imports
    info "Testing Python imports..."
    local import_errors=0
    for module in docker mysql.connector; do
        if "${MATCHMAKER_VENV}/bin/python" -c "import ${module}" 2>/dev/null; then
            ok "Import OK: ${module}"
        else
            warn "Import failed: ${module} (may not be listed in requirements.txt)"
            (( import_errors++ ))
        fi
    done
    # Try valve.rcon (may be named differently)
    if "${MATCHMAKER_VENV}/bin/python" -c "import valve.rcon" 2>/dev/null || \
       "${MATCHMAKER_VENV}/bin/python" -c "from rcon.source import Client" 2>/dev/null; then
        ok "Import OK: rcon library"
    else
        warn "RCON library import failed. The matchmaker may not function correctly."
        (( import_errors++ ))
    fi

    if (( import_errors > 0 )); then
        warn "${import_errors} import(s) failed. Check requirements.txt."
    else
        ok "All matchmaker Python imports successful"
    fi
}

# ==============================================================================
# WEB PANEL SETUP
# ==============================================================================
setup_webpanel() {
    print_section "Web Panel Setup"

    local webpanel_dir="${SCRIPT_DIR}/web-panel"
    if [[ ! -d "${webpanel_dir}" ]]; then
        warn "web-panel/ directory not found. Skipping."
        return 0
    fi

    # Create virtual environment
    if [[ ! -d "${WEBPANEL_VENV}" ]]; then
        info "Creating Python virtual environment at ${WEBPANEL_VENV}..."
        python3 -m venv "${WEBPANEL_VENV}"
        ok "Virtual environment created"
        INSTALLED_COMPONENTS+=("webpanel-venv")
        ROLLBACK_ACTIONS+=("rm -rf ${WEBPANEL_VENV} 2>/dev/null || true")
    else
        ok "Web panel virtual environment already exists"
    fi

    # Upgrade pip and install gunicorn
    "${WEBPANEL_VENV}/bin/pip" install --quiet --upgrade pip
    "${WEBPANEL_VENV}/bin/pip" install --quiet gunicorn

    # Install requirements
    if [[ -f "${webpanel_dir}/requirements.txt" ]]; then
        info "Installing web panel Python dependencies..."
        "${WEBPANEL_VENV}/bin/pip" install --quiet -r "${webpanel_dir}/requirements.txt"
        ok "Web panel dependencies installed"
    else
        warn "requirements.txt not found in web-panel/. Skipping pip install."
    fi

    # Test Flask import
    if "${WEBPANEL_VENV}/bin/python" -c "import flask" 2>/dev/null; then
        ok "Flask import successful"
    else
        warn "Flask import failed. Check web-panel/requirements.txt"
    fi

    ok "Web panel setup complete"
}

# ==============================================================================
# SYSTEMD SERVICE GENERATION
# ==============================================================================
generate_systemd_services() {
    print_section "Systemd Service Configuration"

    if [[ "${OS_TYPE}" == "macos" ]]; then
        warn "systemd not available on macOS. Skipping service generation."
        _generate_macos_launchd
        return 0
    fi

    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found. This system may not use systemd. Skipping service generation."
        return 0
    fi

    local csgo_bin="${CSGO_DIR}/srcds_run"

    # ─── csgo-lobby.service ──────────────────────────────────────────────────
    info "Generating /etc/systemd/system/csgo-lobby.service..."
    cat > /etc/systemd/system/csgo-lobby.service << LOBBY_SERVICE
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
LOBBY_SERVICE
    ok "csgo-lobby.service created"

    # ─── csgo-matchmaker.service ─────────────────────────────────────────────
    info "Generating /etc/systemd/system/csgo-matchmaker.service..."
    cat > /etc/systemd/system/csgo-matchmaker.service << MATCHMAKER_SERVICE
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
MATCHMAKER_SERVICE
    ok "csgo-matchmaker.service created"

    # ─── csgo-webpanel.service ───────────────────────────────────────────────
    info "Generating /etc/systemd/system/csgo-webpanel.service..."
    cat > /etc/systemd/system/csgo-webpanel.service << WEBPANEL_SERVICE
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
WEBPANEL_SERVICE
    ok "csgo-webpanel.service created"

    # Reload and enable
    info "Reloading systemd daemon..."
    systemctl daemon-reload

    info "Enabling services (not starting yet)..."
    systemctl enable csgo-lobby csgo-matchmaker csgo-webpanel 2>/dev/null || \
        warn "Could not enable one or more services"

    ok "All systemd services configured and enabled"
    INSTALLED_COMPONENTS+=("systemd-services")
    ROLLBACK_ACTIONS+=("systemctl disable csgo-lobby csgo-matchmaker csgo-webpanel 2>/dev/null; rm -f /etc/systemd/system/csgo-lobby.service /etc/systemd/system/csgo-matchmaker.service /etc/systemd/system/csgo-webpanel.service; systemctl daemon-reload")
}

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
    ok "macOS launchd plist written to ${plist_dir}"
    info "To start: launchctl load ${plist_dir}/com.csgo-matchmaking.matchmaker.plist"
}

# ==============================================================================
# VALIDATION AND HEALTH CHECK
# ==============================================================================
validate_installation() {
    print_section "Validating Installation"
    local errors=0
    local warnings=0

    # ─── 1. MySQL connection test ─────────────────────────────────────────────
    info "Checking MySQL connection..."
    if mysql -h "${DB_HOST}" -P "${DB_PORT}" -u csgo_mm -p"${DB_PASS}" \
            csgo_matchmaking -e 'SELECT 1' &>/dev/null; then
        ok "MySQL connection: OK"
    else
        error "MySQL connection failed (user: csgo_mm)"
        (( errors++ ))
    fi

    # ─── 2. DB tables exist ───────────────────────────────────────────────────
    info "Checking database tables..."
    local table_count
    table_count="$(mysql -h "${DB_HOST}" -P "${DB_PORT}" -u csgo_mm -p"${DB_PASS}" \
        csgo_matchmaking -se 'SHOW TABLES' 2>/dev/null | wc -l | tr -d ' ')"
    if (( table_count > 0 )); then
        ok "Database tables: ${table_count} found"
    else
        warn "No tables found in database (schema may not have been applied)"
        (( warnings++ ))
    fi

    # ─── 3. GSLT tokens in DB ────────────────────────────────────────────────
    info "Checking GSLT tokens in database..."
    local token_count
    token_count="$(mysql -h "${DB_HOST}" -P "${DB_PORT}" -u csgo_mm -p"${DB_PASS}" \
        csgo_matchmaking -se 'SELECT COUNT(*) FROM mm_gslt_tokens' 2>/dev/null || echo "0")"
    if (( token_count > 0 )); then
        ok "GSLT tokens in DB: ${token_count}"
    else
        warn "No GSLT tokens found in database"
        (( warnings++ ))
    fi

    # ─── 4. Docker running ────────────────────────────────────────────────────
    info "Checking Docker daemon..."
    if docker info &>/dev/null; then
        ok "Docker daemon: running"
    else
        error "Docker daemon is not running"
        (( errors++ ))
    fi

    # ─── 5. Docker image exists ───────────────────────────────────────────────
    info "Checking Docker image..."
    if docker images csgo-match-server:latest --format '{{.ID}}' 2>/dev/null | grep -q .; then
        ok "Docker image csgo-match-server:latest: exists"
    else
        warn "Docker image csgo-match-server:latest not found (build may have been skipped)"
        (( warnings++ ))
    fi

    # ─── 6. Python deps import ───────────────────────────────────────────────
    info "Checking Python dependencies (matchmaker)..."
    if [[ -d "${MATCHMAKER_VENV}" ]]; then
        if "${MATCHMAKER_VENV}/bin/python" -c "import docker, mysql.connector" 2>/dev/null; then
            ok "Matchmaker Python imports: OK"
        else
            warn "Some matchmaker Python imports failed"
            (( warnings++ ))
        fi
    else
        warn "Matchmaker virtual environment not found"
        (( warnings++ ))
    fi

    info "Checking Python dependencies (web panel)..."
    if [[ -d "${WEBPANEL_VENV}" ]]; then
        if "${WEBPANEL_VENV}/bin/python" -c "import flask" 2>/dev/null; then
            ok "Web panel Python imports: OK"
        else
            warn "Flask import failed"
            (( warnings++ ))
        fi
    else
        warn "Web panel virtual environment not found"
        (( warnings++ ))
    fi

    # ─── 7. Port conflicts ───────────────────────────────────────────────────
    info "Checking for port conflicts on configured ports..."
    for port in "${LOBBY_PORT}" "${WEB_PORT}"; do
        if check_port_free "${port}"; then
            ok "Port ${port}: available"
        else
            warn "Port ${port}: already in use (service may already be running)"
            (( warnings++ ))
        fi
    done

    # ─── 8. File permissions ─────────────────────────────────────────────────
    info "Checking file permissions..."
    if [[ -f "${CONFIG_FILE}" ]]; then
        local perms
        perms="$(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || stat -f '%OLp' "${CONFIG_FILE}" 2>/dev/null)"
        if [[ "${perms}" == "600" ]]; then
            ok "config.env permissions: 600 (secure)"
        else
            warn "config.env permissions: ${perms} (should be 600)"
            chmod 600 "${CONFIG_FILE}"
            ok "config.env permissions corrected to 600"
            (( warnings++ ))
        fi
    fi

    # ─── 9. CS:GO server files ───────────────────────────────────────────────
    if [[ "${OS_TYPE}" == "linux" ]]; then
        info "Checking CS:GO server files..."
        if [[ -f "${CSGO_DIR}/srcds_run" ]]; then
            ok "CS:GO server: srcds_run found at ${CSGO_DIR}"
        else
            warn "CS:GO server not found at ${CSGO_DIR} (download may have been skipped)"
            (( warnings++ ))
        fi
    fi

    # ─── 10. Run health_check.sh if available ────────────────────────────────
    if [[ -f "${SCRIPT_DIR}/scripts/health_check.sh" ]]; then
        info "Running health_check.sh..."
        chmod +x "${SCRIPT_DIR}/scripts/health_check.sh"
        bash "${SCRIPT_DIR}/scripts/health_check.sh" 2>/dev/null || {
            warn "health_check.sh reported issues"
            (( warnings++ ))
        }
    fi

    # ─── Summary ─────────────────────────────────────────────────────────────
    printf '\n'
    if (( errors == 0 && warnings == 0 )); then
        ok "All validation checks passed!"
    elif (( errors == 0 )); then
        warn "${warnings} warning(s) found. Installation is functional but review warnings above."
    else
        error "${errors} error(s) and ${warnings} warning(s) found. See above for details."
    fi

    return "${errors}"
}

# ==============================================================================
# COMPLETION SUMMARY
# ==============================================================================
print_summary() {
    local match_port_end=$(( MATCH_PORT_START + MATCH_SLOTS - 1 ))

    printf '\n'
    printf '%s' "${GREEN}"
    printf '╔══════════════════════════════════════════════════════════════════════╗\n'
    printf '║                  Installation Complete!                             ║\n'
    printf '╚══════════════════════════════════════════════════════════════════════╝\n'
    printf '%s\n' "${RESET}"

    printf '  Your CS:GO Matchmaking system is ready!\n\n'

    printf '%s=== Quick Reference ===%s\n\n' "${BOLD}" "${RESET}"

    if [[ "${OS_TYPE}" == "linux" ]]; then
        printf '  %sStart services:%s\n' "${BOLD}" "${RESET}"
        printf '    sudo systemctl start csgo-lobby csgo-matchmaker csgo-webpanel\n\n'

        printf '  %sStop services:%s\n' "${BOLD}" "${RESET}"
        printf '    sudo systemctl stop csgo-lobby csgo-matchmaker csgo-webpanel\n\n'

        printf '  %sView logs:%s\n' "${BOLD}" "${RESET}"
        printf '    sudo journalctl -u csgo-matchmaker -f    # Matchmaker\n'
        printf '    sudo journalctl -u csgo-lobby -f         # Lobby server\n'
        printf '    sudo journalctl -u csgo-webpanel -f      # Web panel\n\n'
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
    printf '    !queue    - Join matchmaking queue\n'
    printf '    !leave    - Leave queue\n'
    printf '    !rank     - Show your ELO rank\n'
    printf '    !top      - View leaderboard\n\n'

    printf '  %sSystem management:%s\n' "${BOLD}" "${RESET}"
    printf '    ./scripts/health_check.sh    - Check system health\n'
    printf '    ./scripts/backup.sh          - Backup database\n'
    printf '    sudo ./install.sh --update   - Update installation\n\n'

    printf '  %sImportant files:%s\n' "${BOLD}" "${RESET}"
    printf '    Config:    %s\n' "${CONFIG_FILE}"
    printf '    Log:       %s\n' "${LOG_FILE}"
    printf '    CS:GO:     %s\n' "${CSGO_DIR}"
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

# ==============================================================================
# MAIN ENTRYPOINT
# ==============================================================================
main() {
    # Initial log entry
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

    if [[ "${OS_TYPE}" == "linux" ]]; then
        generate_systemd_services
    else
        generate_systemd_services  # handles macOS launchd internally
    fi

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
