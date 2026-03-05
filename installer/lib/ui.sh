#!/usr/bin/env bash
# ==============================================================================
# installer/lib/ui.sh — Terminal colours and display helpers
# ==============================================================================
# Provides: colour variables, print_header, print_section, print_step,
#           ok, warn, error, info, die.
# Colours are disabled automatically when stdout is not a TTY.
# ==============================================================================

# ── Colour setup ───────────────────────────────────────────────────────────────
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
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" MAGENTA="" BOLD="" DIM="" RESET=""
fi

# ── Page-level headers ─────────────────────────────────────────────────────────

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
    printf '%s%sDISCLAIMER:%s You must have valid Valve GSLTs and accept Valve'"'"'s\n' \
        "${BOLD}" "${YELLOW}" "${RESET}"
    printf '          Steam Subscriber Agreement before proceeding.\n'
    printf '          See: https://store.steampowered.com/subscriber_agreement/\n\n'
}

# print_section <title>
# Draws a full-width separator with the section title centred.
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

# print_step <number> <title>
print_step() {
    local num="$1"
    local title="$2"
    printf '\n%s[Step %s]%s %s%s%s\n' \
        "${BOLD}${MAGENTA}" "${num}" "${RESET}" "${BOLD}" "${title}" "${RESET}"
}

# ── Per-line status printers ───────────────────────────────────────────────────

ok()    { printf '  %s✓%s %s\n' "${GREEN}"  "${RESET}" "$*"; log_raw "OK:    $*"; }
warn()  { printf '  %s⚠%s  %s\n' "${YELLOW}" "${RESET}" "$*"; log_raw "WARN:  $*"; }
error() { printf '  %s✗%s  %s\n' "${RED}"    "${RESET}" "$*" >&2; log_raw "ERROR: $*"; }
info()  { printf '  %s→%s  %s\n' "${CYAN}"   "${RESET}" "$*"; log_raw "INFO:  $*"; }

# die <message>
# Print a fatal error message and exit with code 1.
die() {
    error "$*"
    printf '\n%sFatal error. Check %s for details.%s\n' \
        "${RED}" "${LOG_FILE}" "${RESET}" >&2
    exit 1
}
