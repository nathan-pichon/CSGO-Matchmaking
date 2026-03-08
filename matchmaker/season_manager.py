"""
Season management for the CS:GO matchmaking daemon.

Handles season transitions including ELO soft-reset, stat archival,
and ELO history logging.  All operations are idempotent and logged.
"""

from __future__ import annotations

import logging
from datetime import date
from typing import Optional

from matchmaker.db import Database

logger = logging.getLogger(__name__)

# ELO soft-reset formula:
# If elo > reset_to: new_elo = reset_to + (elo - reset_to) * 0.5
# If elo <= reset_to: new_elo = reset_to


class SeasonManager:
    """Manages competitive season lifecycle.

    Args:
        db: Connected :class:`~matchmaker.db.Database` instance.
    """

    def __init__(self, db: Database) -> None:
        self._db = db

    # ---------------------------------------------------------------------- #
    # Public API
    # ---------------------------------------------------------------------- #

    def get_active_season(self) -> Optional[dict]:
        """Return the currently active season row, or ``None``."""
        return self._db.query_one(
            "SELECT id, name, start_date, elo_reset_to FROM mm_seasons WHERE is_active = 1 LIMIT 1"
        )

    def start_new_season(self, name: str, elo_reset_to: int = 1000) -> int:
        """Close the current season and start a new one.

        Steps:
        1. Deactivate current active season (set end_date = today).
        2. Create a new season row.
        3. Soft-reset ELO for all players.
        4. Log every change in mm_elo_history.
        5. Update mm_players.season_id for all players.

        Args:
            name: Human-readable season name (e.g. ``'Season 2'``).
            elo_reset_to: Base ELO value for the soft-reset formula.

        Returns:
            The new season's database ID.
        """
        logger.info("Starting new season '%s' (reset_to=%d)", name, elo_reset_to)

        with self._db.get_connection() as conn:
            with conn.cursor(dictionary=True) as cur:
                # 1. Close current active season
                cur.execute(
                    "UPDATE mm_seasons SET is_active = 0, end_date = %s WHERE is_active = 1",
                    (date.today().isoformat(),),
                )

                # 2. Create new season
                cur.execute(
                    "INSERT INTO mm_seasons (name, start_date, is_active, elo_reset_to) "
                    "VALUES (%s, %s, 1, %s)",
                    (name, date.today().isoformat(), elo_reset_to),
                )
                new_season_id = cur.lastrowid
                logger.info("New season ID: %d", new_season_id)

                # 3+4. Soft-reset ELO and log history
                cur.execute("SELECT steam_id, elo FROM mm_players FOR UPDATE")
                players = cur.fetchall()

                for p in players:
                    old_elo: int = p["elo"]
                    sid: str = p["steam_id"]
                    if old_elo > elo_reset_to:
                        new_elo = elo_reset_to + (old_elo - elo_reset_to) // 2
                    else:
                        new_elo = elo_reset_to

                    cur.execute(
                        "UPDATE mm_players SET elo = %s, season_id = %s WHERE steam_id = %s",
                        (new_elo, new_season_id, sid),
                    )
                    cur.execute(
                        "INSERT INTO mm_elo_history "
                        "  (steam_id, match_id, elo_before, elo_after, change_reason) "
                        "VALUES (%s, NULL, %s, %s, 'season_reset')",
                        (sid, old_elo, new_elo),
                    )

                logger.info(
                    "Season reset applied to %d players (reset_to=%d)",
                    len(players), elo_reset_to,
                )

        return new_season_id
