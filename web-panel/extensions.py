"""
Flask extension instances shared across the application.

Defined here to avoid circular imports between app.py and route blueprints.
"""

from flask_caching import Cache

# Initialised in app.py via cache.init_app(app, ...)
cache: Cache = Cache()
