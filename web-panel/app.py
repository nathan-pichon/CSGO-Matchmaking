"""
Flask application factory for the CS:GO Matchmaking web panel.
"""

from __future__ import annotations

from flask import Flask, render_template, session

from config import Config
from extensions import cache, limiter
from models import db, query_one


def _seed_super_admin(app: Flask) -> None:
    """Insert the super-admin Steam ID into mm_admins if not already present.

    Idempotent: does nothing if the row already exists or if
    ``SUPER_ADMIN_STEAM_ID`` is not set.
    """
    steam_id = app.config.get("SUPER_ADMIN_STEAM_ID", "").strip()
    if not steam_id:
        return

    from models import execute_db, query_one

    with app.app_context():
        existing = query_one(
            "SELECT steam_id FROM mm_admins WHERE steam_id = :sid",
            {"sid": steam_id},
        )
        if existing:
            app.logger.info(
                "[MM] Super-admin %s already registered — skipping seed.", steam_id
            )
            return

        try:
            execute_db(
                """
                INSERT INTO mm_admins (steam_id, role, added_by, notes)
                VALUES (:sid, 'superadmin', NULL,
                        'Seeded from SUPER_ADMIN_STEAM_ID env var')
                """,
                {"sid": steam_id},
            )
            app.logger.info(
                "[MM] Super-admin seeded: %s — first login at /admin/login",
                steam_id,
            )
        except Exception as exc:
            app.logger.error(
                "[MM] Failed to seed super-admin %s: %s", steam_id, exc
            )


def create_app(config_class: type = Config) -> Flask:
    """
    Create and configure the Flask application.

    Args:
        config_class: Configuration class to use (defaults to Config).

    Returns:
        Configured Flask application instance.
    """
    app = Flask(__name__)
    app.config.from_object(config_class)

    # Initialise extensions
    db.init_app(app)
    cache.init_app(app, config={
        "CACHE_TYPE": config_class.CACHE_TYPE,
        "CACHE_DEFAULT_TIMEOUT": config_class.CACHE_TIMEOUT,
    })
    limiter.init_app(app)

    # Seed super-admin from env var (idempotent, runs once per startup)
    _seed_super_admin(app)

    # Register blueprints
    from routes.auth import auth_bp
    from routes.home import home_bp
    from routes.leaderboard import leaderboard_bp
    from routes.players import players_bp
    from routes.matches import matches_bp
    from routes.api import api_bp
    from routes.admin import admin_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(home_bp)
    app.register_blueprint(leaderboard_bp)
    app.register_blueprint(players_bp)
    app.register_blueprint(matches_bp)
    app.register_blueprint(api_bp, url_prefix="/api")
    app.register_blueprint(admin_bp)

    # ---------------------------------------------------------------------------
    # Context processor — inject queue count + current_user into every template
    # ---------------------------------------------------------------------------
    @app.context_processor
    def inject_globals() -> dict:
        """Inject live queue count and logged-in user info into all templates."""
        try:
            row = query_one(
                "SELECT COUNT(*) AS cnt FROM mm_queue WHERE status = 'searching'"
            )
            count = int(row["cnt"]) if row else 0
        except Exception:
            count = 0

        current_user = None
        if session.get("is_logged_in"):
            current_user = {
                "steam_id":   session.get("steam_id", ""),
                "steam_name": session.get("steam_name", ""),
                "is_admin":   session.get("is_admin", False),
                "admin_role": session.get("admin_role", ""),
            }

        return {"queue_count": count, "current_user": current_user}

    # ---------------------------------------------------------------------------
    # Error handlers
    # ---------------------------------------------------------------------------
    @app.errorhandler(404)
    def not_found(e: Exception) -> tuple:
        """Render a custom 404 page."""
        return render_template("errors/404.html"), 404

    @app.errorhandler(500)
    def internal_error(e: Exception) -> tuple:
        """Render a custom 500 page."""
        return render_template("errors/500.html"), 500

    return app


if __name__ == "__main__":
    application = create_app()
    application.run(
        host=Config.WEB_HOST,
        port=Config.WEB_PORT,
        debug=False,
    )
