"""
Backend factory functions for the CS:GO matchmaking daemon.

Each ``create_*`` function reads the appropriate ``*_BACKEND`` configuration
value and returns a fully-initialised concrete backend instance.  Raise
:exc:`ValueError` for unrecognised backend names so misconfiguration is
caught at startup rather than at runtime.
"""

from __future__ import annotations

import logging

from matchmaker.interfaces.notification import NotificationBackend
from matchmaker.interfaces.queue_backend import QueueBackend
from matchmaker.interfaces.ranking import RankingBackend
from matchmaker.interfaces.server_backend import ServerBackend

logger = logging.getLogger(__name__)


def create_queue_backend(config: object, db: object) -> QueueBackend:
    """Instantiate and return the configured queue backend.

    Args:
        config: Application :class:`~matchmaker.config.Config` instance.
            The ``QUEUE_BACKEND`` attribute selects the implementation.
        db: :class:`~matchmaker.db.Database` instance to inject into the
            backend.

    Returns:
        Concrete :class:`~matchmaker.interfaces.queue_backend.QueueBackend`.

    Raises:
        ValueError: If ``config.QUEUE_BACKEND`` is not a recognised value.
    """
    backend_name: str = getattr(config, "QUEUE_BACKEND", "mysql").lower()

    if backend_name == "mysql":
        from matchmaker.backends.mysql_queue import MySQLQueueBackend

        logger.info("Queue backend: MySQLQueueBackend")
        return MySQLQueueBackend(config=config, db=db)

    raise ValueError(
        f"Unknown QUEUE_BACKEND={backend_name!r}. "
        "Supported values: 'mysql'"
    )


def create_server_backend(config: object) -> ServerBackend:
    """Instantiate and return the configured server backend.

    Args:
        config: Application :class:`~matchmaker.config.Config` instance.
            The ``SERVER_BACKEND`` attribute selects the implementation.

    Returns:
        Concrete :class:`~matchmaker.interfaces.server_backend.ServerBackend`.

    Raises:
        ValueError: If ``config.SERVER_BACKEND`` is not a recognised value.
    """
    backend_name: str = getattr(config, "SERVER_BACKEND", "docker").lower()

    if backend_name == "docker":
        from matchmaker.backends.docker_server import DockerServerBackend

        logger.info("Server backend: DockerServerBackend")
        return DockerServerBackend(config=config)

    raise ValueError(
        f"Unknown SERVER_BACKEND={backend_name!r}. "
        "Supported values: 'docker'"
    )


def create_ranking_backend(config: object, db: object) -> RankingBackend:
    """Instantiate and return the configured ranking backend.

    Args:
        config: Application :class:`~matchmaker.config.Config` instance.
            The ``RANKING_BACKEND`` attribute selects the implementation.
        db: :class:`~matchmaker.db.Database` instance to inject into the
            backend (used for ELO history persistence).

    Returns:
        Concrete :class:`~matchmaker.interfaces.ranking.RankingBackend`.

    Raises:
        ValueError: If ``config.RANKING_BACKEND`` is not a recognised value.
    """
    backend_name: str = getattr(config, "RANKING_BACKEND", "elo").lower()

    if backend_name == "elo":
        from matchmaker.backends.elo_ranking import EloRankingBackend

        logger.info("Ranking backend: EloRankingBackend")
        return EloRankingBackend(config=config, db=db)

    raise ValueError(
        f"Unknown RANKING_BACKEND={backend_name!r}. "
        "Supported values: 'elo'"
    )


def create_notification_backend(config: object) -> NotificationBackend:
    """Instantiate and return the configured notification backend.

    Args:
        config: Application :class:`~matchmaker.config.Config` instance.
            The ``NOTIFICATION_BACKEND`` attribute selects the implementation.

    Returns:
        Concrete :class:`~matchmaker.interfaces.notification.NotificationBackend`.

    Raises:
        ValueError: If ``config.NOTIFICATION_BACKEND`` is not a recognised
            value.
    """
    backend_name: str = getattr(config, "NOTIFICATION_BACKEND", "discord").lower()

    if backend_name == "discord":
        from matchmaker.backends.discord_notifier import DiscordNotifier

        logger.info("Notification backend: DiscordNotifier")
        return DiscordNotifier(config=config)

    if backend_name in ("none", "noop", "null"):
        from matchmaker.backends.noop_notifier import NoopNotifier

        logger.info("Notification backend: NoopNotifier")
        return NoopNotifier()

    raise ValueError(
        f"Unknown NOTIFICATION_BACKEND={backend_name!r}. "
        "Supported values: 'discord', 'none'"
    )
