"""
Admin blueprint for the CS:GO Matchmaking web panel.

Authentication
--------------
Admin access is granted to any user whose Steam ID appears in ``mm_admins``.
Authentication is handled by the Steam OpenID flow in ``routes/auth.py``:

  1. Visiting ``/admin/login`` (or any protected admin route while logged out)
     redirects to ``/login?next=/admin/`` which triggers the Steam OpenID flow.
     After successful auth the session will contain ``is_admin=True`` and
     ``admin_role`` if the player is registered as an admin.
  2. An ``Authorization: Bearer <ADMIN_TOKEN>`` header also grants access
     (for API / curl usage — backward-compatible).

Role hierarchy
--------------
  superadmin  — full access: admin management + all admin/moderator actions
  admin       — ban/unban players, override ELO, view all
  moderator   — ban/unban players only

The first super-admin is seeded from the ``SUPER_ADMIN_STEAM_ID`` env var at
startup.  Additional admins are managed at ``/admin/admins`` (superadmin only).
"""

from __future__ import annotations

import functools
import os
import secrets
import sys
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

# Role order for comparison
_ROLE_RANK = {"moderator": 1, "admin": 2, "superadmin": 3}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _current_role() -> str:
    """Return the role for the active request (session or Bearer token)."""
    if session.get("is_admin"):
        return session.get("admin_role", "moderator")
    # Bearer token grants implicit superadmin (backward-compat API access)
    header = request.headers.get("Authorization", "")
    token = header.removeprefix("Bearer ").strip()
    configured = current_app.config.get("ADMIN_TOKEN", "")
    if token and configured and secrets.compare_digest(token, configured):
        return "superadmin"
    return ""


def _current_steam_id() -> str:
    """Return the logged-in admin's Steam ID, or 'api-token' for Bearer auth."""
    return session.get("admin_steam_id", "api-token")


def _log_action(
    action: str,
    target_type: str | None = None,
    target_id: str | None = None,
    detail: str | None = None,
) -> None:
    """Insert an audit log entry.  Failures are swallowed so the log can never
    block the actual admin action."""
    try:
        execute_db(
            """
            INSERT INTO mm_admin_log
                (admin_id, action, target_type, target_id, detail, created_at)
            VALUES (:admin_id, :action, :target_type, :target_id, :detail, NOW())
            """,
            {
                "admin_id": _current_steam_id(),
                "action": action,
                "target_type": target_type,
                "target_id": str(target_id) if target_id is not None else None,
                "detail": detail,
            },
        )
    except Exception:  # noqa: BLE001
        pass  # audit failure must never break the actual action


def _get_rcon():
    """Return a configured RCONClient imported from the matchmaker package."""
    mm_path = os.path.join(os.path.dirname(__file__), "..", "..", "matchmaker")
    if mm_path not in sys.path:
        sys.path.insert(0, mm_path)
    from rcon_client import RCONClient  # type: ignore[import]
    return RCONClient(timeout=4)


# ---------------------------------------------------------------------------
# Decorators
# ---------------------------------------------------------------------------

def require_role(min_role: str) -> Callable:
    """Protect a route to admins whose role is >= *min_role*.

    Unauthenticated visitors are redirected to the Steam login flow.
    Authenticated non-admins receive a 403.
    """
    def decorator(f: Callable) -> Callable:
        @functools.wraps(f)
        def wrapper(*args, **kwargs):
            role = _current_role()
            if not role:
                # Not logged in at all → send through Steam auth
                if not session.get("is_logged_in"):
                    return redirect(url_for("auth_bp.login", next="/admin/"))
                abort(403)
            if _ROLE_RANK.get(role, 0) < _ROLE_RANK.get(min_role, 99):
                flash(
                    f"This action requires the '{min_role}' role.",
                    "error",
                )
                return redirect(url_for("admin_bp.dashboard"))
            return f(*args, **kwargs)
        return wrapper
    return decorator


# Convenience alias for backward-compat with any existing callers
require_admin = require_role("moderator")


# ---------------------------------------------------------------------------
# Login / logout
# ---------------------------------------------------------------------------

@admin_bp.route("/login")
def login() -> object:
    """Redirect to the Steam login page with /admin/ as the post-auth target.

    If the user already has an active admin session, redirect straight to the
    admin dashboard.  If they are logged in as a regular player but not an
    admin, show a 403 flash and send them back to the home page.
    """
    if session.get("is_admin"):
        return redirect(url_for("admin_bp.dashboard"))
    if session.get("is_logged_in"):
        flash("Your account does not have admin access.", "error")
        return redirect(url_for("home_bp.index"))
    # Not logged in at all — bounce through Steam OpenID, then come back here.
    return redirect(url_for("auth_bp.login", next="/admin/"))


@admin_bp.route("/logout")
def logout() -> object:
    """Clear the full session and redirect to the home page."""
    session.clear()
    flash("Signed out.", "info")
    return redirect(url_for("home_bp.index"))


# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

@admin_bp.route("/")
@require_role("moderator")
def dashboard() -> str:
    live_matches = query_db(
        """
        SELECT id, match_token, map_name, status, server_port,
               docker_container_id, started_at
        FROM mm_matches
        WHERE status IN ('creating', 'warmup', 'live', 'overtime')
        ORDER BY started_at DESC
        """
    )
    queue_count = query_one(
        "SELECT COUNT(*) AS cnt FROM mm_queue WHERE status = 'waiting'"
    )
    active_bans = query_one(
        "SELECT COUNT(*) AS cnt FROM mm_bans WHERE expires_at > NOW() OR expires_at IS NULL"
    )
    pending_reports = query_one(
        """
        SELECT COUNT(DISTINCT reported_id) AS cnt
        FROM mm_reports
        WHERE reviewed = 0
          AND created_at > DATE_SUB(NOW(), INTERVAL 30 DAY)
        GROUP BY reported_id
        HAVING COUNT(DISTINCT reporter_id) >= 3
        """
    )
    stats = query_one(
        """
        SELECT
          (SELECT COUNT(*) FROM mm_players) AS total_players,
          (SELECT COUNT(*) FROM mm_matches WHERE status = 'finished') AS total_matches,
          (SELECT COUNT(*) FROM mm_players
           WHERE DATE(created_at) = CURDATE()) AS players_today,
          (SELECT COUNT(*) FROM mm_matches
           WHERE status = 'finished' AND DATE(started_at) = CURDATE()) AS matches_today,
          (SELECT COUNT(*) FROM mm_server_ports WHERE in_use = 0) AS free_ports,
          (SELECT COUNT(*) FROM mm_gslt_tokens WHERE in_use = 0) AS free_gslt
        """
    )
    return render_template(
        "admin/dashboard.html",
        live_matches=live_matches,
        queue_count=int((queue_count or {}).get("cnt", 0)),
        active_bans=int((active_bans or {}).get("cnt", 0)),
        pending_reports=int((pending_reports or {}).get("cnt", 0)),
        stats=stats or {},
        current_role=_current_role(),
    )


# ---------------------------------------------------------------------------
# Queue monitor
# ---------------------------------------------------------------------------

@admin_bp.route("/queue")
@require_role("moderator")
def queue_monitor() -> str:
    queue_entries = query_db(
        """
        SELECT q.id, q.steam_id, COALESCE(p.name, q.steam_id) AS player_name,
               q.elo, q.rank_tier, q.status, q.ready, q.queued_at,
               q.map_preference, q.lobby_server_id,
               TIMESTAMPDIFF(SECOND, q.queued_at, NOW()) AS wait_secs
        FROM mm_queue q
        LEFT JOIN mm_players p ON p.steam_id = q.steam_id
        WHERE q.status IN ('waiting', 'ready_check', 'matched')
        ORDER BY q.status ASC, q.queued_at ASC
        """
    )
    return render_template(
        "admin/queue.html",
        queue_entries=queue_entries,
        current_role=_current_role(),
    )


@admin_bp.route("/queue/<int:entry_id>/kick", methods=["POST"])
@require_role("moderator")
@limiter.limit("20 per minute")
def queue_kick(entry_id: int) -> object:
    entry = query_one("SELECT steam_id FROM mm_queue WHERE id = :id", {"id": entry_id})
    if not entry:
        flash("Queue entry not found.", "warning")
        return redirect(url_for("admin_bp.queue_monitor"))
    execute_db(
        "UPDATE mm_queue SET status = 'cancelled' WHERE id = :id",
        {"id": entry_id},
    )
    _log_action("queue_kick", "queue", str(entry_id),
                f"Kicked {entry['steam_id']} from queue")
    flash(f"Player {entry['steam_id']} removed from queue.", "success")
    return redirect(url_for("admin_bp.queue_monitor"))


# ---------------------------------------------------------------------------
# Server management
# ---------------------------------------------------------------------------

@admin_bp.route("/servers")
@require_role("moderator")
def servers() -> str:
    match_servers = query_db(
        """
        SELECT id, match_token, map_name, status, server_port, server_ip,
               docker_container_id, started_at, live_at, ended_at,
               team1_score, team2_score, cancel_reason, cleaned_up
        FROM mm_matches
        WHERE status IN ('creating', 'warmup', 'live', 'overtime')
        ORDER BY started_at DESC
        """
    )
    lobby = {
        "ip": current_app.config.get("LOBBY_IP", "127.0.0.1"),
        "port": current_app.config.get("LOBBY_PORT", 27015),
    }
    port_stats = query_one(
        "SELECT COUNT(*) AS total, SUM(in_use) AS used FROM mm_server_ports"
    )
    gslt_stats = query_one(
        "SELECT COUNT(*) AS total, SUM(in_use) AS used FROM mm_gslt_tokens"
    )
    return render_template(
        "admin/servers.html",
        match_servers=match_servers,
        lobby=lobby,
        port_stats=port_stats or {},
        gslt_stats=gslt_stats or {},
        current_role=_current_role(),
    )


@admin_bp.route("/servers/<int:match_id>/cancel", methods=["POST"])
@require_role("admin")
@limiter.limit("10 per minute")
def server_cancel(match_id: int) -> object:
    reason = request.form.get("reason", "Cancelled by admin").strip()
    rows = execute_db(
        """
        UPDATE mm_matches
        SET status = 'cancelled', cancel_reason = :reason, ended_at = NOW()
        WHERE id = :id AND status IN ('creating', 'warmup', 'live', 'overtime')
        """,
        {"id": match_id, "reason": reason},
    )
    if rows == 0:
        flash("Match not found or already finished.", "warning")
    else:
        _log_action("cancel_match", "match", str(match_id), reason)
        flash(f"Match #{match_id} cancelled.", "success")
    return redirect(url_for("admin_bp.servers"))


@admin_bp.route("/servers/<int:match_id>/say", methods=["POST"])
@require_role("moderator")
@limiter.limit("15 per minute")
def server_say(match_id: int) -> object:
    message = request.form.get("message", "").strip()
    if not message:
        flash("Message cannot be empty.", "error")
        return redirect(url_for("admin_bp.servers"))

    match = query_one(
        "SELECT server_ip, server_port FROM mm_matches WHERE id = :id",
        {"id": match_id},
    )
    if not match:
        flash("Match not found.", "warning")
        return redirect(url_for("admin_bp.servers"))

    try:
        rcon = _get_rcon()
        rcon.say(
            match["server_ip"],
            match["server_port"],
            current_app.config.get("RCON_PASSWORD", ""),
            f"[ADMIN] {message}",
        )
        _log_action("server_say", "server", str(match_id), message[:100])
        flash(f"Message sent to match #{match_id}.", "success")
    except Exception as exc:
        current_app.logger.warning("RCON say failed for match %d: %s", match_id, exc)
        flash(f"RCON error: {exc}", "error")
    return redirect(url_for("admin_bp.servers"))


@admin_bp.route("/servers/lobby-say", methods=["POST"])
@require_role("moderator")
@limiter.limit("10 per minute")
def lobby_say() -> object:
    message = request.form.get("message", "").strip()
    if not message:
        flash("Message cannot be empty.", "error")
        return redirect(url_for("admin_bp.servers"))

    try:
        rcon = _get_rcon()
        rcon.say(
            current_app.config.get("LOBBY_IP", "127.0.0.1"),
            current_app.config.get("LOBBY_PORT", 27015),
            current_app.config.get("RCON_PASSWORD", ""),
            f"[ADMIN] {message}",
        )
        _log_action("lobby_say", "server", "lobby", message[:100])
        flash("Message broadcast to lobby.", "success")
    except Exception as exc:
        current_app.logger.warning("Lobby RCON say failed: %s", exc)
        flash(f"RCON error: {exc}", "error")
    return redirect(url_for("admin_bp.servers"))


# ---------------------------------------------------------------------------
# Admin match list  (all statuses, cancel + cleanup)
# ---------------------------------------------------------------------------

@admin_bp.route("/matches")
@require_role("moderator")
def admin_matches() -> str:
    page = max(1, request.args.get("page", 1, type=int))
    per_page = 30
    status_filter = request.args.get("status", "")

    where = "WHERE 1=1"
    params: dict = {}
    if status_filter:
        where += " AND status = :status"
        params["status"] = status_filter

    total_row = query_one(
        f"SELECT COUNT(*) AS cnt FROM mm_matches {where}", params
    )
    total = int((total_row or {}).get("cnt", 0))
    total_pages = max(1, (total + per_page - 1) // per_page)
    params["limit"] = per_page
    params["offset"] = (page - 1) * per_page

    matches = query_db(
        f"""
        SELECT id, match_token, map_name, status, server_port, server_ip,
               docker_container_id, started_at, ended_at,
               team1_score, team2_score, winner, cancel_reason,
               cleaned_up, cleanup_attempts
        FROM mm_matches
        {where}
        ORDER BY started_at DESC
        LIMIT :limit OFFSET :offset
        """,
        params,
    )
    return render_template(
        "admin/matches_admin.html",
        matches=matches,
        status_filter=status_filter,
        page=page,
        total_pages=total_pages,
        current_role=_current_role(),
    )


@admin_bp.route("/matches/<int:match_id>/cancel", methods=["POST"])
@require_role("admin")
@limiter.limit("10 per minute")
def match_cancel(match_id: int) -> object:
    reason = request.form.get("reason", "Cancelled by admin").strip()
    rows = execute_db(
        """
        UPDATE mm_matches
        SET status = 'cancelled', cancel_reason = :reason, ended_at = NOW()
        WHERE id = :id AND status NOT IN ('finished', 'cancelled')
        """,
        {"id": match_id, "reason": reason},
    )
    if rows == 0:
        flash("Match not found or already in a terminal state.", "warning")
    else:
        _log_action("cancel_match", "match", str(match_id), reason)
        flash(f"Match #{match_id} cancelled.", "success")
    return redirect(url_for("admin_bp.admin_matches"))


@admin_bp.route("/matches/<int:match_id>/cleanup", methods=["POST"])
@require_role("admin")
@limiter.limit("10 per minute")
def match_cleanup(match_id: int) -> object:
    """Force-mark a match as cleaned up and release its port / GSLT."""
    match = query_one(
        "SELECT server_port, gslt_token FROM mm_matches WHERE id = :id",
        {"id": match_id},
    )
    if not match:
        flash("Match not found.", "warning")
        return redirect(url_for("admin_bp.admin_matches"))

    execute_db(
        "UPDATE mm_matches SET cleaned_up = 1 WHERE id = :id",
        {"id": match_id},
    )
    if match.get("server_port"):
        execute_db(
            "UPDATE mm_server_ports SET in_use = 0, assigned_match_id = NULL WHERE port = :port",
            {"port": match["server_port"]},
        )
    if match.get("gslt_token"):
        execute_db(
            "UPDATE mm_gslt_tokens SET in_use = 0, assigned_match_id = NULL WHERE token = :token",
            {"token": match["gslt_token"]},
        )
    _log_action("cleanup_match", "match", str(match_id), "Force-cleanup by admin")
    flash(f"Match #{match_id} marked as cleaned up; resources released.", "success")
    return redirect(url_for("admin_bp.admin_matches"))


# ---------------------------------------------------------------------------
# Player management
# ---------------------------------------------------------------------------

@admin_bp.route("/players")
@require_role("moderator")
def admin_players() -> str:
    q = request.args.get("q", "").strip()
    tab = request.args.get("tab", "all")  # all | banned | abandon | reported
    page = max(1, request.args.get("page", 1, type=int))
    per_page = 30

    base_select = """
        SELECT p.steam_id, p.name, p.elo, p.rank_tier,
               p.matches_played, p.is_banned, p.abandon_count,
               b.expires_at AS ban_expires, b.reason AS ban_reason,
               (SELECT COUNT(DISTINCT r.reporter_id)
                FROM mm_reports r
                WHERE r.reported_id = p.steam_id AND r.reviewed = 0
                  AND r.created_at > DATE_SUB(NOW(), INTERVAL 30 DAY)) AS report_count
        FROM mm_players p
        LEFT JOIN mm_bans b ON b.steam_id = p.steam_id
            AND (b.expires_at > NOW() OR b.expires_at IS NULL)
    """
    where_parts = []
    params: dict = {}

    if q:
        where_parts.append("(p.name LIKE :q OR p.steam_id LIKE :q)")
        params["q"] = f"%{q}%"

    if tab == "banned":
        where_parts.append("p.is_banned = 1")
    elif tab == "abandon":
        where_parts.append("p.abandon_count > 0")
    elif tab == "reported":
        where_parts.append(
            """(SELECT COUNT(DISTINCT r.reporter_id) FROM mm_reports r
                WHERE r.reported_id = p.steam_id AND r.reviewed = 0
                  AND r.created_at > DATE_SUB(NOW(), INTERVAL 30 DAY)) >= 3"""
        )

    where_clause = ("WHERE " + " AND ".join(where_parts)) if where_parts else ""

    total_row = query_one(
        f"SELECT COUNT(*) AS cnt FROM mm_players p LEFT JOIN mm_bans b "
        f"ON b.steam_id = p.steam_id AND (b.expires_at > NOW() OR b.expires_at IS NULL) "
        f"{where_clause}",
        params,
    )
    total = int((total_row or {}).get("cnt", 0))
    total_pages = max(1, (total + per_page - 1) // per_page)

    params["limit"] = per_page
    params["offset"] = (page - 1) * per_page

    players = query_db(
        f"{base_select} {where_clause} ORDER BY p.elo DESC LIMIT :limit OFFSET :offset",
        params,
    )
    return render_template(
        "admin/players.html",
        players=players,
        q=q,
        tab=tab,
        page=page,
        total_pages=total_pages,
        current_role=_current_role(),
    )


@admin_bp.route("/players/<steam_id>/kick-queue", methods=["POST"])
@require_role("moderator")
@limiter.limit("20 per minute")
def player_kick_queue(steam_id: str) -> object:
    rows = execute_db(
        "UPDATE mm_queue SET status = 'cancelled' WHERE steam_id = :sid AND status IN ('waiting', 'ready_check')",
        {"sid": steam_id},
    )
    if rows == 0:
        flash(f"{steam_id} is not currently in queue.", "warning")
    else:
        _log_action("kick_queue", "player", steam_id, "Removed from queue by admin")
        flash(f"{steam_id} removed from queue.", "success")
    return redirect(url_for("admin_bp.admin_players"))


# ---------------------------------------------------------------------------
# Bans
# ---------------------------------------------------------------------------

@admin_bp.route("/bans")
@require_role("moderator")
def bans() -> str:
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
    recent_unbans = query_db(
        """
        SELECT b.steam_id, p.name, b.reason, b.banned_by,
               b.unbanned_by, b.unbanned_at
        FROM mm_bans b
        LEFT JOIN mm_players p ON p.steam_id = b.steam_id
        WHERE b.unbanned_at IS NOT NULL
          AND b.unbanned_at > DATE_SUB(NOW(), INTERVAL 7 DAY)
        ORDER BY b.unbanned_at DESC
        LIMIT 20
        """
    )
    return render_template(
        "admin/bans.html",
        bans=active_bans,
        recent_unbans=recent_unbans,
        current_role=_current_role(),
    )


@admin_bp.route("/ban", methods=["POST"])
@require_role("moderator")
@limiter.limit("10 per minute")
def ban_player() -> object:
    steam_id = request.form.get("steam_id", "").strip()
    duration = request.form.get("duration_minutes", "0").strip()
    reason   = request.form.get("reason", "No reason given").strip()

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
    by = _current_steam_id()

    execute_db(
        f"""
        INSERT INTO mm_bans (steam_id, reason, banned_by, created_at, expires_at)
        VALUES (:sid, :reason, :by, NOW(), {expires_expr})
        ON DUPLICATE KEY UPDATE
            reason      = VALUES(reason),
            banned_by   = VALUES(banned_by),
            created_at  = VALUES(created_at),
            expires_at  = VALUES(expires_at),
            unbanned_by = NULL,
            unbanned_at = NULL
        """,
        {"sid": steam_id, "reason": reason, "by": by, "dur": duration_int},
    )
    execute_db(
        "UPDATE mm_players SET is_banned = 1 WHERE steam_id = :sid",
        {"sid": steam_id},
    )
    dur_label = f"{duration_int} min" if duration_int > 0 else "permanent"
    _log_action("ban", "ban", steam_id, f"{reason} ({dur_label})")
    flash(f"Player {steam_id} banned.", "success")
    return redirect(url_for("admin_bp.bans"))


@admin_bp.route("/unban", methods=["POST"])
@require_role("moderator")
@limiter.limit("10 per minute")
def unban_player() -> object:
    steam_id = request.form.get("steam_id", "").strip()
    if not steam_id:
        flash("steam_id is required.", "error")
        return redirect(url_for("admin_bp.bans"))

    by = _current_steam_id()
    # Soft-delete: set expires_at to NOW() and record who unbanned + when
    execute_db(
        """
        UPDATE mm_bans
        SET expires_at  = NOW(),
            unbanned_by = :by,
            unbanned_at = NOW()
        WHERE steam_id = :sid
          AND (expires_at > NOW() OR expires_at IS NULL)
        """,
        {"sid": steam_id, "by": by},
    )
    execute_db(
        "UPDATE mm_players SET is_banned = 0 WHERE steam_id = :sid",
        {"sid": steam_id},
    )
    _log_action("unban", "ban", steam_id, f"Ban lifted by {by}")
    flash(f"Ban lifted for {steam_id}.", "success")
    return redirect(url_for("admin_bp.bans"))


# ---------------------------------------------------------------------------
# ELO management  (admin+)
# ---------------------------------------------------------------------------

@admin_bp.route("/setelo", methods=["POST"])
@require_role("admin")
@limiter.limit("10 per minute")
def set_elo() -> object:
    steam_id = request.form.get("steam_id", "").strip()
    elo_raw  = request.form.get("elo", "").strip()
    redirect_to = request.form.get("redirect_to", "players")

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

    old = query_one("SELECT elo FROM mm_players WHERE steam_id = :sid", {"sid": steam_id})
    rows = execute_db(
        "UPDATE mm_players SET elo = :elo WHERE steam_id = :sid",
        {"elo": elo, "sid": steam_id},
    )
    if rows == 0:
        flash(f"Player {steam_id} not found.", "warning")
    else:
        old_elo = int((old or {}).get("elo", 0))
        execute_db(
            """
            INSERT INTO mm_elo_history
                (steam_id, match_id, elo_before, elo_after, change_reason, created_at)
            VALUES (:sid, NULL, :before, :after, 'admin', NOW())
            """,
            {"sid": steam_id, "before": old_elo, "after": elo},
        )
        _log_action("set_elo", "player", steam_id, f"{old_elo} → {elo}")
        flash(f"ELO for {steam_id} set to {elo}.", "success")

    if redirect_to == "players":
        return redirect(url_for("admin_bp.admin_players"))
    return redirect(url_for("admin_bp.dashboard"))


# ---------------------------------------------------------------------------
# Map pool  (admin+)
# ---------------------------------------------------------------------------

@admin_bp.route("/maps")
@require_role("admin")
def map_pool() -> str:
    maps = query_db(
        "SELECT id, map_name, display_name, is_active, weight FROM mm_map_pool ORDER BY weight DESC, map_name ASC"
    )
    return render_template(
        "admin/maps.html",
        maps=maps,
        current_role=_current_role(),
    )


@admin_bp.route("/maps/<int:map_id>/toggle", methods=["POST"])
@require_role("admin")
@limiter.limit("20 per minute")
def map_toggle(map_id: int) -> object:
    m = query_one("SELECT map_name, is_active FROM mm_map_pool WHERE id = :id", {"id": map_id})
    if not m:
        flash("Map not found.", "warning")
        return redirect(url_for("admin_bp.map_pool"))
    new_state = 0 if m["is_active"] else 1
    execute_db(
        "UPDATE mm_map_pool SET is_active = :state WHERE id = :id",
        {"state": new_state, "id": map_id},
    )
    label = "enabled" if new_state else "disabled"
    _log_action("map_toggle", "map", m["map_name"], f"Map {label}")
    flash(f"{m['map_name']} {label}.", "success")
    return redirect(url_for("admin_bp.map_pool"))


@admin_bp.route("/maps/<int:map_id>/weight", methods=["POST"])
@require_role("admin")
@limiter.limit("20 per minute")
def map_weight(map_id: int) -> object:
    try:
        weight = int(request.form.get("weight", "1"))
        if not 1 <= weight <= 10:
            raise ValueError
    except ValueError:
        flash("Weight must be an integer between 1 and 10.", "error")
        return redirect(url_for("admin_bp.map_pool"))

    m = query_one("SELECT map_name FROM mm_map_pool WHERE id = :id", {"id": map_id})
    if not m:
        flash("Map not found.", "warning")
        return redirect(url_for("admin_bp.map_pool"))

    execute_db(
        "UPDATE mm_map_pool SET weight = :weight WHERE id = :id",
        {"weight": weight, "id": map_id},
    )
    _log_action("map_weight", "map", m["map_name"], f"Weight set to {weight}")
    flash(f"Weight for {m['map_name']} updated to {weight}.", "success")
    return redirect(url_for("admin_bp.map_pool"))


@admin_bp.route("/maps/add", methods=["POST"])
@require_role("admin")
@limiter.limit("10 per minute")
def map_add() -> object:
    map_name = request.form.get("map_name", "").strip().lower()
    display_name = request.form.get("display_name", "").strip()

    if not map_name or not display_name:
        flash("Both map name and display name are required.", "error")
        return redirect(url_for("admin_bp.map_pool"))

    try:
        execute_db(
            "INSERT INTO mm_map_pool (map_name, display_name, is_active, weight) VALUES (:name, :display, 1, 1)",
            {"name": map_name, "display": display_name},
        )
        _log_action("map_add", "map", map_name, f"Added as '{display_name}'")
        flash(f"Map {map_name} added.", "success")
    except Exception:
        flash(f"Map '{map_name}' already exists.", "error")
    return redirect(url_for("admin_bp.map_pool"))


@admin_bp.route("/maps/<int:map_id>/delete", methods=["POST"])
@require_role("superadmin")
@limiter.limit("10 per minute")
def map_delete(map_id: int) -> object:
    m = query_one("SELECT map_name FROM mm_map_pool WHERE id = :id", {"id": map_id})
    if not m:
        flash("Map not found.", "warning")
        return redirect(url_for("admin_bp.map_pool"))
    execute_db("DELETE FROM mm_map_pool WHERE id = :id", {"id": map_id})
    _log_action("map_delete", "map", m["map_name"], "Deleted from pool")
    flash(f"Map {m['map_name']} removed from pool.", "success")
    return redirect(url_for("admin_bp.map_pool"))


# ---------------------------------------------------------------------------
# Admin management  (superadmin only)
# ---------------------------------------------------------------------------

@admin_bp.route("/admins")
@require_role("superadmin")
def admin_list() -> str:
    admins = query_db(
        """
        SELECT a.steam_id, a.role, a.notes,
               COALESCE(p.name, a.steam_id) AS display_name,
               a.added_by, a.created_at, a.last_login
        FROM mm_admins a
        LEFT JOIN mm_players p ON p.steam_id = a.steam_id
        ORDER BY FIELD(a.role,'superadmin','admin','moderator'), a.created_at ASC
        """
    )
    return render_template(
        "admin/admins.html",
        admins=admins,
        current_steam_id=_current_steam_id(),
    )


@admin_bp.route("/admins/add", methods=["POST"])
@require_role("superadmin")
@limiter.limit("20 per minute")
def admin_add() -> object:
    steam_id = request.form.get("steam_id", "").strip()
    role     = request.form.get("role", "moderator").strip()
    notes    = request.form.get("notes", "").strip()

    if not steam_id:
        flash("Steam ID is required.", "error")
        return redirect(url_for("admin_bp.admin_list"))

    if role not in ("superadmin", "admin", "moderator"):
        flash("Invalid role.", "error")
        return redirect(url_for("admin_bp.admin_list"))

    by = _current_steam_id()

    execute_db(
        """
        INSERT INTO mm_admins (steam_id, role, added_by, notes)
        VALUES (:sid, :role, :by, :notes)
        ON DUPLICATE KEY UPDATE
            role     = VALUES(role),
            added_by = VALUES(added_by),
            notes    = VALUES(notes)
        """,
        {"sid": steam_id, "role": role, "by": by, "notes": notes or None},
    )
    _log_action("admin_add", "admin", steam_id, f"Role: {role}")
    flash(f"Admin {steam_id} added/updated as {role}.", "success")
    return redirect(url_for("admin_bp.admin_list"))


@admin_bp.route("/admins/remove", methods=["POST"])
@require_role("superadmin")
@limiter.limit("20 per minute")
def admin_remove() -> object:
    steam_id = request.form.get("steam_id", "").strip()

    if not steam_id:
        flash("Steam ID is required.", "error")
        return redirect(url_for("admin_bp.admin_list"))

    # Prevent self-removal
    if steam_id == _current_steam_id():
        flash("You cannot remove your own admin account.", "error")
        return redirect(url_for("admin_bp.admin_list"))

    rows = execute_db(
        "DELETE FROM mm_admins WHERE steam_id = :sid",
        {"sid": steam_id},
    )
    if rows == 0:
        flash(f"Admin {steam_id} not found.", "warning")
    else:
        _log_action("admin_remove", "admin", steam_id, "Admin access revoked")
        flash(f"Admin {steam_id} removed.", "success")
    return redirect(url_for("admin_bp.admin_list"))


@admin_bp.route("/admins/role", methods=["POST"])
@require_role("superadmin")
@limiter.limit("20 per minute")
def admin_set_role() -> object:
    steam_id = request.form.get("steam_id", "").strip()
    new_role = request.form.get("role", "").strip()

    if not steam_id or new_role not in ("superadmin", "admin", "moderator"):
        flash("Invalid request.", "error")
        return redirect(url_for("admin_bp.admin_list"))

    if steam_id == _current_steam_id():
        flash("You cannot change your own role.", "error")
        return redirect(url_for("admin_bp.admin_list"))

    rows = execute_db(
        "UPDATE mm_admins SET role = :role WHERE steam_id = :sid",
        {"role": new_role, "sid": steam_id},
    )
    if rows == 0:
        flash(f"Admin {steam_id} not found.", "warning")
    else:
        _log_action("admin_role", "admin", steam_id, f"Role changed to {new_role}")
        flash(f"Role for {steam_id} changed to {new_role}.", "success")
    return redirect(url_for("admin_bp.admin_list"))


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

@admin_bp.route("/reports")
@require_role("moderator")
def reports() -> str:
    flagged = query_db(
        """
        SELECT r.reported_id,
               COALESCE(p.name, r.reported_id) AS display_name,
               COUNT(DISTINCT r.reporter_id)    AS unique_reporters,
               COUNT(*)                         AS total_reports,
               MAX(r.created_at)                AS last_report
        FROM mm_reports r
        LEFT JOIN mm_players p ON p.steam_id = r.reported_id
        WHERE r.reviewed = 0
          AND r.created_at > DATE_SUB(NOW(), INTERVAL 30 DAY)
        GROUP BY r.reported_id
        HAVING unique_reporters >= 3
        ORDER BY unique_reporters DESC
        """
    )
    return render_template("admin/reports.html", flagged=flagged,
                           current_role=_current_role())


@admin_bp.route("/reports/<reported_id>")
@require_role("moderator")
def report_detail(reported_id: str) -> str:
    player = query_one(
        "SELECT name, elo, rank_tier, matches_played, is_banned FROM mm_players WHERE steam_id = :sid",
        {"sid": reported_id},
    )
    individual_reports = query_db(
        """
        SELECT r.id, r.reporter_id,
               COALESCE(rp.name, r.reporter_id) AS reporter_name,
               r.match_id, m.map_name, r.reason, r.details, r.created_at
        FROM mm_reports r
        LEFT JOIN mm_players rp ON rp.steam_id = r.reporter_id
        LEFT JOIN mm_matches  m  ON m.id = r.match_id
        WHERE r.reported_id = :sid
          AND r.reviewed = 0
        ORDER BY r.created_at DESC
        """,
        {"sid": reported_id},
    )
    return render_template(
        "admin/report_detail.html",
        reported_id=reported_id,
        player=player,
        individual_reports=individual_reports,
        current_role=_current_role(),
    )


@admin_bp.route("/reports/<reported_id>/dismiss", methods=["POST"])
@require_role("moderator")
@limiter.limit("30 per minute")
def report_dismiss(reported_id: str) -> object:
    execute_db(
        "UPDATE mm_reports SET reviewed = 1 WHERE reported_id = :rid",
        {"rid": reported_id},
    )
    _log_action("report_dismiss", "player", reported_id, "All reports marked reviewed")
    flash(f"Reports for {reported_id} marked as reviewed.", "success")
    return redirect(url_for("admin_bp.reports"))


# ---------------------------------------------------------------------------
# Activity log
# ---------------------------------------------------------------------------

@admin_bp.route("/log")
@require_role("admin")
def activity_log() -> str:
    page = max(1, request.args.get("page", 1, type=int))
    per_page = 50
    admin_filter = request.args.get("admin_id", "").strip()
    action_filter = request.args.get("action", "").strip()

    where_parts = []
    params: dict = {}
    if admin_filter:
        where_parts.append("l.admin_id = :admin_id")
        params["admin_id"] = admin_filter
    if action_filter:
        where_parts.append("l.action LIKE :action")
        params["action"] = f"%{action_filter}%"

    where_clause = ("WHERE " + " AND ".join(where_parts)) if where_parts else ""

    total_row = query_one(
        f"SELECT COUNT(*) AS cnt FROM mm_admin_log l {where_clause}", params
    )
    total = int((total_row or {}).get("cnt", 0))
    total_pages = max(1, (total + per_page - 1) // per_page)

    params["limit"] = per_page
    params["offset"] = (page - 1) * per_page

    log_entries = query_db(
        f"""
        SELECT l.id, l.admin_id, COALESCE(p.name, l.admin_id) AS admin_name,
               l.action, l.target_type, l.target_id, l.detail, l.created_at
        FROM mm_admin_log l
        LEFT JOIN mm_players p ON p.steam_id = l.admin_id
        {where_clause}
        ORDER BY l.created_at DESC
        LIMIT :limit OFFSET :offset
        """,
        params,
    )
    # distinct admins for filter dropdown
    all_admins = query_db(
        """
        SELECT DISTINCT l.admin_id, COALESCE(p.name, l.admin_id) AS name
        FROM mm_admin_log l
        LEFT JOIN mm_players p ON p.steam_id = l.admin_id
        ORDER BY name ASC
        """
    )
    return render_template(
        "admin/log.html",
        log_entries=log_entries,
        all_admins=all_admins,
        admin_filter=admin_filter,
        action_filter=action_filter,
        page=page,
        total_pages=total_pages,
        total=total,
        current_role=_current_role(),
    )


# ---------------------------------------------------------------------------
# Season management  (superadmin only)
# ---------------------------------------------------------------------------

@admin_bp.route("/seasons")
@require_role("superadmin")
def seasons() -> str:
    all_seasons = query_db(
        "SELECT id, name, start_date, end_date, is_active, elo_reset_to FROM mm_seasons ORDER BY start_date DESC"
    )
    return render_template("admin/seasons.html", seasons=all_seasons,
                           current_role=_current_role())


@admin_bp.route("/seasons/new", methods=["POST"])
@require_role("superadmin")
@limiter.limit("5 per minute")
def season_new() -> object:
    name = request.form.get("name", "").strip()
    elo_reset_raw = request.form.get("elo_reset_to", "1000").strip()

    if not name:
        flash("Season name is required.", "error")
        return redirect(url_for("admin_bp.seasons"))

    try:
        elo_reset_to = int(elo_reset_raw)
        if not 0 <= elo_reset_to <= 9999:
            raise ValueError
    except ValueError:
        flash("ELO reset value must be an integer between 0 and 9999.", "error")
        return redirect(url_for("admin_bp.seasons"))

    try:
        mm_path = os.path.join(os.path.dirname(__file__), "..", "..", "matchmaker")
        if mm_path not in sys.path:
            sys.path.insert(0, mm_path)
        from matchmaker.season_manager import SeasonManager  # type: ignore[import]
        from matchmaker.db import Database  # type: ignore[import]
        db = Database(
            host=current_app.config["DB_HOST"],
            port=int(current_app.config["DB_PORT"]),
            user=current_app.config["DB_USER"],
            password=current_app.config["DB_PASS"],
            database=current_app.config["DB_NAME"],
        )
        mgr = SeasonManager(db)
        new_id = mgr.start_new_season(name, elo_reset_to)
        _log_action("season_new", "season", str(new_id), f"'{name}', ELO reset to {elo_reset_to}")
        flash(f"Season '{name}' started (ID {new_id}). ELO soft-reset applied to all players.", "success")
    except Exception as exc:
        current_app.logger.error("Failed to start new season: %s", exc)
        flash(f"Failed to start season: {exc}", "error")

    return redirect(url_for("admin_bp.seasons"))


# ---------------------------------------------------------------------------
# Error handlers
# ---------------------------------------------------------------------------

@admin_bp.errorhandler(403)
def admin_forbidden(e: Exception) -> tuple:
    flash("Authentication required.", "error")
    return redirect(url_for("admin_bp.login")), 302
