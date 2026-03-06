"""
Docker-based game server backend for the CS:GO matchmaking daemon.

Implements :class:`~matchmaker.interfaces.server_backend.ServerBackend` using
the official Docker SDK for Python.  Each CS:GO server runs as an isolated
container with ``network_mode='host'`` so the game port is directly reachable
from the host machine.
"""

from __future__ import annotations

import logging
from typing import Optional

import docker
import docker.errors
from docker.models.containers import Container

from matchmaker.interfaces.server_backend import ServerBackend

logger = logging.getLogger(__name__)


class DockerServerBackend(ServerBackend):
    """Docker SDK implementation of :class:`ServerBackend`.

    Args:
        config: Application :class:`~matchmaker.config.Config` instance.
            Used to read ``DOCKER_IMAGE``, ``DOCKER_NETWORK``,
            ``RCON_PASSWORD``, ``SERVER_IP``, ``LOBBY_IP``, and
            ``LOBBY_PORT``.
    """

    def __init__(self, config: object) -> None:
        self._config = config
        self._client: Optional[docker.DockerClient] = None

    # ---------------------------------------------------------------------- #
    # Docker client (lazy init + reconnect)
    # ---------------------------------------------------------------------- #

    def _get_client(self) -> docker.DockerClient:
        """Return (or lazily create) the Docker client.

        Returns:
            An initialised :class:`docker.DockerClient`.

        Raises:
            docker.errors.DockerException: If the Docker daemon is not
                reachable.
        """
        if self._client is None:
            self._client = docker.from_env()
            logger.debug("Docker client connected to daemon")
        return self._client

    def _get_container(self, container_id: str) -> Optional[Container]:
        """Fetch a container object by ID or name.

        Args:
            container_id: Docker container ID or name.

        Returns:
            :class:`Container` or ``None`` if not found.
        """
        try:
            return self._get_client().containers.get(container_id)
        except docker.errors.NotFound:
            return None
        except Exception as exc:
            logger.warning("_get_container(%s): unexpected error: %s", container_id, exc)
            return None

    # ---------------------------------------------------------------------- #
    # ServerBackend implementation
    # ---------------------------------------------------------------------- #

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
        """Start a CS:GO game server container for the given match.

        The container runs with ``network_mode='host'`` so the game and TV
        ports are directly bound to the host interface.  A memory limit of
        2 GB is applied to prevent runaway processes.

        Args:
            match_id: Database ID of the match.
            match_token: Unique token for server-plugin authentication.
            server_port: UDP port for the game server.
            tv_port: UDP port for SourceTV.
            gslt_token: Steam Game Server Login Token.
            map_name: Starting map (e.g. ``de_dust2``).
            team1_steam_ids: List of Steam IDs for team 1.
            team2_steam_ids: List of Steam IDs for team 2.
            db_config: Dict with ``host``, ``port``, ``user``, ``password``,
                ``database`` for the in-game plugin database connection.

        Returns:
            The Docker container ID string.

        Raises:
            docker.errors.ImageNotFound: If the Docker image is missing.
            docker.errors.APIError: On Docker daemon errors.
        """
        cfg = self._config
        image: str = getattr(cfg, "DOCKER_IMAGE", "cm2network/csgo:latest")
        rcon_pw: str = getattr(cfg, "RCON_PASSWORD", "")
        server_ip: str = getattr(cfg, "SERVER_IP", "127.0.0.1")
        lobby_ip: str = getattr(cfg, "LOBBY_IP", "127.0.0.1")
        lobby_port: int = getattr(cfg, "LOBBY_PORT", 27015)

        container_name = f"csgo-match-{match_id}"
        hostname = f"csgo-mm-{match_id}"

        env: dict[str, str] = {
            # SteamCMD / SRCDS core
            "SRCDS_TOKEN": gslt_token,
            "SRCDS_PORT": str(server_port),
            "SRCDS_TV_PORT": str(tv_port),
            "SRCDS_PW": match_token[:16],          # server connect password
            "SRCDS_RCONPW": rcon_pw,
            # Game settings
            "SRCDS_STARTMAP": map_name,
            "SRCDS_MAXPLAYERS": "12",
            "SRCDS_TICKRATE": "128",
            "SRCDS_GAMETYPE": "0",
            "SRCDS_GAMEMODE": "1",
            # Networking
            "SRCDS_HOSTNAME": f"CS:GO MM #{match_id}",
            "SRCDS_NET_PUBLIC_ADDRESS": server_ip,
            "ADDITIONAL_ARGS": "-net_port_try 1",
            # Matchmaking plugin
            "MM_MATCH_TOKEN": match_token,
            "MM_MATCH_ID": str(match_id),
            "MM_LOBBY_IP": lobby_ip,
            "MM_LOBBY_PORT": str(lobby_port),
            # Database for plugin
            "MM_DB_HOST": db_config.get("host", "127.0.0.1"),
            "MM_DB_PORT": str(db_config.get("port", 3306)),
            "MM_DB_USER": db_config.get("user", ""),
            "MM_DB_PASS": db_config.get("password", ""),
            "MM_DB_NAME": db_config.get("database", "csgo_matchmaking"),
            # Teams
            "MM_TEAM1_STEAMIDS": ",".join(team1_steam_ids),
            "MM_TEAM2_STEAMIDS": ",".join(team2_steam_ids),
        }

        logger.info(
            "create_server: starting container=%s image=%s port=%d map=%s",
            container_name, image, server_port, map_name,
        )

        try:
            container: Container = self._get_client().containers.run(
                image=image,
                name=container_name,
                hostname=hostname,
                environment=env,
                network_mode="host",
                mem_limit="2g",
                restart_policy={"Name": "no"},
                detach=True,
                remove=False,  # we remove manually after cleanup
            )
        except docker.errors.ImageNotFound:
            logger.error(
                "create_server: Docker image '%s' not found — "
                "rebuild the image with install.sh (match_id=%d)",
                image, match_id,
            )
            raise RuntimeError(
                f"Docker image '{image}' not found. "
                "Run install.sh to rebuild the match-server image."
            )
        except docker.errors.APIError as exc:
            logger.error(
                "create_server: Docker API error for match_id=%d: %s",
                match_id, exc,
            )
            raise RuntimeError(
                f"Docker API error while starting match server: {exc}"
            ) from exc

        logger.info(
            "create_server: container started id=%s match_id=%d",
            container.id, match_id,
        )
        return container.id

    def destroy_server(self, container_id: str, match_id: int) -> bool:
        """Stop (timeout 10 s) and remove a CS:GO server container.

        Args:
            container_id: Docker container ID or name.
            match_id: Database ID of the match (for logging).

        Returns:
            True if the container was stopped and removed, False if it could
            not be found or removal raised an unexpected error.
        """
        container = self._get_container(container_id)
        if container is None:
            logger.warning(
                "destroy_server: container not found id=%s match_id=%d",
                container_id, match_id,
            )
            return False

        try:
            container.stop(timeout=10)
            logger.info("destroy_server: stopped container=%s match_id=%d", container_id, match_id)
        except docker.errors.APIError as exc:
            logger.warning("destroy_server: stop error container=%s: %s", container_id, exc)

        try:
            container.remove(force=True)
            logger.info("destroy_server: removed container=%s match_id=%d", container_id, match_id)
            return True
        except docker.errors.NotFound:
            # Already removed – treat as success.
            return True
        except docker.errors.APIError as exc:
            logger.error("destroy_server: remove error container=%s: %s", container_id, exc)
            return False

    def get_server_status(self, container_id: str) -> str:
        """Query the Docker status of a CS:GO server container.

        Args:
            container_id: Docker container ID or name.

        Returns:
            One of ``'running'``, ``'stopped'``, or ``'not_found'``.
        """
        container = self._get_container(container_id)
        if container is None:
            return "not_found"

        try:
            container.reload()
            status = container.status  # 'running', 'exited', 'paused', etc.
            if status == "running":
                return "running"
            return "stopped"
        except docker.errors.NotFound:
            return "not_found"
        except Exception as exc:
            logger.warning("get_server_status(%s): error: %s", container_id, exc)
            return "stopped"

    def cleanup_finished_servers(self, matches: list[dict]) -> list[str]:
        """Stop and remove containers for all finished matches.

        Args:
            matches: List of match dicts from the DB with at least the keys
                ``id`` and ``docker_container_id``.

        Returns:
            List of container IDs that were successfully cleaned up.
        """
        cleaned: list[str] = []
        for match in matches:
            match_id = match.get("id")
            container_id = match.get("docker_container_id")

            if not container_id:
                logger.debug(
                    "cleanup_finished_servers: match_id=%s has no container, skipping",
                    match_id,
                )
                continue

            if self.destroy_server(container_id, match_id):
                cleaned.append(container_id)
                logger.info(
                    "cleanup_finished_servers: cleaned container=%s match_id=%s",
                    container_id, match_id,
                )
            else:
                logger.warning(
                    "cleanup_finished_servers: failed to clean container=%s match_id=%s",
                    container_id, match_id,
                )

        return cleaned
