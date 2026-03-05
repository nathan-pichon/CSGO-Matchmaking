"""
Abstract base class for the game-server backend.

Concrete implementations (e.g. Docker, bare-metal) must subclass
:class:`ServerBackend` and implement every abstract method.
"""

from __future__ import annotations

from abc import ABC, abstractmethod


class ServerBackend(ABC):
    """Interface for spinning up and tearing down CS:GO game servers."""

    @abstractmethod
    def create_server(
        self,
        match_id: int,
        match_token: str,
        server_port: int,
        tv_port: int,
        gslt_token: str,
        map_name: str,
        team1_steam_ids: list[str],
        team2_steam_ids: list[str],
        db_config: dict,
    ) -> str:
        """Start a new game server for the given match.

        Args:
            match_id: Database ID of the match.
            match_token: Unique token string for the match (used by plugins).
            server_port: UDP port the game server should listen on.
            tv_port: UDP port for SourceTV.
            gslt_token: Steam Game Server Login Token.
            map_name: Starting map (e.g. ``de_dust2``).
            team1_steam_ids: List of Steam IDs for team 1.
            team2_steam_ids: List of Steam IDs for team 2.
            db_config: Dict with keys ``host``, ``port``, ``user``,
                ``password``, ``database`` for the game server plugin to
                connect back to the database.

        Returns:
            The container/process ID of the started server as a string.
            Raise on unrecoverable error (caller will log and skip).
        """

    @abstractmethod
    def destroy_server(self, container_id: str, match_id: int) -> bool:
        """Stop and remove a running server.

        Args:
            container_id: The container/process ID returned by
                :py:meth:`create_server`.
            match_id: Database ID of the match (for logging purposes).

        Returns:
            True if the server was successfully stopped and removed, False
            if it could not be found or removal failed.
        """

    @abstractmethod
    def get_server_status(self, container_id: str) -> str:
        """Query the current status of a server.

        Args:
            container_id: The container/process ID to query.

        Returns:
            One of ``'running'``, ``'stopped'``, or ``'not_found'``.
        """

    @abstractmethod
    def cleanup_finished_servers(self, matches: list[dict]) -> list[str]:
        """Bulk-clean containers for matches that are fully finished.

        Args:
            matches: List of match dicts (from the DB) that have
                ``status`` in ``{'finished', 'cancelled', 'error'}`` and
                ``cleaned_up=False``.  Each dict must contain at least
                ``id`` and ``docker_container_id``.

        Returns:
            List of container IDs that were successfully cleaned up.
        """
