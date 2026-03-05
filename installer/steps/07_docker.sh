#!/usr/bin/env bash
# ==============================================================================
# installer/steps/07_docker.sh — Docker match-server image build
# ==============================================================================

build_docker_image() {
    print_section "Docker Image Build"

    _docker_ensure_daemon_running
    _docker_ensure_dockerfile_exists || return 0
    _docker_build_or_skip

    INSTALLED_COMPONENTS+=("docker-image")
    ROLLBACK_ACTIONS+=("docker rmi csgo-match-server:latest 2>/dev/null || true")
}

# ── Private helpers ────────────────────────────────────────────────────────────

_docker_ensure_daemon_running() {
    docker info &>/dev/null && return 0
    warn "Docker daemon is not running — attempting to start..."
    command -v systemctl &>/dev/null \
        && { systemctl start docker || die "Could not start Docker daemon."; sleep 3; }
    docker info &>/dev/null \
        || die "Docker daemon is not accessible. Ensure Docker is installed and running."
}

_docker_ensure_dockerfile_exists() {
    local dockerfile_dir="${SCRIPT_DIR}/match-server"
    if [[ ! -d "${dockerfile_dir}" ]]; then
        warn "match-server/ directory not found — Docker build skipped."
        return 1
    fi
    if [[ ! -f "${dockerfile_dir}/Dockerfile" ]]; then
        warn "Dockerfile not found at ${dockerfile_dir}/Dockerfile — Docker build skipped."
        return 1
    fi
    return 0
}

_docker_build_or_skip() {
    local dockerfile_dir="${SCRIPT_DIR}/match-server"

    if docker images csgo-match-server:latest --format '{{.ID}}' 2>/dev/null | grep -q .; then
        warn "Docker image csgo-match-server:latest already exists."
        if [[ "${MODE}" != "update" ]] \
                && ! confirm "Rebuild Docker image? (This may take 10–20 minutes)"; then
            ok "Docker build skipped (image exists)"
            return 0
        fi
    fi

    warn "Building Docker image — this may take 10–20 minutes (CS:GO files are bundled inside)."
    info "Build output will appear below:"

    local build_log="/tmp/docker_build_$$.log"
    docker build \
        --tag csgo-match-server:latest \
        --build-arg SERVER_IP="${SERVER_IP}" \
        --build-arg RCON_PASSWORD="${RCON_PASSWORD}" \
        "${dockerfile_dir}" 2>&1 | tee "${build_log}" \
    && rm -f "${build_log}" \
    || { error "Docker build failed. See log: ${build_log}"; die "Docker image build failed."; }

    docker images csgo-match-server:latest --format '{{.ID}}' | grep -q . \
        || die "Docker image not found after build."
    ok "Docker image built: $(docker images csgo-match-server:latest \
        --format '{{.Repository}}:{{.Tag}} ({{.Size}})')"
}
