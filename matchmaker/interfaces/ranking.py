"""
Abstract base class for the ranking / ELO backend.

Concrete implementations must subclass :class:`RankingBackend` and implement
every abstract method.
"""

from __future__ import annotations

from abc import ABC, abstractmethod


class RankingBackend(ABC):
    """Interface for computing ELO changes and rank tiers."""

    @abstractmethod
    def calculate_match_results(
        self,
        match_id: int,
        winner: str,
        team1_players: list[dict],
        team2_players: list[dict],
        player_stats: dict[str, dict],
    ) -> dict[str, int]:
        """Compute ELO changes for all players in a completed match.

        The implementation should use team-average ELO vs. opponent-average
        ELO as the basis for the expected score calculation, then scale the
        individual K-factor by the player's number of matches played.

        Args:
            match_id: Database ID of the match (for logging / history).
            winner: Which side won: ``'team1'``, ``'team2'``, or ``'tie'``.
            team1_players: List of dicts with at least ``steam_id``,
                ``elo_before``, and ``matches_played`` for each team-1 player.
            team2_players: Same structure for team-2 players.
            player_stats: Mapping of ``steam_id`` → stat dict (kills, deaths,
                assists, headshots, mvps, score, damage).

        Returns:
            Dict mapping each ``steam_id`` to its integer ELO change (can be
            negative).
        """

    @abstractmethod
    def get_rank_tier(self, elo: int) -> int:
        """Convert an ELO rating to a rank-tier index.

        Args:
            elo: ELO rating to look up.

        Returns:
            Integer tier index in the range ``[0, 17]`` where 0 is the lowest
            rank (Silver I) and 17 is the highest (The Global Elite).
        """

    @abstractmethod
    def apply_elo_decay(
        self,
        steam_id: str,
        current_elo: int,
        weeks_inactive: int,
    ) -> int:
        """Apply inactivity decay to a player's ELO.

        Decay only kicks in after 2 weeks of inactivity (no decay for
        ``weeks_inactive <= 2``).  The ELO floor is the minimum ELO for the
        player's current rank tier.

        Args:
            steam_id: Player's legacy Steam ID (for logging).
            current_elo: The player's current ELO before decay.
            weeks_inactive: Number of weeks since their last match.

        Returns:
            The new ELO after decay has been applied (may equal *current_elo*
            if decay did not apply or the floor was already reached).
        """
