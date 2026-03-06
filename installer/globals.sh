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

# ── Third-party versions & checksums ──────────────────────────────────────────
readonly SM_VERSION="1.11"
readonly SM_BUILD="6970"   # git6970 — latest available 1.11 build on AlliedMods CDN
readonly MM_VERSION="1.11" # MetaMod version matches SourceMod branch

# SHA256 checksums for downloaded archives (verified at install time)
readonly MM_SHA256="977607008ec94dd5fff6e5bc351fcf1610e2e9852ac61268fc798a6a1d282a2d"
readonly SM_SHA256="075ebcd0e8aa7192b83ac2e21a645638261fb1bc6882ec12f8736ac6aca7c29a7"

# Vendored third-party SourceMod plugin versions (binaries committed in vendor/)
readonly LR_VERSION="3.1.6"  # Levels Ranks Core — https://github.com/levelsranks/pawn-levels_ranks-core
readonly SR_VERSION="1.3.1"  # ServerRedirect    — https://github.com/GAMMACASE/ServerRedirect
readonly LR_SHA256="a17155442448f5ff757a50677bb7035c7ab6badf542680293ef858669eaeaa7c"
readonly SR_SHA256="8947e3028ae2762a580044ce5412c5d8201f005ff4702b65e5dd8065a5054839"

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
ADMIN_TOKEN=""
SELECTED_MAPS=()
USE_EXISTING_MYSQL="n"
