"""
Utility functions for the CS:GO matchmaking daemon.

Provides logging setup, password generation, Steam ID conversion helpers,
and human-readable duration formatting.
"""

from __future__ import annotations

import logging
import re
import secrets
import string


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging(level: str = "INFO") -> None:
    """Configure structured logging with timestamps for the entire application.

    Sets up the root logger with a ``StreamHandler`` using a standardised
    format that includes timestamp, log level, logger name, and message.
    Calling this function more than once is safe – existing handlers are
    replaced.

    Args:
        level: Logging level name (``'DEBUG'``, ``'INFO'``, ``'WARNING'``,
               ``'ERROR'``, ``'CRITICAL'``).  Case-insensitive.
    """
    numeric_level = getattr(logging, level.upper(), logging.INFO)

    fmt = "%(asctime)s [%(levelname)-8s] %(name)s: %(message)s"
    datefmt = "%Y-%m-%d %H:%M:%S"

    # Remove existing handlers to avoid duplicate output when called multiple
    # times (e.g. in tests).
    root = logging.getLogger()
    for handler in root.handlers[:]:
        root.removeHandler(handler)

    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter(fmt=fmt, datefmt=datefmt))

    root.setLevel(numeric_level)
    root.addHandler(handler)

    # Quieten very verbose third-party libraries.
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("docker").setLevel(logging.WARNING)
    logging.getLogger("mysql.connector").setLevel(logging.WARNING)


# ---------------------------------------------------------------------------
# Password generation
# ---------------------------------------------------------------------------

_PASSWORD_CHARS = string.ascii_letters + string.digits


def generate_password(length: int = 12) -> str:
    """Generate a cryptographically secure random alphanumeric password.

    Args:
        length: Number of characters in the password.  Minimum 8.

    Returns:
        A random string of *length* alphanumeric characters.
    """
    length = max(length, 8)
    return "".join(secrets.choice(_PASSWORD_CHARS) for _ in range(length))


# ---------------------------------------------------------------------------
# Steam ID conversion
# ---------------------------------------------------------------------------

# Steam universe/instance base offset for public accounts.
_STEAM64_BASE = 76561197960265728

# Regex for legacy Steam ID format: STEAM_X:Y:Z
_STEAM_ID_RE = re.compile(
    r"^STEAM_([0-9]):([01]):([0-9]+)$",
    re.IGNORECASE,
)


def steam_id_to_steam64(steam_id: str) -> int:
    """Convert a legacy Steam ID string to a 64-bit Steam ID.

    Handles both ``STEAM_0:Y:Z`` and ``STEAM_1:Y:Z`` formats (treating the
    universe ID as 0 for the conversion, which is the Valve convention for
    public matchmaking).

    Args:
        steam_id: Legacy Steam ID string, e.g. ``STEAM_0:1:12345``.

    Returns:
        64-bit Steam ID integer.

    Raises:
        ValueError: If *steam_id* does not match the expected format.

    Example::

        >>> steam_id_to_steam64("STEAM_0:1:12345")
        76561197960291482
    """
    match = _STEAM_ID_RE.match(steam_id.strip())
    if not match:
        raise ValueError(f"Invalid Steam ID format: {steam_id!r}")

    # W = universe (ignore for public accounts), Y = auth bit, Z = account ID
    _w = int(match.group(1))  # noqa: F841 (unused but captured for clarity)
    y = int(match.group(2))
    z = int(match.group(3))

    return _STEAM64_BASE + z * 2 + y


def steam64_to_steam_id(steam64: int) -> str:
    """Convert a 64-bit Steam ID to a legacy Steam ID string.

    Args:
        steam64: 64-bit Steam ID integer.

    Returns:
        Legacy Steam ID string in ``STEAM_0:Y:Z`` format.

    Raises:
        ValueError: If *steam64* is below the valid Steam64 base value.

    Example::

        >>> steam64_to_steam_id(76561197960291482)
        'STEAM_0:1:12345'
    """
    if steam64 < _STEAM64_BASE:
        raise ValueError(
            f"steam64 value {steam64} is below the Steam64 base ({_STEAM64_BASE})"
        )

    account_id = steam64 - _STEAM64_BASE
    y = account_id % 2          # auth bit
    z = account_id // 2         # account number
    return f"STEAM_0:{y}:{z}"


# ---------------------------------------------------------------------------
# Duration formatting
# ---------------------------------------------------------------------------

def format_duration(seconds: int | float) -> str:
    """Format a duration in seconds to a human-readable string.

    Args:
        seconds: Duration in seconds (floats are truncated to integers).

    Returns:
        Human-readable string, e.g. ``'1h 23m 45s'``, ``'5m 0s'``,
        ``'30s'``.

    Example::

        >>> format_duration(5025)
        '1h 23m 45s'
        >>> format_duration(300)
        '5m 0s'
        >>> format_duration(45)
        '45s'
    """
    total = int(seconds)
    if total < 0:
        total = 0

    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)

    if hours:
        return f"{hours}h {minutes}m {secs}s"
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{secs}s"
