"""
Database access layer for the CS:GO Matchmaking web panel.

Uses SQLAlchemy engine for raw SQL queries (read-only access).
All queries are parameterized to prevent SQL injection.
"""

from __future__ import annotations

from typing import Any

from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text

db = SQLAlchemy()


def query_db(sql: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """
    Execute a raw SQL query and return results as a list of dicts.

    Args:
        sql: Parameterized SQL string (use :param_name style placeholders).
        params: Optional dict of parameter values.

    Returns:
        List of row dicts, with column names as keys.
    """
    with db.engine.connect() as conn:
        result = conn.execute(text(sql), params or {})
        columns = list(result.keys())
        return [dict(zip(columns, row)) for row in result.fetchall()]


def execute_db(sql: str, params: dict[str, Any] | None = None) -> int:
    """
    Execute a write SQL statement (INSERT / UPDATE / DELETE) and commit.

    Args:
        sql: Parameterized SQL string (use :param_name style placeholders).
        params: Optional dict of parameter values.

    Returns:
        Number of rows affected.
    """
    with db.engine.begin() as conn:
        result = conn.execute(text(sql), params or {})
        return result.rowcount


def query_one(sql: str, params: dict[str, Any] | None = None) -> dict[str, Any] | None:
    """
    Execute a raw SQL query and return the first row as a dict, or None.

    Args:
        sql: Parameterized SQL string (use :param_name style placeholders).
        params: Optional dict of parameter values.

    Returns:
        First row dict or None if no results.
    """
    rows = query_db(sql, params)
    return rows[0] if rows else None


# ---------------------------------------------------------------------------
# Rank information utility
# ---------------------------------------------------------------------------

class RankInfo:
    """
    Utility class for CS:GO rank tiers.

    Tiers 0-17 map to the classic CS:GO rank names with associated ELO
    thresholds and display colours.
    """

    # (min_elo, tier_index, display_name, hex_color)
    RANKS: list[tuple[int, int, str, str]] = [
        (0,    0,  "Silver I",                    "#808080"),
        (800,  1,  "Silver II",                   "#909090"),
        (900,  2,  "Silver III",                  "#999999"),
        (1000, 3,  "Silver IV",                   "#a0a0a0"),
        (1100, 4,  "Silver Elite",                "#b0b0b0"),
        (1200, 5,  "Silver Elite Master",         "#c0c0c0"),
        (1300, 6,  "Gold Nova I",                 "#c8a800"),
        (1400, 7,  "Gold Nova II",                "#d4b000"),
        (1500, 8,  "Gold Nova III",               "#e0bb00"),
        (1600, 9,  "Gold Nova Master",            "#f0cc00"),
        (1700, 10, "Master Guardian I",           "#4a90d9"),
        (1800, 11, "Master Guardian II",          "#3a80cc"),
        (1900, 12, "Master Guardian Elite",       "#2a70bf"),
        (2000, 13, "Distinguished Master Guardian","#6a4fbf"),
        (2200, 14, "Legendary Eagle",             "#b04040"),
        (2400, 15, "Legendary Eagle Master",      "#c04848"),
        (2600, 16, "Supreme Master First Class",  "#e05050"),
        (2800, 17, "The Global Elite",            "#FFD700"),
    ]

    @staticmethod
    def get_name(tier: int) -> str:
        """Return the display name for a rank tier index (0-17)."""
        tier = max(0, min(17, tier))
        return RankInfo.RANKS[tier][2]

    @staticmethod
    def get_color(tier: int) -> str:
        """Return the hex colour string for a rank tier index (0-17)."""
        tier = max(0, min(17, tier))
        return RankInfo.RANKS[tier][3]

    @staticmethod
    def get_tier_from_elo(elo: int) -> int:
        """
        Calculate the rank tier index (0-17) for a given ELO value.

        Args:
            elo: Player ELO rating.

        Returns:
            Integer tier index between 0 and 17 inclusive.
        """
        tier = 0
        for min_elo, idx, _name, _color in RankInfo.RANKS:
            if elo >= min_elo:
                tier = idx
            else:
                break
        return tier

    @staticmethod
    def get_all() -> list[tuple[int, int, str, str]]:
        """Return the full RANKS list."""
        return RankInfo.RANKS
