"""
Abstract base class for the notification backend.

Concrete implementations (e.g. Discord, Slack, no-op) must subclass
:class:`NotificationBackend` and implement every abstract method.
All methods must be safe to call even when the underlying service is
unavailable – they should log a warning and return, never raise.
"""

from __future__ import annotations

from abc import ABC, abstractmethod


class NotificationBackend(ABC):
    """Interface for sending matchmaking event notifications."""

    @abstractmethod
    def notify_match_found(
        self,
        match_id: int,
        map_name: str,
        team1: list[dict],
        team2: list[dict],
    ) -> None:
        """Notify that a new match has been created and a server is starting.

        Args:
            match_id: Database ID of the match.
            map_name: The map that will be played.
            team1: List of player dicts (keys: ``steam_id``, ``elo``,
                ``rank_tier``) for team 1.
            team2: Same structure for team 2.
        """

    @abstractmethod
    def notify_match_result(
        self,
        match_id: int,
        winner: str,
        team1_score: int,
        team2_score: int,
        top_player: dict,
        player_stats: list[dict] | None = None,
        elo_changes: dict[str, int] | None = None,
    ) -> None:
        """Notify that a match has ended with its final result.

        Args:
            match_id: Database ID of the match.
            winner: Which side won: ``'team1'``, ``'team2'``, or ``'tie'``.
            team1_score: Rounds won by team 1.
            team2_score: Rounds won by team 2.
            top_player: Stat dict for the player with the most kills (keys:
                ``steam_id``, ``kills``, ``deaths``, ``assists``,
                ``elo_change``).
            player_stats: Optional list of all player stat dicts (each with
                a ``team`` key) for full per-team scoreboards.
            elo_changes: Optional mapping of steam_id → ELO delta.
        """

    @abstractmethod
    def notify_rank_up(
        self,
        steam_id: str,
        name: str,
        old_tier: int,
        new_tier: int,
    ) -> None:
        """Notify that a player has crossed a rank-tier boundary upward.

        Args:
            steam_id: Player's legacy Steam ID.
            name: Player display name.
            old_tier: Previous rank tier index.
            new_tier: New (higher) rank tier index.
        """

    @abstractmethod
    def notify_system_error(self, error_msg: str) -> None:
        """Notify operators of a critical system error.

        This should be a high-visibility alert (e.g. @here mention on
        Discord).  The implementation must never raise even if the
        notification service is down.

        Args:
            error_msg: Human-readable description of the error.
        """
