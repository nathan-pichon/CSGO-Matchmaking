"""
Leaderboard routes for the CS:GO Matchmaking web panel.
"""

from __future__ import annotations

import math

from flask import Blueprint, render_template, request

from extensions import cache
from models import query_db, query_one, RankInfo

leaderboard_bp = Blueprint("leaderboard_bp", __name__)

PER_PAGE = 25


@leaderboard_bp.route("/leaderboard")
@cache.cached(timeout=30, query_string=True)
def leaderboard() -> str:
    """
    Display the paginated player leaderboard.

    Reads from the mm_leaderboard view, supports page query param and
    optional season filter. Results are cached for 30 seconds.
    """
    page = max(1, request.args.get("page", 1, type=int))
    season_id = request.args.get("season", None, type=int)
    offset = (page - 1) * PER_PAGE

    # Fetch seasons for the dropdown
    seasons = query_db(
        "SELECT id, name, is_active FROM mm_seasons ORDER BY start_date DESC"
    )

    # Total count for pagination
    count_row = query_one("SELECT COUNT(*) AS cnt FROM mm_leaderboard")
    total = int(count_row["cnt"]) if count_row else 0
    total_pages = max(1, math.ceil(total / PER_PAGE))
    page = min(page, total_pages)

    # Fetch one page of leaderboard rows
    rows = query_db(
        """
        SELECT
            `rank`,
            steam_id,
            name,
            elo,
            rank_tier,
            matches_played,
            win_rate_pct,
            kd_ratio
        FROM mm_leaderboard
        ORDER BY `rank`
        LIMIT :limit OFFSET :offset
        """,
        {"limit": PER_PAGE, "offset": offset},
    )

    # Annotate each row with rank name and colour
    for row in rows:
        tier = int(row.get("rank_tier") or 0)
        row["rank_name"] = RankInfo.get_name(tier)
        row["rank_color"] = RankInfo.get_color(tier)

    # Wins / losses — mm_leaderboard doesn't expose W/L/T directly so we
    # pull them separately via mm_player_stats for the visible page only.
    if rows:
        steam_ids = [r["steam_id"] for r in rows]
        placeholders = ", ".join(f":sid{i}" for i in range(len(steam_ids)))
        params = {f"sid{i}": sid for i, sid in enumerate(steam_ids)}
        stats = query_db(
            f"""
            SELECT steam_id, matches_won, matches_lost, matches_tied
            FROM mm_player_stats
            WHERE steam_id IN ({placeholders})
            """,
            params,
        )
        stats_map = {s["steam_id"]: s for s in stats}
        for row in rows:
            extra = stats_map.get(row["steam_id"], {})
            row["matches_won"] = extra.get("matches_won", 0)
            row["matches_lost"] = extra.get("matches_lost", 0)
            row["matches_tied"] = extra.get("matches_tied", 0)

    return render_template(
        "leaderboard.html",
        rows=rows,
        page=page,
        total_pages=total_pages,
        total=total,
        seasons=seasons,
        selected_season=season_id,
    )
