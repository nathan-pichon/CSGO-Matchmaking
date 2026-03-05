#!/usr/bin/env bash
# ==============================================================================
# installer/steps/01_packages.sh — Dependency installation
# ==============================================================================
# Installs Docker, MySQL/MariaDB, SteamCMD, Python and core utilities for
# every supported Linux distribution, plus a minimal macOS (Homebrew) path.
# ==============================================================================

# is_installed <package>
# Returns 0 if the package is already installed by the current package manager.
is_installed() {
    local pkg="$1"
    case "${PKG_MANAGER}" in
        apt)    dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii' ;;
        yum|dnf) rpm -q "${pkg}" &>/dev/null ;;
        pacman) pacman -Q "${pkg}" &>/dev/null ;;
        brew)   brew list "${pkg}" &>/dev/null ;;
    esac
}

# ── Public entry point ─────────────────────────────────────────────────────────

install_packages() {
    print_section "Installing Dependencies"

    case "${PKG_MANAGER}" in
        apt)    _install_packages_apt    ;;
        yum)    _install_packages_yum    ;;
        dnf)    _install_packages_dnf    ;;
        pacman) _install_packages_pacman ;;
        brew)   _install_packages_brew   ;;
        *)      die "Unknown package manager: ${PKG_MANAGER}" ;;
    esac
}

# ── Per-distro helpers ─────────────────────────────────────────────────────────

_apt_update_if_needed() {
    local cache_file="/var/lib/apt/periodic/update-success-stamp"
    local cache_age=3600  # 1 hour
    local stamp_time
    stamp_time="$(stat -c %Y "${cache_file}" 2>/dev/null || echo 0)"
    if [[ ! -f "${cache_file}" ]] || (( $(date +%s) - stamp_time > cache_age )); then
        info "Updating apt package lists..."
        apt-get update -qq
    fi
}

_apt_install_core_pkgs() {
    local core_pkgs=(
        curl wget tar unzip git screen
        python3 python3-pip python3-venv
        gnupg2 ca-certificates lsb-release software-properties-common
    )
    local to_install=()
    for pkg in "${core_pkgs[@]}"; do
        if is_installed "${pkg}"; then ok "Already installed: ${pkg}"
        else                            to_install+=("${pkg}")
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        info "Installing core packages: ${to_install[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
        ok "Core packages installed"
    fi
}

_apt_install_mysql() {
    if is_installed "mysql-server" || is_installed "mariadb-server"; then
        ok "MySQL/MariaDB already installed"; return
    fi
    info "Installing MySQL server..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-server
    ok "MySQL installed"
    INSTALLED_COMPONENTS+=("mysql-server")
    ROLLBACK_ACTIONS+=("apt-get remove -y mysql-server mysql-common 2>/dev/null || true")
}

_apt_install_docker() {
    if command -v docker &>/dev/null; then
        ok "Docker already installed: $(docker --version 2>/dev/null | head -1)"; return
    fi
    info "Installing Docker CE..."
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    install -m 0755 -d /etc/apt/keyrings
    with_retry curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local arch codename
    arch="$(dpkg --print-architecture)"
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
}

_apt_install_steamcmd() {
    if command -v steamcmd &>/dev/null || [[ -f /usr/games/steamcmd ]]; then
        ok "SteamCMD already installed"; return
    fi
    info "Installing SteamCMD..."
    dpkg --add-architecture i386
    apt-get update -qq
    echo "steam steam/question select I AGREE" | debconf-set-selections
    echo "steam steam/license note ''"         | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq steamcmd 2>/dev/null \
        || { warn "steamcmd not in apt repos, installing manually..."; _install_steamcmd_manual; }
    ok "SteamCMD installed"
    INSTALLED_COMPONENTS+=("steamcmd")
}

_install_packages_apt() {
    _apt_update_if_needed
    _apt_install_core_pkgs
    _apt_install_mysql
    _apt_install_docker
    _apt_install_steamcmd
    _post_package_install
}

# ── yum (CentOS 7 / RHEL 7) ───────────────────────────────────────────────────

_install_packages_yum() {
    info "Updating yum package cache..."
    yum makecache -q 2>/dev/null || true

    rpm -q epel-release &>/dev/null || { info "Installing EPEL..."; yum install -y epel-release; }

    local core_pkgs=(curl wget tar unzip git screen python3 python3-pip)
    for pkg in "${core_pkgs[@]}"; do
        is_installed "${pkg}" && ok "Already installed: ${pkg}" \
            || { info "Installing ${pkg}..."; yum install -y -q "${pkg}"; }
    done

    python3 -m venv --help &>/dev/null \
        || yum install -y -q python3-virtualenv \
        || pip3 install virtualenv

    if ! command -v mysql &>/dev/null; then
        info "Installing MariaDB..."
        yum install -y -q mariadb-server mariadb
        ok "MariaDB installed"
        INSTALLED_COMPONENTS+=("mariadb-server")
        ROLLBACK_ACTIONS+=("yum remove -y mariadb-server 2>/dev/null || true")
    else
        ok "MySQL/MariaDB already installed"
    fi

    if ! command -v docker &>/dev/null; then
        info "Installing Docker CE..."
        with_retry curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        bash /tmp/get-docker.sh
        ok "Docker CE installed"
        INSTALLED_COMPONENTS+=("docker-ce")
    else
        ok "Docker already installed"
    fi

    command -v steamcmd &>/dev/null || [[ -f /usr/local/bin/steamcmd ]] \
        || _install_steamcmd_manual

    _post_package_install
}

# ── dnf (Fedora / RHEL 8-9 / CentOS Stream) ───────────────────────────────────

_install_packages_dnf() {
    info "Updating dnf package cache..."
    dnf makecache -q 2>/dev/null || true

    rpm -q epel-release &>/dev/null 2>&1 \
        || dnf install -y -q epel-release 2>/dev/null || true

    local core_pkgs=(curl wget tar unzip git screen python3 python3-pip)
    for pkg in "${core_pkgs[@]}"; do
        is_installed "${pkg}" && ok "Already installed: ${pkg}" \
            || dnf install -y -q "${pkg}"
    done

    python3 -m venv --help &>/dev/null \
        || dnf install -y -q python3-virtualenv 2>/dev/null \
        || pip3 install virtualenv

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
        dnf config-manager \
            --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
            || { with_retry curl -fsSL https://get.docker.com -o /tmp/get-docker.sh \
                 && bash /tmp/get-docker.sh; }
        dnf install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin 2>/dev/null \
            || bash /tmp/get-docker.sh
        ok "Docker CE installed"
        INSTALLED_COMPONENTS+=("docker-ce")
    else
        ok "Docker already installed"
    fi

    command -v steamcmd &>/dev/null || [[ -f /usr/local/bin/steamcmd ]] \
        || _install_steamcmd_manual

    _post_package_install
}

# ── pacman (Arch / Manjaro) ───────────────────────────────────────────────────

_install_packages_pacman() {
    info "Updating pacman database..."
    pacman -Sy --noconfirm 2>/dev/null

    local core_pkgs=(curl wget tar unzip git screen python python-pip)
    for pkg in "${core_pkgs[@]}"; do
        is_installed "${pkg}" && ok "Already installed: ${pkg}" \
            || pacman -S --noconfirm --needed "${pkg}"
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

    if ! command -v steamcmd &>/dev/null; then
        local aur_user
        aur_user="$(logname 2>/dev/null || echo "${SUDO_USER:-}")"
        if command -v yay &>/dev/null && [[ -n "${aur_user}" ]]; then
            info "Installing SteamCMD via AUR (yay)..."
            sudo -u "${aur_user}" yay -S --noconfirm steamcmd \
                || _install_steamcmd_manual
        else
            _install_steamcmd_manual
        fi
    else
        ok "SteamCMD already installed"
    fi

    _post_package_install
}

# ── Homebrew (macOS dev) ───────────────────────────────────────────────────────

_install_packages_brew() {
    command -v brew &>/dev/null \
        || die "Homebrew not found. Install from https://brew.sh/ then re-run."

    local brew_pkgs=(curl wget git python3)
    for pkg in "${brew_pkgs[@]}"; do
        brew list "${pkg}" &>/dev/null && ok "Already installed: ${pkg}" \
            || { info "Installing ${pkg}..."; brew install "${pkg}"; }
    done

    brew list mariadb &>/dev/null \
        && ok "MariaDB already installed" \
        || { info "Installing MariaDB..."; brew install mariadb; ok "MariaDB installed"; }

    if ! command -v docker &>/dev/null; then
        warn "Docker not found. Install Docker Desktop: https://docs.docker.com/desktop/mac/"
        confirm "Is Docker Desktop already installed and running?" \
            || die "Docker Desktop is required. Install it and re-run."
    else
        ok "Docker found: $(docker --version 2>/dev/null | head -1)"
    fi

    info "SteamCMD skipped on macOS (dev mode)"
}

# ── SteamCMD manual install (distro-agnostic fallback) ────────────────────────

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

    cat > /usr/local/bin/steamcmd << 'STEAMCMD_WRAPPER'
#!/usr/bin/env bash
exec /opt/steamcmd/steamcmd.sh "$@"
STEAMCMD_WRAPPER
    chmod +x /usr/local/bin/steamcmd

    info "Running SteamCMD initial self-update..."
    sudo -u "${STEAM_USER:-root}" "${steamcmd_dir}/steamcmd.sh" +quit 2>/dev/null || true

    ok "SteamCMD installed to ${steamcmd_dir}"
    INSTALLED_COMPONENTS+=("steamcmd-manual")
    ROLLBACK_ACTIONS+=("rm -rf /opt/steamcmd /usr/local/bin/steamcmd 2>/dev/null || true")
}

# ── Post-install (all distros) ────────────────────────────────────────────────

_post_package_install() {
    # Create the dedicated steam system user
    if ! id "${STEAM_USER}" &>/dev/null; then
        info "Creating '${STEAM_USER}' system user..."
        useradd -r -m -d "/home/${STEAM_USER}" -s /bin/bash "${STEAM_USER}"
        ok "User '${STEAM_USER}' created"
        INSTALLED_COMPONENTS+=("steam-user")
        ROLLBACK_ACTIONS+=("userdel -r ${STEAM_USER} 2>/dev/null || true")
    else
        ok "User '${STEAM_USER}' already exists"
    fi

    # Add the invoking user to the docker group
    local actual_user="${SUDO_USER:-${USER}}"
    if [[ -n "${actual_user}" && "${actual_user}" != "root" ]]; then
        groups "${actual_user}" | grep -q docker \
            && ok "${actual_user} already in docker group" \
            || { usermod -aG docker "${actual_user}"; ok "Added ${actual_user} to docker group (re-login required)"; }
    fi

    # Enable and start Docker + MySQL/MariaDB via systemd
    if [[ "${OS_TYPE}" == "linux" ]] && command -v systemctl &>/dev/null; then
        if systemctl list-unit-files docker.service &>/dev/null; then
            systemctl enable --now docker 2>/dev/null \
                || warn "Could not enable docker service"
            ok "Docker service enabled and started"
        fi

        local mysql_svc=""
        systemctl list-unit-files mysql.service   &>/dev/null && mysql_svc="mysql"
        systemctl list-unit-files mariadb.service &>/dev/null && mysql_svc="mariadb"
        if [[ -n "${mysql_svc}" ]]; then
            systemctl enable --now "${mysql_svc}" 2>/dev/null \
                || warn "Could not enable ${mysql_svc} service"
            ok "${mysql_svc} service enabled and started"
        fi
    elif [[ "${OS_TYPE}" == "macos" ]]; then
        brew services start mariadb 2>/dev/null || true
    fi
}
