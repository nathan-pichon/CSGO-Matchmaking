"""
REST API blueprint for the CS:GO Matchmaking web panel.

All endpoints return JSON with appropriate HTTP status codes.
"""

from __future__ import annotations

from flask import Blueprint, jsonify, request

from models import query_db, query_one

api_bp = Blueprint("api_bp", __name__)


# ---------------------------------------------------------------------------
# Error helpers
# ---------------------------------------------------------------------------

def _err(message: str, status: int) -> tuple:
    """Return a JSON error response tuple."""
    return jsonify({"error": message}), status


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@api_bp.route("/queue/count")
def queue_count() -> tuple:
    """
    Return the number of players currently searching for a match.

    Returns:
        JSON: {"count": N, "status": "ok"}
    """
    try:
        row = query_one(
            "SELECT COUNT(*) AS cnt FROM mm_queue WHERE status = 'searching'"
        )
        count = int(row["cnt"]) if row else 0
        return jsonify({"count": count, "status": "ok"}), 200
    except Exception:
        return _err("Internal server error", 500)


@api_bp.route("/player/<steam_id>")
def player_stats(steam_id: str) -> tuple:
    """
    Return full stats for a single player.

    Args:
        steam_id: Player Steam ID.

    Returns:
        JSON player stats dict, or 404 JSON error if not found.
    """
    try:
        row = query_one(
            "SELECT * FROM mm_player_stats WHERE steam_id = :sid",
            {"sid": steam_id},
        )
        if not row:
            return _err("Not found", 404)
        return jsonify(_serialize(row)), 200
    except Exception:
        return _err("Internal server error", 500)


@api_bp.route("/leaderboard")
def leaderboard() -> tuple:
    """
    Return top players from the leaderboard.

    Query params:
        limit (int): Number of players to return (default 10, max 100).

    Returns:
        JSON array of player objects.
    """
    try:
        limit = min(100, max(1, request.args.get("limit", 10, type=int)))
        rows = query_db(
            """
            SELECT `rank`, steam_id, name, elo, rank_tier,
                   matches_played, win_rate_pct, kd_ratio
            FROM mm_leaderboard
            ORDER BY `rank`
            LIMIT :limit
            """,
            {"limit": limit},
        )
        return jsonify([_serialize(r) for r in rows]), 200
    except Exception:
        return _err("Internal server error", 500)


@api_bp.route("/matches")
def recent_matches() -> tuple:
    """
    Return recent finished matches.

    Query params:
        limit (int): Number of matches to return (default 10, max 50).

    Returns:
        JSON array of match objects.
    """
    try:
        limit = min(50, max(1, request.args.get("limit", 10, type=int)))
        rows = query_db(
            """
            SELECT id, match_token, map_name,
                   team1_score, team2_score, winner,
                   started_at, ended_at,
                   TIMESTAMPDIFF(MINUTE, started_at, ended_at) AS duration_minutes
            FROM mm_matches
            WHERE status = 'finished'
            ORDER BY ended_at DESC
            LIMIT :limit
            """,
            {"limit": limit},
        )
        return jsonify([_serialize(r) for r in rows]), 200
    except Exception:
        return _err("Internal server error", 500)


@api_bp.errorhandler(404)
def api_not_found(e: Exception) -> tuple:
    """Return JSON 404 for any unmatched route within this blueprint."""
    return _err("Not found", 404)


@api_bp.errorhandler(500)
def api_internal_error(e: Exception) -> tuple:
    """Return JSON 500 for any unhandled error within this blueprint."""
    return _err("Internal server error", 500)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _serialize(row: dict) -> dict:
    """
    Convert a row dict to a JSON-safe dict.

    Converts datetime objects to ISO strings and Decimal to float.
    """
    import datetime
    import decimal

    result: dict = {}
    for k, v in row.items():
        if isinstance(v, (datetime.datetime, datetime.date)):
            result[k] = v.isoformat()
        elif isinstance(v, decimal.Decimal):
            result[k] = float(v)
        else:
            result[k] = v
    return result
