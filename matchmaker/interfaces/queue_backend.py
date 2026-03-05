"""
Abstract base class for the matchmaking queue backend.

Any concrete implementation (e.g. MySQL, Redis) must subclass
:class:`QueueBackend` and implement every abstract method.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Optional

from matchmaker.models import MatchGroup, QueueEntry


class QueueBackend(ABC):
    """Interface for managing the matchmaking queue."""

    # ---------------------------------------------------------------------- #
    # Queue entry lifecycle
    # ---------------------------------------------------------------------- #

    @abstractmethod
    def add_to_queue(
        self,
        steam_id: str,
        elo: int,
        rank_tier: int,
        map_preference: Optional[str] = None,
    ) -> bool:
        """Add a player to the waiting queue.

        Args:
            steam_id: The player's legacy Steam ID string.
            elo: Current ELO rating at queue time.
            rank_tier: Current rank tier (0-17) at queue time.
            map_preference: Optional preferred map name.

        Returns:
            True if the player was successfully added, False if they were
            already in the queue or the operation failed.
        """

    @abstractmethod
    def remove_from_queue(self, steam_id: str) -> bool:
        """Remove a player from the queue regardless of their current status.

        Args:
            steam_id: The player's legacy Steam ID string.

        Returns:
            True if the row was deleted, False if the player was not in the
            queue or the operation failed.
        """

    @abstractmethod
    def get_waiting_entries(self) -> list[QueueEntry]:
        """Return all queue entries with ``status='waiting'``.

        Returns:
            Ordered list of :class:`~matchmaker.models.QueueEntry` objects,
            oldest first.
        """

    # ---------------------------------------------------------------------- #
    # Ready-check lifecycle
    # ---------------------------------------------------------------------- #

    @abstractmethod
    def set_ready_check(
        self,
        steam_ids: list[str],
        match_id: int,
    ) -> bool:
        """Transition the given players into the ready-check phase.

        Sets ``status='ready_check'`` and ``match_id`` for all *steam_ids*.

        Args:
            steam_ids: List of legacy Steam ID strings to update.
            match_id: The tentative match ID these players are grouped under.

        Returns:
            True if all rows were updated, False on partial update or failure.
        """

    @abstractmethod
    def get_ready_check_entries(self, match_id: int) -> list[QueueEntry]:
        """Return all queue entries currently in a ready check for *match_id*.

        Args:
            match_id: The match ID to look up.

        Returns:
            List of :class:`~matchmaker.models.QueueEntry` objects.
        """

    @abstractmethod
    def set_player_ready(self, steam_id: str) -> bool:
        """Mark a single player as ready (``ready=1``).

        Args:
            steam_id: The player's legacy Steam ID string.

        Returns:
            True if the row was updated, False if the player was not found or
            not in a ready-check state.
        """

    # ---------------------------------------------------------------------- #
    # Match transition
    # ---------------------------------------------------------------------- #

    @abstractmethod
    def set_matched(self, match_id: int) -> bool:
        """Move all players in *match_id*'s ready check to ``status='matched'``.

        Args:
            match_id: The match ID whose ready-check entries should be updated.

        Returns:
            True on success, False on failure.
        """

    @abstractmethod
    def cancel_match_queue(
        self,
        match_id: int,
        requeue: bool = True,
    ) -> bool:
        """Cancel the ready check for a match and optionally re-queue players.

        Args:
            match_id: The match ID to cancel.
            requeue: When True, players who had ``ready=1`` are returned to
                ``status='waiting'``; those who did not ready are marked
                ``status='cancelled'``.

        Returns:
            True on success, False on failure.
        """

    # ---------------------------------------------------------------------- #
    # Expiry / cleanup
    # ---------------------------------------------------------------------- #

    @abstractmethod
    def expire_stale_entries(self, max_wait_minutes: int = 15) -> int:
        """Mark queue entries older than *max_wait_minutes* as expired.

        Only entries with ``status='waiting'`` are eligible.

        Args:
            max_wait_minutes: Maximum age in minutes before expiry.

        Returns:
            Number of entries that were expired.
        """

    @abstractmethod
    def expire_stale_ready_checks(self, timeout_seconds: int = 30) -> int:
        """Expire ready checks that have not been fully confirmed in time.

        Any ready-check group (identified by ``match_id``) where at least one
        player has not set ``ready=1`` and the group is older than
        *timeout_seconds* will be cancelled.  Players who were ready are
        re-queued; those who were not are marked cancelled.

        Args:
            timeout_seconds: Maximum age in seconds before expiry.

        Returns:
            Number of ready-check groups that were expired.
        """

    # ---------------------------------------------------------------------- #
    # Match formation
    # ---------------------------------------------------------------------- #

    @abstractmethod
    def find_balanced_match(self) -> Optional[MatchGroup]:
        """Attempt to form one balanced 10-player match from the current queue.

        Uses a snake-draft algorithm to balance teams by ELO.  The ELO spread
        window expands dynamically based on how long players have been waiting.

        Returns:
            A :class:`~matchmaker.models.MatchGroup` if a valid group was
            found, or ``None`` if there are not enough compatible players.
        """
