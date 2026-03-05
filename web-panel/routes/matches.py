"""
Match listing and match detail routes for the CS:GO Matchmaking web panel.
"""

from __future__ import annotations

import math

from flask import Blueprint, abort, render_template, request

from models import query_db, query_one, RankInfo

matches_bp = Blueprint("matches_bp", __name__)

PER_PAGE = 20


@matches_bp.route("/matches")
def match_list() -> str:
    """
    Display a paginated list of finished matches.

    Queries mm_matches WHERE status='finished', ordered by ended_at DESC.
    Shows map, date, score, duration, and winning team indicator.
    """
    page = max(1, request.args.get("page", 1, type=int))
    offset = (page - 1) * PER_PAGE

    count_row = query_one(
        "SELECT COUNT(*) AS cnt FROM mm_matches WHERE status = 'finished'"
    )
    total = int(count_row["cnt"]) if count_row else 0
    total_pages = max(1, math.ceil(total / PER_PAGE))
    page = min(page, total_pages)

    matches = query_db(
        """
        SELECT
            id,
            match_token,
            map_name,
            team1_score,
            team2_score,
            winner,
            started_at,
            ended_at,
            TIMESTAMPDIFF(MINUTE, started_at, ended_at) AS duration_minutes
        FROM mm_matches
        WHERE status = 'finished'
        ORDER BY ended_at DESC
        LIMIT :limit OFFSET :offset
        """,
        {"limit": PER_PAGE, "offset": offset},
    )

    return render_template(
        "matches.html",
        matches=matches,
        page=page,
        total_pages=total_pages,
        total=total,
    )


@matches_bp.route("/match/<int:match_id>")
def match_detail(match_id: int) -> str:
    """
    Display the full CS:GO-style scoreboard for a single match.

    Fetches match header info from mm_matches and all player rows from
    mm_match_players, split into team1/team2 dicts sorted by score DESC.
    Highlights the top fragger and MVP of the match.

    Args:
        match_id: Primary key of the mm_matches row.

    Returns:
        Rendered match.html template, or 404 if the match does not exist.
    """
    match = query_one(
        """
        SELECT
            id,
            match_token,
            map_name,
            team1_score,
            team2_score,
            winner,
            started_at,
            ended_at,
            TIMESTAMPDIFF(MINUTE, started_at, ended_at) AS duration_minutes
        FROM mm_matches
        WHERE id = :mid
        """,
        {"mid": match_id},
    )
    if not match:
        abort(404)

    players = query_db(
        """
        SELECT
            mp.steam_id,
            mp.team,
            mp.is_captain,
            mp.kills,
            mp.deaths,
            mp.assists,
            mp.headshots,
            mp.mvps,
            mp.score,
            mp.damage,
            mp.elo_before,
            mp.elo_after,
            mp.elo_change,
            ps.name,
            ps.rank_tier,
            CASE WHEN mp.deaths = 0 THEN mp.kills
                 ELSE ROUND(mp.kills / mp.deaths, 2)
            END AS kd_ratio,
            CASE WHEN mp.kills = 0 THEN 0
                 ELSE ROUND(mp.headshots / mp.kills * 100, 1)
            END AS hs_pct
        FROM mm_match_players mp
        LEFT JOIN mm_player_stats ps ON ps.steam_id = mp.steam_id
        WHERE mp.match_id = :mid
        ORDER BY mp.team, mp.score DESC
        """,
        {"mid": match_id},
    )

    # Annotate rank info
    for p in players:
        tier = int(p.get("rank_tier") or 0)
        p["rank_name"] = RankInfo.get_name(tier)
        p["rank_color"] = RankInfo.get_color(tier)

    team1 = [p for p in players if p["team"] == 1]
    team2 = [p for p in players if p["team"] == 2]

    # Sort each team by score descending (already done by ORDER BY, but be explicit)
    team1.sort(key=lambda p: int(p.get("score") or 0), reverse=True)
    team2.sort(key=lambda p: int(p.get("score") or 0), reverse=True)

    # Top fragger (most kills across both teams)
    all_players = team1 + team2
    top_fragger_sid: str | None = None
    if all_players:
        top = max(all_players, key=lambda p: int(p.get("kills") or 0))
        top_fragger_sid = top["steam_id"]

    # MVP of the match — player with most mvp stars
    match_mvp_sid: str | None = None
    if all_players:
        mvp_player = max(all_players, key=lambda p: int(p.get("mvps") or 0))
        if int(mvp_player.get("mvps") or 0) > 0:
            match_mvp_sid = mvp_player["steam_id"]

    return render_template(
        "match.html",
        match=match,
        team1=team1,
        team2=team2,
        top_fragger_sid=top_fragger_sid,
        match_mvp_sid=match_mvp_sid,
    )
