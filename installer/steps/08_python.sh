#!/usr/bin/env bash
# ==============================================================================
# installer/steps/08_python.sh — Python virtual environments
# ==============================================================================
# Sets up isolated venvs for the matchmaker daemon and the Flask web panel,
# installs dependencies from their respective requirements.txt files, and
# performs a smoke-test of the critical imports.
# ==============================================================================

setup_matchmaker() {
    print_section "Python Matchmaker Setup"
    _python_setup_venv \
        "${SCRIPT_DIR}/matchmaker" \
        "${MATCHMAKER_VENV}" \
        "matchmaker-venv"
    _python_check_imports "${MATCHMAKER_VENV}" docker mysql.connector
    _python_check_rcon_import "${MATCHMAKER_VENV}"
}

setup_webpanel() {
    print_section "Web Panel Setup"
    _python_setup_venv \
        "${SCRIPT_DIR}/web-panel" \
        "${WEBPANEL_VENV}" \
        "webpanel-venv"
    # gunicorn is not in requirements.txt but is always needed as the WSGI server
    "${WEBPANEL_VENV}/bin/pip" install --quiet gunicorn
    _python_check_imports "${WEBPANEL_VENV}" flask
    ok "Web panel setup complete"
}

# ── Private helpers ────────────────────────────────────────────────────────────

# _python_setup_venv <app_dir> <venv_path> <component_name>
_python_setup_venv() {
    local app_dir="$1" venv_path="$2" component="$3"

    if [[ ! -d "${app_dir}" ]]; then
        warn "${app_dir} not found — skipping."
        return 0
    fi

    if [[ ! -d "${venv_path}" ]]; then
        info "Creating Python virtual environment at ${venv_path}..."
        python3 -m venv "${venv_path}"
        ok "Virtual environment created"
        INSTALLED_COMPONENTS+=("${component}")
        ROLLBACK_ACTIONS+=("rm -rf ${venv_path} 2>/dev/null || true")
    else
        ok "Virtual environment already exists: ${venv_path}"
    fi

    "${venv_path}/bin/pip" install --quiet --upgrade pip

    # Prefer the pinned lockfile for reproducible installs; fall back to requirements.txt.
    local req_lock="${app_dir}/requirements-lock.txt"
    local req_file="${app_dir}/requirements.txt"
    local install_from

    if [[ -f "${req_lock}" ]]; then
        install_from="${req_lock}"
        info "Installing pinned dependencies from ${req_lock}..."
    elif [[ -f "${req_file}" ]]; then
        install_from="${req_file}"
        warn "No requirements-lock.txt found — installing from requirements.txt (versions may float)."
    else
        warn "No requirements file found in ${app_dir}/ — skipping pip install."
        return 0
    fi

    "${venv_path}/bin/pip" install --quiet -r "${install_from}"
    ok "Dependencies installed from $(basename "${install_from}")"
}

# _python_check_imports <venv_path> <module> [<module>...]
_python_check_imports() {
    local venv_path="$1"; shift
    local import_errors=0
    for module in "$@"; do
        if "${venv_path}/bin/python" -c "import ${module}" 2>/dev/null; then
            ok "Import OK: ${module}"
        else
            warn "Import failed: ${module} (may not be in requirements.txt)"
            (( import_errors++ ))
        fi
    done
    (( import_errors == 0 )) \
        || warn "${import_errors} import(s) failed — check requirements.txt."
}

# Check the RCON library (name varies between packages)
_python_check_rcon_import() {
    local venv_path="$1"
    if   "${venv_path}/bin/python" -c "import valve.rcon"              2>/dev/null \
      || "${venv_path}/bin/python" -c "from rcon.source import Client" 2>/dev/null; then
        ok "Import OK: rcon library"
    else
        warn "RCON library import failed — matchmaker may not communicate with servers."
    fi
}
