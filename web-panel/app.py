"""
Flask application factory for the CS:GO Matchmaking web panel.
"""

from __future__ import annotations

from flask import Flask, redirect, render_template, url_for

from config import Config
from extensions import cache, limiter
from models import db, query_one


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

    # Register blueprints
    from routes.leaderboard import leaderboard_bp
    from routes.players import players_bp
    from routes.matches import matches_bp
    from routes.api import api_bp
    from routes.admin import admin_bp

    app.register_blueprint(leaderboard_bp)
    app.register_blueprint(players_bp)
    app.register_blueprint(matches_bp)
    app.register_blueprint(api_bp, url_prefix="/api")
    app.register_blueprint(admin_bp)

    # ---------------------------------------------------------------------------
    # Context processor — inject queue count into every template
    # ---------------------------------------------------------------------------
    @app.context_processor
    def inject_queue_count() -> dict:
        """Inject the live queue player count into all template contexts."""
        try:
            row = query_one(
                "SELECT COUNT(*) AS cnt FROM mm_queue WHERE status = 'searching'"
            )
            count = int(row["cnt"]) if row else 0
        except Exception:
            count = 0
        return {"queue_count": count}

    # ---------------------------------------------------------------------------
    # Root redirect
    # ---------------------------------------------------------------------------
    @app.route("/")
    def index() -> object:
        """Redirect root URL to the leaderboard page."""
        return redirect(url_for("leaderboard_bp.leaderboard"))

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
