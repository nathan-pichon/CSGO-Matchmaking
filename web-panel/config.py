"""
Configuration module for the CS:GO Matchmaking web panel.
Loads settings from ../config.env via python-dotenv.
"""

import os
from dotenv import load_dotenv

# Load environment variables from the shared config file one level up
load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), "..", "config.env"))


class Config:
    """Base configuration loaded from environment variables."""

    # Database
    DB_HOST: str = os.getenv("DB_HOST", "127.0.0.1")
    DB_PORT: str = os.getenv("DB_PORT", "3306")
    DB_USER: str = os.getenv("DB_USER", "root")
    DB_PASS: str = os.getenv("DB_PASS", "")
    DB_NAME: str = os.getenv("DB_NAME", "csgo_mm")

    SQLALCHEMY_DATABASE_URI: str = (
        f"mysql+pymysql://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
        "?charset=utf8mb4"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS: bool = False

    # Flask
    SECRET_KEY: str = os.getenv("SECRET_KEY", "change-me-in-production")

    # Web server
    WEB_HOST: str = os.getenv("WEB_HOST", "0.0.0.0")
    WEB_PORT: int = int(os.getenv("WEB_PORT", "5000"))

    # Caching
    CACHE_TYPE: str = "SimpleCache"
    CACHE_TIMEOUT: int = 30  # seconds

    # Pagination
    LEADERBOARD_PER_PAGE: int = 25
    MATCHES_PER_PAGE: int = 20
