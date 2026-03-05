#!/usr/bin/env bash
# ==============================================================================
# installer/globals.sh — Global constants and mutable runtime state
# ==============================================================================
# Sourced first by every module. All values that need to be shared across
# installer steps live here.
# ==============================================================================

# ── Installer metadata ─────────────────────────────────────────────────────────
readonly INSTALLER_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── File paths ─────────────────────────────────────────────────────────────────
readonly LOG_FILE="${SCRIPT_DIR}/install.log"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.env"
readonly CONFIG_EXAMPLE="${SCRIPT_DIR}/config.example.env"

# ── Server paths ───────────────────────────────────────────────────────────────
readonly CSGO_DIR="/opt/csgo-server"
readonly MATCHMAKER_VENV="/opt/csgo-matchmaker-venv"
readonly WEBPANEL_VENV="/opt/csgo-webpanel-venv"
readonly STEAM_USER="steam"

# ── System requirements ────────────────────────────────────────────────────────
readonly MIN_RAM_MB=4096
readonly WARN_RAM_MB=8192
readonly MIN_CPU_CORES=2
readonly MIN_DISK_GB=50
readonly REQUIRED_PORTS=(27015 27020 3306 5000)

# ── Third-party versions ───────────────────────────────────────────────────────
readonly SM_VERSION="1.11"
readonly SM_BUILD="7152"
readonly MM_VERSION="1.12"

# ── Available maps ─────────────────────────────────────────────────────────────
readonly ALL_MAPS=(
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

# ── Runtime state (mutable, populated during execution) ───────────────────────
OS_TYPE=""
DISTRO=""
PKG_MANAGER=""
VERSION_ID=""
INSTALLED_COMPONENTS=()
ROLLBACK_ACTIONS=()
MODE="install"

# ── Configuration values (set by the wizard) ──────────────────────────────────
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
