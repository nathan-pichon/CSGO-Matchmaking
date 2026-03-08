"""
Steam OpenID authentication and player dashboard blueprint.

Authentication flow
-------------------
1. ``GET /login``          — Show the "Login with Steam" page (or redirect if already
                             logged in).
2. ``GET /auth/steam``     — Redirect to Steam's OpenID endpoint.
3. ``GET /auth/steam/callback`` — Verify Steam's OpenID response, create session,
                             detect admin role, redirect to dashboard or ``next``.
4. ``GET /logout``         — Clear the session and return to the home page.
5. ``GET /dashboard``      — Personal stats dashboard for the logged-in player.

Session keys set after successful login
---------------------------------------
- ``is_logged_in``    bool   — always True after Steam auth
- ``steam_id``        str    — legacy Steam ID (STEAM_0:X:Y)
- ``steam_name``      str    — display name from mm_players, or Steam ID fallback
- ``is_admin``        bool   — True if the player is in mm_admins
- ``admin_role``      str    — 'superadmin' | 'admin' | 'moderator' (only if admin)
- ``admin_steam_id``  str    — same as steam_id (kept for admin_bp compatibility)
"""

from __future__ import annotations

import re
import urllib.parse

import requests as http_client
from flask import (
    Blueprint,
    flash,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

from models import RankInfo, execute_db, query_db, query_one

auth_bp = Blueprint("auth_bp", __name__)

# Steam OpenID endpoint
_STEAM_OPENID = "https://steamcommunity.com/openid/login"
# HTTP timeout for the server-side verification call
_VERIFY_TIMEOUT = 10


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _steamid64_to_steam2(steamid64: int) -> str:
    """Convert a 64-bit Steam ID to legacy STEAM_0:X:Y format.

    Args:
        steamid64: Raw 64-bit Steam community ID.

    Returns:
        String in ``STEAM_0:<auth_bit>:<account_id>`` format.
    """
    base = 76561197960265728
    val = steamid64 - base
    return f"STEAM_0:{val % 2}:{val // 2}"


def _match_result(team: str, winner: str) -> str:
    """Return 'win', 'loss', or 'tie' from the player's perspective.

    Args:
        team: ``'team1'`` or ``'team2'`` — which side the player was on.
        winner: ``'team1'``, ``'team2'``, or ``'tie'`` from mm_matches.

    Returns:
        One of ``'win'``, ``'loss'``, or ``'tie'``.
    """
    if winner == "tie":
        return "tie"
    if (team == "team1" and winner == "team1") or (team == "team2" and winner == "team2"):
        return "win"
    return "loss"


def _safe_next(next_url: str | None) -> str | None:
    """Return *next_url* only if it is a safe relative URL (no open redirect).

    Args:
        next_url: Candidate redirect target from session or query string.

    Returns:
        The URL if safe, otherwise ``None``.
    """
    if next_url and next_url.startswith("/") and not next_url.startswith("//"):
        return next_url
    return None


# ---------------------------------------------------------------------------
# Login / logout
# ---------------------------------------------------------------------------

@auth_bp.route("/login")
def login() -> object:
    """Display the login page or redirect if already authenticated."""
    if session.get("is_logged_in"):
        dest = _safe_next(request.args.get("next")) or url_for("auth_bp.dashboard")
        return redirect(dest)

    # Persist intended destination across the OpenID redirect round-trip.
    next_url = request.args.get("next", "")
    if next_url:
        session["login_next"] = next_url

    return render_template("auth/login.html")


@auth_bp.route("/auth/steam")
def steam_redirect() -> object:
    """Build the Steam OpenID authorisation URL and redirect the browser."""
    return_to = url_for("auth_bp.steam_callback", _external=True)
    realm = request.url_root.rstrip("/")

    params = urllib.parse.urlencode({
        "openid.ns":         "http://specs.openid.net/auth/2.0",
        "openid.mode":       "checkid_setup",
        "openid.return_to":  return_to,
        "openid.realm":      realm,
        "openid.identity":   "http://specs.openid.net/auth/2.0/identifier_select",
        "openid.claimed_id": "http://specs.openid.net/auth/2.0/identifier_select",
    })
    return redirect(f"{_STEAM_OPENID}?{params}")


@auth_bp.route("/auth/steam/callback")
def steam_callback() -> object:
    """Verify the Steam OpenID response and create a session.

    Performs a server-side ``check_authentication`` POST to Steam to confirm
    the identity claim, then resolves the SteamID64 to a legacy Steam ID,
    looks up the player and any admin record, and builds the session.
    """
    # --- 1. Server-side verification ---
    verify_params = dict(request.args)
    verify_params["openid.mode"] = "check_authentication"

    try:
        resp = http_client.post(
            _STEAM_OPENID,
            data=verify_params,
            timeout=_VERIFY_TIMEOUT,
        )
        if "is_valid:true" not in resp.text:
            flash("Steam authentication failed — please try again.", "error")
            return redirect(url_for("auth_bp.login"))
    except http_client.RequestException:
        flash("Could not reach Steam servers — please try again.", "error")
        return redirect(url_for("auth_bp.login"))

    # --- 2. Extract SteamID64 from claimed_id ---
    claimed = request.args.get("openid.claimed_id", "")
    match = re.search(r"/id/(\d+)$", claimed)
    if not match:
        flash("Invalid Steam response — please try again.", "error")
        return redirect(url_for("auth_bp.login"))

    steamid64 = int(match.group(1))
    steam_id = _steamid64_to_steam2(steamid64)

    # --- 3. Look up the player (may not exist yet if they've never played) ---
    player = query_one(
        "SELECT name FROM mm_players WHERE steam_id = :sid",
        {"sid": steam_id},
    )
    steam_name = player["name"] if player else steam_id

    # --- 4. Build session ---
    session.permanent = False
    session["is_logged_in"]  = True
    session["steam_id"]      = steam_id
    session["steam_name"]    = steam_name

    # --- 5. Admin check ---
    admin = query_one(
        "SELECT role FROM mm_admins WHERE steam_id = :sid",
        {"sid": steam_id},
    )
    if admin:
        session["is_admin"]       = True
        session["admin_role"]     = admin["role"]
        session["admin_steam_id"] = steam_id
        try:
            execute_db(
                "UPDATE mm_admins SET last_login = NOW() WHERE steam_id = :sid",
                {"sid": steam_id},
            )
        except Exception:
            pass  # Non-fatal — login still succeeds
    else:
        # Clear any stale admin session data
        session.pop("is_admin", None)
        session.pop("admin_role", None)
        session.pop("admin_steam_id", None)

    # --- 6. Redirect ---
    next_url = _safe_next(session.pop("login_next", None))
    return redirect(next_url or url_for("auth_bp.dashboard"))


@auth_bp.route("/logout")
def logout() -> object:
    """Clear the session and return to the home page."""
    session.clear()
    flash("You have been signed out.", "info")
    return redirect(url_for("home_bp.index"))


# ---------------------------------------------------------------------------
# Personal dashboard
# ---------------------------------------------------------------------------

@auth_bp.route("/dashboard")
def dashboard() -> object:
    """Render the logged-in player's personal stats dashboard.

    Redirects to the login page if the user is not authenticated.
    Shows graceful empty-state content for players not yet in the database.
    """
    if not session.get("is_logged_in"):
        return redirect(url_for("auth_bp.login", next="/dashboard"))

    steam_id = session["steam_id"]

    # --- Player record ---
    player = query_one(
        """
        SELECT name, elo, rank_tier, matches_played,
               wins, losses, ties,
               total_kills, total_deaths, total_assists
        FROM   mm_players
        WHERE  steam_id = :sid
        """,
        {"sid": steam_id},
    )

    if player:
        tier       = int(player.get("rank_tier") or 0)
        rank_name  = RankInfo.get_name(tier)
        rank_color = RankInfo.get_color(tier)
        played     = int(player.get("matches_played") or 0)
        wins       = int(player.get("wins") or 0)
        kills      = int(player.get("total_kills") or 0)
        deaths     = int(player.get("total_deaths") or 0)
        kd         = round(kills / deaths, 2) if deaths else float(kills)
        win_rate   = round(wins / played * 100, 1) if played else 0.0
    else:
        rank_name  = "Unranked"
        rank_color = "#888888"
        kd         = 0.0
        win_rate   = 0.0

    # --- Recent matches (last 10) ---
    recent_matches = query_db(
        """
        SELECT m.id, m.map_name, m.team1_score, m.team2_score,
               m.winner, m.ended_at,
               mp.team, mp.kills, mp.deaths, mp.assists, mp.elo_change
        FROM   mm_match_players mp
        JOIN   mm_matches m ON m.id = mp.match_id
        WHERE  mp.steam_id = :sid AND m.status = 'finished'
        ORDER  BY m.ended_at DESC
        LIMIT  10
        """,
        {"sid": steam_id},
    )
    for m in recent_matches:
        m["result"] = _match_result(m["team"], m["winner"])

    # --- ELO history sparkline (last 20 data points) ---
    elo_history = query_db(
        """
        SELECT elo_after
        FROM   mm_elo_history
        WHERE  steam_id = :sid
        ORDER  BY changed_at ASC
        LIMIT  20
        """,
        {"sid": steam_id},
    )
    elo_points = [int(row["elo_after"]) for row in elo_history]

    return render_template(
        "dashboard.html",
        player=player,
        steam_id=steam_id,
        rank_name=rank_name,
        rank_color=rank_color,
        kd=kd,
        win_rate=win_rate,
        recent_matches=recent_matches,
        elo_points=elo_points,
    )
