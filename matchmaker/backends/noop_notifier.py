"""
No-op notification backend.

Used when ``NOTIFICATION_BACKEND`` is set to ``'none'`` / ``'noop'``.
All methods are silent no-ops suitable for testing or environments where
notifications are not desired.
"""

from __future__ import annotations

import logging

from matchmaker.interfaces.notification import NotificationBackend

logger = logging.getLogger(__name__)


class NoopNotifier(NotificationBackend):
    """Notification backend that discards all messages silently."""

    def notify_match_found(
        self,
        match_id: int,
        map_name: str,
        team1: list[dict],
        team2: list[dict],
    ) -> None:
        """No-op implementation."""
        logger.debug("NoopNotifier.notify_match_found: match_id=%d", match_id)

    def notify_match_result(
        self,
        match_id: int,
        winner: str,
        team1_score: int,
        team2_score: int,
        top_player: dict,
    ) -> None:
        """No-op implementation."""
        logger.debug("NoopNotifier.notify_match_result: match_id=%d", match_id)

    def notify_rank_up(
        self,
        steam_id: str,
        name: str,
        old_tier: int,
        new_tier: int,
    ) -> None:
        """No-op implementation."""
        logger.debug("NoopNotifier.notify_rank_up: player=%s", steam_id)

    def notify_system_error(self, error_msg: str) -> None:
        """No-op implementation."""
        logger.debug("NoopNotifier.notify_system_error: %s", error_msg)
