"""
Player profile routes for the CS:GO Matchmaking web panel.
"""

from __future__ import annotations

import json

from flask import Blueprint, abort, redirect, render_template, request, url_for

from models import query_db, query_one, RankInfo

players_bp = Blueprint("players_bp", __name__)


@players_bp.route("/player/search", methods=["GET", "POST"])
def player_search() -> object:
    """
    Search for a player by name and redirect to their profile.

    Accepts both GET (query param ?q=) and POST (form field name=).
    If multiple matches are found the first result is used.
    Returns 404 if no player is found.
    """
    if request.method == "POST":
        name = request.form.get("name", "").strip()
    else:
        name = request.args.get("q", "").strip()

    if not name:
        return redirect(url_for("leaderboard_bp.leaderboard"))

    row = query_one(
        "SELECT steam_id FROM mm_player_stats WHERE name LIKE :pattern LIMIT 1",
        {"pattern": f"%{name}%"},
    )
    if not row:
        abort(404)

    return redirect(url_for("players_bp.player_profile", steam_id=row["steam_id"]))


@players_bp.route("/player/<steam_id>")
def player_profile(steam_id: str) -> str:
    """
    Display full profile page for a single player.

    Fetches player stats from mm_player_stats, last 20 matches from
    mm_match_players joined with mm_matches, and ELO history (last 50
    entries) for the inline SVG sparkline graph.

    Args:
        steam_id: Player's Steam ID (non-64-bit format).

    Returns:
        Rendered player.html template or 404 if player not found.
    """
    # Core stats
    player = query_one(
        "SELECT * FROM mm_player_stats WHERE steam_id = :sid",
        {"sid": steam_id},
    )
    if not player:
        abort(404)

    # Annotate rank
    tier = int(player.get("rank_tier") or 0)
    player["rank_name"] = RankInfo.get_name(tier)
    player["rank_color"] = RankInfo.get_color(tier)

    # Last 20 matches
    recent_matches = query_db(
        """
        SELECT
            m.id          AS match_id,
            m.map_name,
            m.team1_score,
            m.team2_score,
            m.ended_at,
            mp.team,
            mp.kills,
            mp.deaths,
            mp.assists,
            mp.elo_before,
            mp.elo_after,
            mp.elo_change,
            mp.score,
            CASE
                WHEN m.winner IS NULL THEN 'T'
                WHEN m.winner = mp.team THEN 'W'
                ELSE 'L'
            END AS result
        FROM mm_match_players mp
        JOIN mm_matches m ON m.id = mp.match_id
        WHERE mp.steam_id = :sid
          AND m.status = 'finished'
        ORDER BY m.ended_at DESC
        LIMIT 20
        """,
        {"sid": steam_id},
    )

    # ELO history for SVG graph (last 50 entries)
    elo_history_rows = query_db(
        """
        SELECT elo_after, created_at
        FROM mm_elo_history
        WHERE steam_id = :sid
        ORDER BY created_at DESC
        LIMIT 50
        """,
        {"sid": steam_id},
    )
    # Reverse so oldest→newest for the graph left-to-right
    elo_history_rows = list(reversed(elo_history_rows))
    elo_values: list[int] = [int(r["elo_after"]) for r in elo_history_rows]
    elo_history_json: str = json.dumps(elo_values)

    # Calculate SVG polyline points
    svg_points: str = _build_svg_points(elo_values, width=600, height=120)

    return render_template(
        "player.html",
        player=player,
        recent_matches=recent_matches,
        elo_values=elo_values,
        elo_history_json=elo_history_json,
        svg_points=svg_points,
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _build_svg_points(values: list[int], width: int = 600, height: int = 120) -> str:
    """
    Convert a list of ELO integers to an SVG polyline points string.

    Args:
        values: List of ELO values (oldest first).
        width:  Desired SVG viewport width in pixels.
        height: Desired SVG viewport height in pixels.

    Returns:
        Space-separated "x,y" coordinate string for use in <polyline points="...">.
        Returns an empty string if fewer than 2 data points are provided.
    """
    if len(values) < 2:
        return ""

    pad = 8  # padding inside the SVG
    inner_w = width - pad * 2
    inner_h = height - pad * 2

    min_v = min(values)
    max_v = max(values)
    v_range = max_v - min_v or 1  # avoid division by zero

    n = len(values)
    points: list[str] = []
    for i, v in enumerate(values):
        x = pad + (i / (n - 1)) * inner_w
        # Invert Y: higher ELO → lower y coordinate (top of SVG)
        y = pad + inner_h - ((v - min_v) / v_range) * inner_h
        points.append(f"{x:.1f},{y:.1f}")

    return " ".join(points)
