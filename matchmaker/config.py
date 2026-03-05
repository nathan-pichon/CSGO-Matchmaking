"""
Configuration loader for the CS:GO matchmaking daemon.

Reads all settings from a ``config.env`` file located in the same directory
as this module (or from any file path passed explicitly) using python-dotenv.
All values are exposed as typed attributes on the singleton ``Config`` instance.
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv


class Config:
    """Typed configuration container loaded from environment variables.

    Call :py:meth:`load` before accessing any attributes, or use the
    module-level singleton :data:`config` which is loaded automatically on
    import.

    Attributes are grouped by concern:

    - **Database** – ``DB_HOST``, ``DB_PORT``, ``DB_USER``, ``DB_PASS``,
      ``DB_NAME``
    - **Matchmaking tuning** – ``POLL_INTERVAL``, ``PLAYERS_PER_TEAM``,
      ``MAX_ELO_SPREAD``, ``ELO_SPREAD_INCREASE_INTERVAL``,
      ``ELO_SPREAD_INCREASE_AMOUNT``
    - **Timeouts** – ``READY_CHECK_TIMEOUT``, ``WARMUP_TIMEOUT``
    - **ELO** – ``ELO_K_FACTOR``, ``ELO_K_FACTOR_NEW``, ``ELO_DEFAULT``,
      ``MIN_PLACEMENT_MATCHES``
    - **Backends** – ``QUEUE_BACKEND``, ``SERVER_BACKEND``,
      ``NOTIFICATION_BACKEND``, ``RANKING_BACKEND``
    - **Networking** – ``SERVER_IP``, ``LOBBY_IP``, ``LOBBY_PORT``,
      ``RCON_PASSWORD``
    - **Docker** – ``DOCKER_IMAGE``, ``DOCKER_NETWORK``
    - **Notifications** – ``DISCORD_WEBHOOK_URL``
    - **Misc** – ``LR_TABLE_NAME``
    """

    def __init__(self) -> None:
        self._loaded: bool = False

        # ------------------------------------------------------------------ #
        # Database
        # ------------------------------------------------------------------ #
        self.DB_HOST: str = "127.0.0.1"
        self.DB_PORT: int = 3306
        self.DB_USER: str = "root"
        self.DB_PASS: str = ""
        self.DB_NAME: str = "csgo_matchmaking"

        # ------------------------------------------------------------------ #
        # Matchmaking tuning
        # ------------------------------------------------------------------ #
        self.POLL_INTERVAL: float = 2.0
        self.PLAYERS_PER_TEAM: int = 5
        self.MAX_ELO_SPREAD: int = 200
        # Seconds between automatic spread expansions
        self.ELO_SPREAD_INCREASE_INTERVAL: int = 60
        # ELO points added per interval
        self.ELO_SPREAD_INCREASE_AMOUNT: int = 50

        # ------------------------------------------------------------------ #
        # Timeouts (seconds)
        # ------------------------------------------------------------------ #
        self.READY_CHECK_TIMEOUT: int = 30
        self.WARMUP_TIMEOUT: int = 300

        # ------------------------------------------------------------------ #
        # ELO / ranking
        # ------------------------------------------------------------------ #
        self.MIN_PLACEMENT_MATCHES: int = 10
        self.ELO_K_FACTOR: int = 32
        self.ELO_K_FACTOR_NEW: int = 64
        self.ELO_DEFAULT: int = 1000

        # ------------------------------------------------------------------ #
        # Backend selection
        # ------------------------------------------------------------------ #
        self.QUEUE_BACKEND: str = "mysql"
        self.SERVER_BACKEND: str = "docker"
        self.NOTIFICATION_BACKEND: str = "discord"
        self.RANKING_BACKEND: str = "elo"

        # ------------------------------------------------------------------ #
        # Networking
        # ------------------------------------------------------------------ #
        self.SERVER_IP: str = "127.0.0.1"
        self.LOBBY_IP: str = "127.0.0.1"
        self.LOBBY_PORT: int = 27015
        self.RCON_PASSWORD: str = ""

        # ------------------------------------------------------------------ #
        # Docker
        # ------------------------------------------------------------------ #
        self.DOCKER_IMAGE: str = "cm2network/csgo:latest"
        self.DOCKER_NETWORK: str = "host"

        # ------------------------------------------------------------------ #
        # Discord
        # ------------------------------------------------------------------ #
        self.DISCORD_WEBHOOK_URL: str = ""

        # ------------------------------------------------------------------ #
        # Misc
        # ------------------------------------------------------------------ #
        self.LR_TABLE_NAME: str = "lvl_base"

    # ---------------------------------------------------------------------- #
    # Public API
    # ---------------------------------------------------------------------- #

    def load(self, env_file: str | Path | None = None) -> "Config":
        """Load configuration from the given env file (or auto-discover).

        Args:
            env_file: Path to the ``.env`` / ``config.env`` file.  When
                *None*, the loader looks for ``config.env`` in the same
                directory as this Python file, falling back to a plain
                ``.env`` in the current working directory.

        Returns:
            The same :class:`Config` instance (for chaining).
        """
        if env_file is None:
            candidate = Path(__file__).parent / "config.env"
            if candidate.exists():
                env_file = candidate
            else:
                env_file = Path(os.getcwd()) / "config.env"

        load_dotenv(dotenv_path=str(env_file), override=False)

        # ------------------------------------------------------------------ #
        # Database
        # ------------------------------------------------------------------ #
        self.DB_HOST = os.getenv("DB_HOST", self.DB_HOST)
        self.DB_PORT = int(os.getenv("DB_PORT", str(self.DB_PORT)))
        self.DB_USER = os.getenv("DB_USER", self.DB_USER)
        self.DB_PASS = os.getenv("DB_PASS", self.DB_PASS)
        self.DB_NAME = os.getenv("DB_NAME", self.DB_NAME)

        # ------------------------------------------------------------------ #
        # Matchmaking tuning
        # ------------------------------------------------------------------ #
        self.POLL_INTERVAL = float(
            os.getenv("POLL_INTERVAL", str(self.POLL_INTERVAL))
        )
        self.PLAYERS_PER_TEAM = int(
            os.getenv("PLAYERS_PER_TEAM", str(self.PLAYERS_PER_TEAM))
        )
        self.MAX_ELO_SPREAD = int(
            os.getenv("MAX_ELO_SPREAD", str(self.MAX_ELO_SPREAD))
        )
        self.ELO_SPREAD_INCREASE_INTERVAL = int(
            os.getenv(
                "ELO_SPREAD_INCREASE_INTERVAL",
                str(self.ELO_SPREAD_INCREASE_INTERVAL),
            )
        )
        self.ELO_SPREAD_INCREASE_AMOUNT = int(
            os.getenv(
                "ELO_SPREAD_INCREASE_AMOUNT",
                str(self.ELO_SPREAD_INCREASE_AMOUNT),
            )
        )

        # ------------------------------------------------------------------ #
        # Timeouts
        # ------------------------------------------------------------------ #
        self.READY_CHECK_TIMEOUT = int(
            os.getenv("READY_CHECK_TIMEOUT", str(self.READY_CHECK_TIMEOUT))
        )
        self.WARMUP_TIMEOUT = int(
            os.getenv("WARMUP_TIMEOUT", str(self.WARMUP_TIMEOUT))
        )

        # ------------------------------------------------------------------ #
        # ELO / ranking
        # ------------------------------------------------------------------ #
        self.MIN_PLACEMENT_MATCHES = int(
            os.getenv("MIN_PLACEMENT_MATCHES", str(self.MIN_PLACEMENT_MATCHES))
        )
        self.ELO_K_FACTOR = int(
            os.getenv("ELO_K_FACTOR", str(self.ELO_K_FACTOR))
        )
        self.ELO_K_FACTOR_NEW = int(
            os.getenv("ELO_K_FACTOR_NEW", str(self.ELO_K_FACTOR_NEW))
        )
        self.ELO_DEFAULT = int(
            os.getenv("ELO_DEFAULT", str(self.ELO_DEFAULT))
        )

        # ------------------------------------------------------------------ #
        # Backend selection
        # ------------------------------------------------------------------ #
        self.QUEUE_BACKEND = os.getenv("QUEUE_BACKEND", self.QUEUE_BACKEND)
        self.SERVER_BACKEND = os.getenv("SERVER_BACKEND", self.SERVER_BACKEND)
        self.NOTIFICATION_BACKEND = os.getenv(
            "NOTIFICATION_BACKEND", self.NOTIFICATION_BACKEND
        )
        self.RANKING_BACKEND = os.getenv("RANKING_BACKEND", self.RANKING_BACKEND)

        # ------------------------------------------------------------------ #
        # Networking
        # ------------------------------------------------------------------ #
        self.SERVER_IP = os.getenv("SERVER_IP", self.SERVER_IP)
        self.LOBBY_IP = os.getenv("LOBBY_IP", self.LOBBY_IP)
        self.LOBBY_PORT = int(os.getenv("LOBBY_PORT", str(self.LOBBY_PORT)))
        self.RCON_PASSWORD = os.getenv("RCON_PASSWORD", self.RCON_PASSWORD)

        # ------------------------------------------------------------------ #
        # Docker
        # ------------------------------------------------------------------ #
        self.DOCKER_IMAGE = os.getenv("DOCKER_IMAGE", self.DOCKER_IMAGE)
        self.DOCKER_NETWORK = os.getenv("DOCKER_NETWORK", self.DOCKER_NETWORK)

        # ------------------------------------------------------------------ #
        # Discord
        # ------------------------------------------------------------------ #
        self.DISCORD_WEBHOOK_URL = os.getenv(
            "DISCORD_WEBHOOK_URL", self.DISCORD_WEBHOOK_URL
        )

        # ------------------------------------------------------------------ #
        # Misc
        # ------------------------------------------------------------------ #
        self.LR_TABLE_NAME = os.getenv("LR_TABLE_NAME", self.LR_TABLE_NAME)

        self._loaded = True
        return self

    @property
    def db_config(self) -> dict:
        """Return a dict suitable for passing to mysql.connector.connect()."""
        return {
            "host": self.DB_HOST,
            "port": self.DB_PORT,
            "user": self.DB_USER,
            "password": self.DB_PASS,
            "database": self.DB_NAME,
        }

    @property
    def players_per_match(self) -> int:
        """Total players required to form one match (both teams)."""
        return self.PLAYERS_PER_TEAM * 2

    def __repr__(self) -> str:
        return (
            f"Config(DB_HOST={self.DB_HOST!r}, DB_NAME={self.DB_NAME!r}, "
            f"PLAYERS_PER_TEAM={self.PLAYERS_PER_TEAM}, "
            f"MAX_ELO_SPREAD={self.MAX_ELO_SPREAD})"
        )


# Module-level singleton – loaded lazily on first access via :func:`get_config`.
_config_instance: Config | None = None


def get_config(env_file: str | Path | None = None) -> Config:
    """Return the module-level :class:`Config` singleton.

    The first call loads the configuration from *env_file* (or auto-discovers
    ``config.env``).  Subsequent calls return the already-loaded instance.

    Args:
        env_file: Optional explicit path to the env file.  Only used on the
            first call; ignored afterwards.

    Returns:
        The loaded :class:`Config` singleton.
    """
    global _config_instance
    if _config_instance is None:
        _config_instance = Config().load(env_file)
    return _config_instance


# Convenience alias – import ``config`` directly and use its attributes.
config: Config = get_config()
