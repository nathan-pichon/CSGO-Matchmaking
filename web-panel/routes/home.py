"""
Home page blueprint for the CS:GO Matchmaking web panel.

Displays live server stats, top players, recent matches, and
a "How to join" guide.
"""

from __future__ import annotations

from flask import Blueprint, redirect, render_template, session, url_for

from models import query_db, query_one, RankInfo

home_bp = Blueprint("home_bp", __name__)


@home_bp.route("/")
def index() -> object:
    """Render the public home page, or redirect logged-in players to their dashboard."""
    if session.get("is_logged_in"):
        return redirect(url_for("auth_bp.dashboard"))

    # ── Live stats ───────────────────────────────────────────────────────────
    queue_count = query_one("SELECT COUNT(*) AS cnt FROM mm_queue WHERE status = 'waiting'")
    live_matches = query_one(
        "SELECT COUNT(*) AS cnt FROM mm_matches WHERE status IN ('warmup', 'live')"
    )
    total_players = query_one("SELECT COUNT(*) AS cnt FROM mm_players")
    total_matches = query_one("SELECT COUNT(*) AS cnt FROM mm_matches WHERE status = 'finished'")

    queue_count   = int(queue_count["cnt"])   if queue_count   else 0
    live_matches  = int(live_matches["cnt"])  if live_matches  else 0
    total_players = int(total_players["cnt"]) if total_players else 0
    total_matches = int(total_matches["cnt"]) if total_matches else 0

    top_players = query_db(
        """
        SELECT p.steam_id, p.name, p.elo, p.rank_tier,
               CASE WHEN p.total_deaths > 0
                    THEN ROUND(p.total_kills * 1.0 / p.total_deaths, 2)
                    ELSE p.total_kills
               END AS kd_ratio
        FROM mm_players p
        WHERE p.matches_played >= 1 AND p.is_banned = 0
        ORDER BY p.elo DESC
        LIMIT 5
        """
    )
    for p in top_players:
        tier = int(p.get("rank_tier") or 0)
        p["rank_name"]  = RankInfo.get_name(tier)
        p["rank_color"] = RankInfo.get_color(tier)

    recent_matches = query_db(
        """
        SELECT id, map_name, team1_score, team2_score, winner, ended_at
        FROM mm_matches
        WHERE status = 'finished'
        ORDER BY ended_at DESC
        LIMIT 5
        """
    )

    return render_template(
        "index.html",
        queue_count=queue_count,
        live_matches=live_matches,
        total_players=total_players,
        total_matches=total_matches,
        top_players=top_players,
        recent_matches=recent_matches,
    )
