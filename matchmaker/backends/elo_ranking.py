"""
ELO-based ranking backend for the CS:GO matchmaking daemon.

Implements :class:`~matchmaker.interfaces.ranking.RankingBackend` using a
standard ELO formula with per-player K-factor scaling and 18 CS:GO-style
rank tiers.
"""

from __future__ import annotations

import logging
from typing import Optional

from matchmaker.interfaces.ranking import RankingBackend

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Rank tier definitions
# Each tuple is (minimum_elo, display_name).  Index == tier id (0-17).
# ---------------------------------------------------------------------------
RANK_THRESHOLDS: list[tuple[int, str]] = [
    (0,    "Silver I"),
    (800,  "Silver II"),
    (850,  "Silver III"),
    (900,  "Silver IV"),
    (950,  "Silver Elite"),
    (1000, "Silver Elite Master"),
    (1050, "Gold Nova I"),
    (1100, "Gold Nova II"),
    (1150, "Gold Nova III"),
    (1200, "Gold Nova Master"),
    (1300, "Master Guardian I"),
    (1400, "Master Guardian II"),
    (1500, "Master Guardian Elite"),
    (1600, "Distinguished Master Guardian"),
    (1700, "Legendary Eagle"),
    (1800, "Legendary Eagle Master"),
    (1900, "Supreme Master First Class"),
    (2000, "The Global Elite"),
]


def _tier_min_elo(tier: int) -> int:
    """Return the minimum ELO required for *tier*.

    Args:
        tier: Rank tier index (0-17).

    Returns:
        Minimum ELO integer.
    """
    if tier < 0:
        return 0
    if tier >= len(RANK_THRESHOLDS):
        return RANK_THRESHOLDS[-1][0]
    return RANK_THRESHOLDS[tier][0]


class EloRankingBackend(RankingBackend):
    """Concrete ELO ranking implementation.

    Args:
        config: The application :class:`~matchmaker.config.Config` instance.
            Used to read ``ELO_K_FACTOR``, ``ELO_K_FACTOR_NEW``, and
            ``ELO_DEFAULT``.
        db: Optional :class:`~matchmaker.db.Database` instance (used to
            persist ELO history records).  When ``None``, history is skipped
            (useful in tests).
    """

    def __init__(self, config: object, db: Optional[object] = None) -> None:
        self._config = config
        self._db = db

    # ---------------------------------------------------------------------- #
    # Public API
    # ---------------------------------------------------------------------- #

    def expected_score(self, rating_a: float, rating_b: float) -> float:
        """Return the expected score for player A against player B.

        Uses the standard ELO formula: ``1 / (1 + 10^((B-A)/400))``.

        Args:
            rating_a: ELO of player A.
            rating_b: ELO of player B.

        Returns:
            Float in ``[0, 1]`` representing A's expected win probability.
        """
        return 1.0 / (1.0 + 10.0 ** ((rating_b - rating_a) / 400.0))

    def get_k_factor(self, matches_played: int, config: Optional[object] = None) -> int:
        """Return the appropriate K-factor for a player.

        Args:
            matches_played: Number of competitive matches the player has
                completed.
            config: Optional config override (falls back to ``self._config``).

        Returns:
            Integer K-factor:

            - ``64`` for players with fewer than 10 matches (placement).
            - ``32`` for players with 10–29 matches.
            - ``24`` for players with 30+ matches (veteran).
        """
        cfg = config or self._config
        k_new: int = getattr(cfg, "ELO_K_FACTOR_NEW", 64)
        k_std: int = getattr(cfg, "ELO_K_FACTOR", 32)
        min_placement: int = getattr(cfg, "MIN_PLACEMENT_MATCHES", 10)

        if matches_played < min_placement:
            return k_new
        if matches_played < 30:
            return k_std
        return 24

    def calculate_match_results(
        self,
        match_id: int,
        winner: str,
        team1_players: list[dict],
        team2_players: list[dict],
        player_stats: dict[str, dict],
    ) -> dict[str, int]:
        """Compute ELO changes for all 10 players in a completed match.

        Uses the *team average ELO* vs *opponent team average ELO* as the
        expected-score baseline, then scales by each player's individual
        K-factor.

        Args:
            match_id: Database ID of the match (for logging).
            winner: ``'team1'``, ``'team2'``, or ``'tie'``.
            team1_players: List of dicts with ``steam_id``, ``elo_before``,
                and ``matches_played`` for each team-1 player.
            team2_players: Same for team 2.
            player_stats: Mapping ``steam_id → stat dict`` (unused in base
                formula but available for future bonus logic).

        Returns:
            Dict mapping each ``steam_id`` to their signed integer ELO change.
        """
        if not team1_players or not team2_players:
            logger.warning(
                "calculate_match_results called with empty team (match_id=%s)",
                match_id,
            )
            return {}

        team1_avg = sum(p["elo_before"] for p in team1_players) / len(team1_players)
        team2_avg = sum(p["elo_before"] for p in team2_players) / len(team2_players)

        # Actual scores: 1 for win, 0.5 for tie, 0 for loss.
        if winner == "team1":
            actual_t1, actual_t2 = 1.0, 0.0
        elif winner == "team2":
            actual_t1, actual_t2 = 0.0, 1.0
        else:  # tie
            actual_t1 = actual_t2 = 0.5

        expected_t1 = self.expected_score(team1_avg, team2_avg)
        expected_t2 = self.expected_score(team2_avg, team1_avg)

        elo_changes: dict[str, int] = {}

        for player in team1_players:
            sid = player["steam_id"]
            k = self.get_k_factor(player.get("matches_played", 0))
            change = round(k * (actual_t1 - expected_t1))
            elo_changes[sid] = change
            logger.debug(
                "ELO change team1 player=%s k=%d actual=%.1f expected=%.3f change=%d",
                sid, k, actual_t1, expected_t1, change,
            )

        for player in team2_players:
            sid = player["steam_id"]
            k = self.get_k_factor(player.get("matches_played", 0))
            change = round(k * (actual_t2 - expected_t2))
            elo_changes[sid] = change
            logger.debug(
                "ELO change team2 player=%s k=%d actual=%.1f expected=%.3f change=%d",
                sid, k, actual_t2, expected_t2, change,
            )

        # Persist ELO history if a DB handle is available.
        if self._db is not None:
            for player in team1_players + team2_players:
                sid = player["steam_id"]
                elo_before = player["elo_before"]
                delta = elo_changes.get(sid, 0)
                try:
                    self._db.record_elo_history(
                        sid, match_id, elo_before, elo_before + delta, "match"
                    )
                except Exception as exc:
                    logger.warning(
                        "Failed to record ELO history for %s: %s", sid, exc
                    )

        return elo_changes

    def get_rank_tier(self, elo: int) -> int:
        """Convert an ELO rating to a rank tier index (0-17).

        Args:
            elo: Player's current ELO rating.

        Returns:
            Tier index.  0 = Silver I, 17 = The Global Elite.
        """
        tier = 0
        for idx, (threshold, _) in enumerate(RANK_THRESHOLDS):
            if elo >= threshold:
                tier = idx
        return tier

    def apply_elo_decay(
        self,
        steam_id: str,
        current_elo: int,
        weeks_inactive: int,
    ) -> int:
        """Apply inactivity ELO decay to a player.

        Decay starts after 2 weeks of inactivity at a rate of 10 ELO per
        week.  The ELO floor is the minimum ELO for the player's current tier.

        Args:
            steam_id: Player's legacy Steam ID (for logging).
            current_elo: Current ELO before decay.
            weeks_inactive: Number of full weeks since the player last played.

        Returns:
            New ELO after decay (may be unchanged if ``weeks_inactive <= 2``).
        """
        if weeks_inactive <= 2:
            return current_elo

        decay_weeks = weeks_inactive - 2
        decay_amount = decay_weeks * 10

        current_tier = self.get_rank_tier(current_elo)
        floor_elo = _tier_min_elo(current_tier)

        new_elo = max(current_elo - decay_amount, floor_elo)

        if new_elo < current_elo:
            logger.info(
                "ELO decay applied: player=%s weeks_inactive=%d "
                "elo_before=%d elo_after=%d",
                steam_id, weeks_inactive, current_elo, new_elo,
            )

        return new_elo
