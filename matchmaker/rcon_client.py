"""
Thin RCON client wrapper for the CS:GO matchmaking daemon.

Wraps the ``valve.rcon`` module from python-valve to provide a simple,
fault-tolerant API for executing remote console commands on CS:GO game
servers.  All methods catch connection and authentication errors and log a
warning rather than propagating exceptions, so a non-responsive server never
crashes the daemon.
"""

from __future__ import annotations

import logging
import socket
import time
from typing import Optional

logger = logging.getLogger(__name__)

# Default RCON command timeout in seconds.
_DEFAULT_TIMEOUT = 5

# Retry configuration for transient connection failures.
_RETRY_ATTEMPTS = 3      # total attempts (1 initial + 2 retries)
_RETRY_BASE_DELAY = 1.0  # seconds; doubles on each retry: 1 s, 2 s


class RCONClient:
    """Fault-tolerant RCON command executor.

    All public methods gracefully handle the following failure modes:

    - Connection refused (server not yet ready or port mismatch).
    - Socket timeout (server overloaded or firewall drop).
    - Wrong RCON password (``valve.rcon`` raises ``WrongPassword``).
    - Any unexpected exception from the underlying library.

    Example::

        client = RCONClient()
        response = client.execute("192.168.1.10", 27015, "secret", "status")
    """

    def __init__(self, timeout: int = _DEFAULT_TIMEOUT) -> None:
        """Initialise the RCON client.

        Args:
            timeout: Socket timeout in seconds for each RCON request.
        """
        self._timeout = timeout

    # ---------------------------------------------------------------------- #
    # Public API
    # ---------------------------------------------------------------------- #

    def execute(
        self,
        host: str,
        port: int,
        password: str,
        command: str,
    ) -> str:
        """Send an RCON command and return the server response.

        Retries up to ``_RETRY_ATTEMPTS`` times on transient failures
        (socket timeout, connection refused) with exponential back-off.
        Permanent errors (wrong password, import error) are not retried.

        Args:
            host: IP address or hostname of the game server.
            port: RCON port (same as game port for SRCDS).
            password: RCON password.
            command: Console command string to execute.

        Returns:
            The response string from the server, or an empty string on
            failure.
        """
        try:
            # Import here to allow the module to load even if python-valve
            # is not installed (tests can mock this import).
            import valve.rcon  # type: ignore[import]
        except ImportError:
            logger.error("python-valve is not installed; RCON is unavailable")
            return ""

        for attempt in range(1, _RETRY_ATTEMPTS + 1):
            try:
                with valve.rcon.RCON((host, port), password, timeout=self._timeout) as rcon:
                    response: str = rcon.execute(command).text
                    logger.debug(
                        "RCON %s:%d cmd=%r response_len=%d (attempt %d)",
                        host, port, command, len(response), attempt,
                    )
                    return response

            except (socket.timeout, ConnectionRefusedError) as exc:
                exc_label = "timeout" if isinstance(exc, socket.timeout) else "refused"
                if attempt < _RETRY_ATTEMPTS:
                    delay = _RETRY_BASE_DELAY * (2 ** (attempt - 1))
                    logger.warning(
                        "RCON %s:%d %s (cmd=%r) — retrying in %.1fs "
                        "(attempt %d/%d)",
                        host, port, exc_label, command, delay,
                        attempt, _RETRY_ATTEMPTS,
                    )
                    time.sleep(delay)
                else:
                    logger.warning(
                        "RCON %s:%d %s after %d attempts (cmd=%r)",
                        host, port, exc_label, _RETRY_ATTEMPTS, command,
                    )
                    return ""

            except OSError as exc:
                logger.warning(
                    "RCON %s:%d OS error: %s (cmd=%r)", host, port, exc, command
                )
                return ""

            except Exception as exc:
                # Catches valve.rcon.RCONCommunicationError, WrongPassword, etc.
                # Not retried — these are permanent or logic errors.
                exc_type = type(exc).__name__
                logger.warning(
                    "RCON %s:%d %s: %s (cmd=%r)", host, port, exc_type, exc, command
                )
                return ""

        return ""  # unreachable but keeps type-checker happy

    def say(
        self,
        host: str,
        port: int,
        password: str,
        message: str,
    ) -> None:
        """Send a chat message to all players via ``sm_say``.

        Wraps *message* in the SourceMod ``sm_say`` command so it appears in
        the in-game chat as a server message.

        Args:
            host: IP address or hostname of the game server.
            port: RCON port.
            password: RCON password.
            message: The text to display in-game (should be kept short).
        """
        # Sanitise the message – strip newlines to avoid command injection.
        safe_message = message.replace("\n", " ").replace("\r", "")
        self.execute(host, port, password, f'sm_say {safe_message}')

    def kick_all(
        self,
        host: str,
        port: int,
        password: str,
    ) -> None:
        """Kick all currently connected players from the server.

        Uses the SRCDS ``kickall`` command.  This is typically called just
        before a server container is destroyed to cleanly disconnect players.

        Args:
            host: IP address or hostname of the game server.
            port: RCON port.
            password: RCON password.
        """
        logger.info("RCON kick_all: %s:%d", host, port)
        self.execute(host, port, password, "kickall Matchmaking server shutting down")
