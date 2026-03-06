"""
Admin blueprint for the CS:GO Matchmaking web panel.

All routes require authentication via:
  - Flask session (browser navigation after login form)
  - Bearer token in the Authorization header (API / curl access)

The token is stored in config.env as ADMIN_TOKEN (48-char hex).
"""

from __future__ import annotations

import functools
import secrets
from typing import Callable

from flask import (
    Blueprint,
    abort,
    current_app,
    flash,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

from extensions import limiter
from models import execute_db, query_db, query_one

admin_bp = Blueprint("admin_bp", __name__, url_prefix="/admin")


# ---------------------------------------------------------------------------
# Authentication decorator
# ---------------------------------------------------------------------------

def require_admin(f: Callable) -> Callable:
    """
    Protect a route to admin-authenticated callers only.

    Accepts either:
      - A valid Flask session (``session["is_admin"] == True``).
      - An ``Authorization: Bearer <token>`` header matching ADMIN_TOKEN.

    Returns 403 for any other caller.
    """
    @functools.wraps(f)
    def wrapper(*args, **kwargs):
        if session.get("is_admin"):
            return f(*args, **kwargs)
        header = request.headers.get("Authorization", "")
        token = header.removeprefix("Bearer ").strip()
        configured = current_app.config.get("ADMIN_TOKEN", "")
        if token and configured and secrets.compare_digest(token, configured):
            return f(*args, **kwargs)
        abort(403)
    return wrapper


# ---------------------------------------------------------------------------
# Login / logout
# ---------------------------------------------------------------------------

@admin_bp.route("/login", methods=["GET"])
def login() -> str:
    """Render the admin login form."""
    if session.get("is_admin"):
        return redirect(url_for("admin_bp.dashboard"))
    return render_template("admin/login.html")


@admin_bp.route("/login", methods=["POST"])
@limiter.limit("10 per minute")
def login_post() -> object:
    """
    Validate the submitted token and create an admin session.

    Form field: ``token`` (plain text, sent over HTTPS in production).
    """
    submitted = request.form.get("token", "").strip()
    configured = current_app.config.get("ADMIN_TOKEN", "")

    if not configured:
        flash("ADMIN_TOKEN is not configured on this server.", "error")
        return redirect(url_for("admin_bp.login"))

    if not submitted or not secrets.compare_digest(submitted, configured):
        flash("Invalid token.", "error")
        return redirect(url_for("admin_bp.login"))

    session.permanent = False
    session["is_admin"] = True
    return redirect(url_for("admin_bp.dashboard"))


@admin_bp.route("/logout")
def logout() -> object:
    """Destroy the admin session and redirect to the login page."""
    session.pop("is_admin", None)
    flash("Logged out.", "info")
    return redirect(url_for("admin_bp.login"))


# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

@admin_bp.route("/")
@require_admin
def dashboard() -> str:
    """
    Admin dashboard: live match count, queue depth, and active containers.
    """
    live_matches = query_db(
        """
        SELECT id, match_token, map_name, status, port,
               docker_container_id, started_at
        FROM mm_matches
        WHERE status IN ('creating', 'warmup', 'live')
        ORDER BY started_at DESC
        """
    )
    queue_count = query_one(
        "SELECT COUNT(*) AS cnt FROM mm_queue WHERE status = 'searching'"
    )
    active_bans = query_one(
        "SELECT COUNT(*) AS cnt FROM mm_bans WHERE expires_at > NOW() OR expires_at IS NULL"
    )
    return render_template(
        "admin/dashboard.html",
        live_matches=live_matches,
        queue_count=int(queue_count["cnt"]) if queue_count else 0,
        active_bans=int(active_bans["cnt"]) if active_bans else 0,
    )


# ---------------------------------------------------------------------------
# Bans
# ---------------------------------------------------------------------------

@admin_bp.route("/bans")
@require_admin
def bans() -> str:
    """List all active bans with their expiry times."""
    active_bans = query_db(
        """
        SELECT b.steam_id, p.name, b.reason, b.banned_by,
               b.created_at, b.expires_at
        FROM mm_bans b
        LEFT JOIN mm_players p ON p.steam_id = b.steam_id
        WHERE b.expires_at > NOW() OR b.expires_at IS NULL
        ORDER BY b.created_at DESC
        """
    )
    return render_template("admin/bans.html", bans=active_bans)


@admin_bp.route("/ban", methods=["POST"])
@require_admin
@limiter.limit("10 per minute")
def ban_player() -> object:
    """
    Ban a player.

    Form fields:
        steam_id (str): Target Steam ID.
        duration_minutes (int): 0 = permanent, >0 = temporary.
        reason (str): Human-readable ban reason.
    """
    steam_id = request.form.get("steam_id", "").strip()
    duration = request.form.get("duration_minutes", "0").strip()
    reason = request.form.get("reason", "No reason given").strip()

    if not steam_id:
        flash("steam_id is required.", "error")
        return redirect(url_for("admin_bp.bans"))

    try:
        duration_int = max(0, int(duration))
    except ValueError:
        flash("duration_minutes must be an integer.", "error")
        return redirect(url_for("admin_bp.bans"))

    expires_expr = (
        "DATE_ADD(NOW(), INTERVAL :dur MINUTE)" if duration_int > 0 else "NULL"
    )

    execute_db(
        f"""
        INSERT INTO mm_bans (steam_id, reason, banned_by, created_at, expires_at)
        VALUES (:sid, :reason, 'admin-panel', NOW(), {expires_expr})
        ON DUPLICATE KEY UPDATE
            reason      = VALUES(reason),
            banned_by   = VALUES(banned_by),
            created_at  = VALUES(created_at),
            expires_at  = VALUES(expires_at)
        """,
        {"sid": steam_id, "reason": reason, "dur": duration_int},
    )
    execute_db(
        "UPDATE mm_players SET is_banned = 1 WHERE steam_id = :sid",
        {"sid": steam_id},
    )
    flash(f"Player {steam_id} banned.", "success")
    return redirect(url_for("admin_bp.bans"))


@admin_bp.route("/unban", methods=["POST"])
@require_admin
@limiter.limit("10 per minute")
def unban_player() -> object:
    """
    Lift a ban from a player.

    Form field:
        steam_id (str): Target Steam ID.
    """
    steam_id = request.form.get("steam_id", "").strip()
    if not steam_id:
        flash("steam_id is required.", "error")
        return redirect(url_for("admin_bp.bans"))

    execute_db("DELETE FROM mm_bans WHERE steam_id = :sid", {"sid": steam_id})
    execute_db(
        "UPDATE mm_players SET is_banned = 0 WHERE steam_id = :sid",
        {"sid": steam_id},
    )
    flash(f"Ban lifted for {steam_id}.", "success")
    return redirect(url_for("admin_bp.bans"))


# ---------------------------------------------------------------------------
# ELO management
# ---------------------------------------------------------------------------

@admin_bp.route("/setelo", methods=["POST"])
@require_admin
@limiter.limit("10 per minute")
def set_elo() -> object:
    """
    Override a player's ELO.

    Form fields:
        steam_id (str): Target Steam ID.
        elo (int): New ELO value (0–9999).
    """
    steam_id = request.form.get("steam_id", "").strip()
    elo_raw = request.form.get("elo", "").strip()

    if not steam_id:
        flash("steam_id is required.", "error")
        return redirect(url_for("admin_bp.dashboard"))

    try:
        elo = int(elo_raw)
        if not 0 <= elo <= 9999:
            raise ValueError
    except ValueError:
        flash("ELO must be an integer between 0 and 9999.", "error")
        return redirect(url_for("admin_bp.dashboard"))

    rows = execute_db(
        "UPDATE mm_players SET elo = :elo WHERE steam_id = :sid",
        {"elo": elo, "sid": steam_id},
    )
    if rows == 0:
        flash(f"Player {steam_id} not found.", "warning")
    else:
        # Log the manual override in elo history
        execute_db(
            """
            INSERT INTO mm_elo_history
                (steam_id, match_id, elo_before, elo_after, change_reason, created_at)
            SELECT :sid, NULL,
                   (SELECT elo FROM mm_players WHERE steam_id = :sid),
                   :elo, 'admin', NOW()
            """,
            {"sid": steam_id, "elo": elo},
        )
        flash(f"ELO for {steam_id} set to {elo}.", "success")
    return redirect(url_for("admin_bp.dashboard"))


# ---------------------------------------------------------------------------
# Error handlers scoped to the admin blueprint
# ---------------------------------------------------------------------------

@admin_bp.errorhandler(403)
def admin_forbidden(e: Exception) -> tuple:
    """Redirect unauthenticated admin requests to the login page."""
    flash("Authentication required.", "error")
    return redirect(url_for("admin_bp.login")), 302
