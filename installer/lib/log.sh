#!/usr/bin/env bash
# ==============================================================================
# installer/lib/log.sh — Logging initialisation
# ==============================================================================
# Must be sourced after globals.sh (needs LOG_FILE).
# Redirects stdout/stderr through `tee` so every line is also written to the
# log file, then exposes log_raw() for explicit timestamped entries.
# ==============================================================================

# Tee all stdout/stderr to the log file for the entire process lifetime.
exec 1> >(tee -a "${LOG_FILE}") 2>&1

# log_raw <message>
# Write a timestamped line directly to the log file (bypasses tee).
log_raw() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}
