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
        SELECT id, match_token, map_name, status, port,
               docker_container_id, started_at
        FROM mm_matches
        WHERE status IN ('creating', 'warmup', 'live')
        ORDER BY started_at DESC
        """
    )
    queue_count = query_one(
        "SELECT COUNT(*) AS cnt FROM mm_queue WHERE status = 'waiting'"
    )
    active_bans = query_one(
        "SELECT COUNT(*) AS cnt FROM mm_bans WHERE expires_at > NOW() OR expires_at IS NULL"
    )
    return render_template(
        "admin/dashboard.html",
        live_matches=live_matches,
        queue_count=int(queue_count["cnt"]) if queue_count else 0,
        active_bans=int(active_bans["cnt"]) if active_bans else 0,
        current_role=_current_role(),
    )


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
    return render_template("admin/bans.html", bans=active_bans,
                           current_role=_current_role())


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
            reason     = VALUES(reason),
            banned_by  = VALUES(banned_by),
            created_at = VALUES(created_at),
            expires_at = VALUES(expires_at)
        """,
        {"sid": steam_id, "reason": reason, "by": by, "dur": duration_int},
    )
    execute_db(
        "UPDATE mm_players SET is_banned = 1 WHERE steam_id = :sid",
        {"sid": steam_id},
    )
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

    execute_db("DELETE FROM mm_bans WHERE steam_id = :sid", {"sid": steam_id})
    execute_db(
        "UPDATE mm_players SET is_banned = 0 WHERE steam_id = :sid",
        {"sid": steam_id},
    )
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
        flash(f"Admin {steam_id} removed.", "success")
    return redirect(url_for("admin_bp.admin_list"))


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


@admin_bp.route("/reports/<reported_id>/dismiss", methods=["POST"])
@require_role("moderator")
@limiter.limit("30 per minute")
def report_dismiss(reported_id: str) -> object:
    execute_db(
        "UPDATE mm_reports SET reviewed = 1 WHERE reported_id = :rid",
        {"rid": reported_id},
    )
    flash(f"Reports for {reported_id} marked as reviewed.", "success")
    return redirect(url_for("admin_bp.reports"))


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
        flash(f"Role for {steam_id} changed to {new_role}.", "success")
    return redirect(url_for("admin_bp.admin_list"))


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
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "matchmaker"))
        from matchmaker.season_manager import SeasonManager
        from matchmaker.db import Database
        db = Database(
            host=current_app.config["DB_HOST"],
            port=int(current_app.config["DB_PORT"]),
            user=current_app.config["DB_USER"],
            password=current_app.config["DB_PASS"],
            database=current_app.config["DB_NAME"],
        )
        mgr = SeasonManager(db)
        new_id = mgr.start_new_season(name, elo_reset_to)
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
