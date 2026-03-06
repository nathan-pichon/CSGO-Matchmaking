"""
Flask extension instances shared across the application.

Defined here to avoid circular imports between app.py and route blueprints.
"""

from flask_caching import Cache
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

# Initialised in app.py via cache.init_app(app, ...)
cache: Cache = Cache()

# Rate limiter keyed by client IP.
# Initialised in app.py via limiter.init_app(app).
limiter: Limiter = Limiter(key_func=get_remote_address)
