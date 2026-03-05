"""
Unit tests for the Docker server backend (match_creator).

All Docker API calls are mocked — no real Docker daemon needed.
"""
import pytest
from unittest.mock import MagicMock, patch, call
from datetime import datetime


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def mock_config():
    cfg = MagicMock()
    cfg.SERVER_IP = "1.2.3.4"
    cfg.LOBBY_IP = "1.2.3.4"
    cfg.LOBBY_PORT = 27015
    cfg.RCON_PASSWORD = "rconpass"
    cfg.DOCKER_IMAGE = "csgo-match-server:latest"
    cfg.DOCKER_NETWORK = "host"
    return cfg


@pytest.fixture
def mock_db():
    return MagicMock()


@pytest.fixture
def docker_backend(mock_config, mock_db):
    """DockerServerBackend with docker.from_env patched out."""
    with patch("docker.from_env") as mock_docker_fn:
        mock_client = MagicMock()
        mock_docker_fn.return_value = mock_client
        from backends.docker_server import DockerServerBackend
        backend = DockerServerBackend(mock_config)
        backend._client = mock_client       # expose for assertions
        yield backend, mock_client


# ---------------------------------------------------------------------------
# create_server
# ---------------------------------------------------------------------------

class TestCreateServer:
    def test_returns_container_id(self, docker_backend):
        backend, mock_client = docker_backend
        mock_container = MagicMock()
        mock_container.id = "abc123def456"
        mock_client.containers.run.return_value = mock_container

        container_id = backend.create_server(
            match_id=42,
            match_token="deadbeef" * 8,
            server_port=27020,
            tv_port=27120,
            gslt_token="mygslttoken",
            map_name="de_mirage",
            team1_steam_ids=["STEAM_0:0:1", "STEAM_0:0:2", "STEAM_0:0:3", "STEAM_0:0:4", "STEAM_0:0:5"],
            team2_steam_ids=["STEAM_0:1:1", "STEAM_0:1:2", "STEAM_0:1:3", "STEAM_0:1:4", "STEAM_0:1:5"],
            db_config=MagicMock(),
        )

        assert container_id == "abc123def456"

    def test_calls_docker_run_with_host_network(self, docker_backend):
        backend, mock_client = docker_backend
        mock_client.containers.run.return_value = MagicMock(id="cid")

        backend.create_server(
            match_id=1, match_token="tok", server_port=27020, tv_port=27120,
            gslt_token="gslt", map_name="de_dust2",
            team1_steam_ids=["STEAM_0:0:1"] * 5,
            team2_steam_ids=["STEAM_0:1:1"] * 5,
            db_config=MagicMock(),
        )

        _, kwargs = mock_client.containers.run.call_args
        assert kwargs.get("network_mode") == "host", "Match servers must use host networking"

    def test_env_contains_match_token(self, docker_backend):
        backend, mock_client = docker_backend
        mock_client.containers.run.return_value = MagicMock(id="cid")
        token = "cafebabe12345678"

        backend.create_server(
            match_id=7, match_token=token, server_port=27021, tv_port=27121,
            gslt_token="gslt", map_name="de_nuke",
            team1_steam_ids=["STEAM_0:0:1"] * 5,
            team2_steam_ids=["STEAM_0:1:1"] * 5,
            db_config=MagicMock(),
        )

        _, kwargs = mock_client.containers.run.call_args
        env = kwargs.get("environment", {})
        assert env.get("MM_MATCH_TOKEN") == token

    def test_env_contains_correct_ports(self, docker_backend):
        backend, mock_client = docker_backend
        mock_client.containers.run.return_value = MagicMock(id="cid")

        backend.create_server(
            match_id=5, match_token="tok", server_port=27023, tv_port=27123,
            gslt_token="gslt", map_name="de_inferno",
            team1_steam_ids=["STEAM_0:0:1"] * 5,
            team2_steam_ids=["STEAM_0:1:1"] * 5,
            db_config=MagicMock(),
        )

        _, kwargs = mock_client.containers.run.call_args
        env = kwargs.get("environment", {})
        assert str(env.get("SRCDS_PORT")) == "27023"
        assert str(env.get("SRCDS_TV_PORT")) == "27123"

    def test_env_contains_team_steamids(self, docker_backend):
        backend, mock_client = docker_backend
        mock_client.containers.run.return_value = MagicMock(id="cid")
        team1 = [f"STEAM_0:0:{i}" for i in range(5)]
        team2 = [f"STEAM_0:1:{i}" for i in range(5)]

        backend.create_server(
            match_id=3, match_token="tok", server_port=27020, tv_port=27120,
            gslt_token="gslt", map_name="de_overpass",
            team1_steam_ids=team1,
            team2_steam_ids=team2,
            db_config=MagicMock(),
        )

        _, kwargs = mock_client.containers.run.call_args
        env = kwargs.get("environment", {})
        team1_env = env.get("MM_TEAM1_STEAMIDS", "")
        team2_env = env.get("MM_TEAM2_STEAMIDS", "")
        for sid in team1:
            assert sid in team1_env, f"{sid} missing from MM_TEAM1_STEAMIDS"
        for sid in team2:
            assert sid in team2_env, f"{sid} missing from MM_TEAM2_STEAMIDS"

    def test_container_name_includes_match_id(self, docker_backend):
        backend, mock_client = docker_backend
        mock_client.containers.run.return_value = MagicMock(id="cid")

        backend.create_server(
            match_id=99, match_token="tok", server_port=27020, tv_port=27120,
            gslt_token="gslt", map_name="de_dust2",
            team1_steam_ids=["STEAM_0:0:1"] * 5,
            team2_steam_ids=["STEAM_0:1:1"] * 5,
            db_config=MagicMock(),
        )

        _, kwargs = mock_client.containers.run.call_args
        name = kwargs.get("name", "")
        assert "99" in name, f"Container name '{name}' should contain match_id 99"

    def test_docker_api_error_is_handled_gracefully(self, docker_backend):
        """A Docker API error must not crash the daemon — return None."""
        import docker.errors
        backend, mock_client = docker_backend
        mock_client.containers.run.side_effect = docker.errors.APIError("Docker daemon not found")

        result = backend.create_server(
            match_id=1, match_token="tok", server_port=27020, tv_port=27120,
            gslt_token="gslt", map_name="de_dust2",
            team1_steam_ids=["STEAM_0:0:1"] * 5,
            team2_steam_ids=["STEAM_0:1:1"] * 5,
            db_config=MagicMock(),
        )

        assert result is None, "create_server should return None on Docker error, not raise"


# ---------------------------------------------------------------------------
# destroy_server
# ---------------------------------------------------------------------------

class TestDestroyServer:
    def test_stops_then_removes_container(self, docker_backend):
        backend, mock_client = docker_backend
        mock_container = MagicMock()
        mock_client.containers.get.return_value = mock_container

        result = backend.destroy_server("abc123", match_id=5)

        mock_container.stop.assert_called_once()
        mock_container.remove.assert_called_once()
        assert result is True

    def test_returns_true_when_already_gone(self, docker_backend):
        """Container not found should not crash — it's already stopped."""
        import docker.errors
        backend, mock_client = docker_backend
        mock_client.containers.get.side_effect = docker.errors.NotFound("Container not found")

        result = backend.destroy_server("gone_container", match_id=1)

        assert result is True, "NotFound during destroy should be treated as success"

    def test_returns_false_on_unexpected_error(self, docker_backend):
        import docker.errors
        backend, mock_client = docker_backend
        mock_client.containers.get.side_effect = docker.errors.APIError("Daemon unreachable")

        result = backend.destroy_server("container_id", match_id=1)

        assert result is False


# ---------------------------------------------------------------------------
# get_server_status
# ---------------------------------------------------------------------------

class TestGetServerStatus:
    def test_running_container(self, docker_backend):
        backend, mock_client = docker_backend
        mock_container = MagicMock()
        mock_container.status = "running"
        mock_client.containers.get.return_value = mock_container

        status = backend.get_server_status("cid")
        assert status == "running"

    def test_exited_container(self, docker_backend):
        backend, mock_client = docker_backend
        mock_container = MagicMock()
        mock_container.status = "exited"
        mock_client.containers.get.return_value = mock_container

        status = backend.get_server_status("cid")
        assert status == "stopped"

    def test_not_found_container(self, docker_backend):
        import docker.errors
        backend, mock_client = docker_backend
        mock_client.containers.get.side_effect = docker.errors.NotFound("gone")

        status = backend.get_server_status("missing_id")
        assert status == "not_found"


# ---------------------------------------------------------------------------
# cleanup_finished_servers
# ---------------------------------------------------------------------------

class TestCleanupFinishedServers:
    def test_cleans_multiple_containers(self, docker_backend):
        backend, mock_client = docker_backend
        mock_container = MagicMock()
        mock_client.containers.get.return_value = mock_container

        matches = [
            {"id": 1, "docker_container_id": "cid1", "server_port": 27020, "gslt_token": "tok1"},
            {"id": 2, "docker_container_id": "cid2", "server_port": 27021, "gslt_token": "tok2"},
        ]

        cleaned = backend.cleanup_finished_servers(matches)

        assert mock_container.stop.call_count == 2
        assert mock_container.remove.call_count == 2
        assert len(cleaned) == 2

    def test_skips_null_container_id(self, docker_backend):
        backend, mock_client = docker_backend

        matches = [
            {"id": 3, "docker_container_id": None, "server_port": 27022, "gslt_token": "tok"},
        ]

        cleaned = backend.cleanup_finished_servers(matches)

        mock_client.containers.get.assert_not_called()
        assert cleaned == []

    def test_continues_after_partial_failure(self, docker_backend):
        """One container failing to clean up should not block others."""
        import docker.errors
        backend, mock_client = docker_backend

        # First container raises, second succeeds
        good_container = MagicMock()
        mock_client.containers.get.side_effect = [
            docker.errors.APIError("oops"),
            good_container,
        ]

        matches = [
            {"id": 1, "docker_container_id": "fail_cid", "server_port": 27020, "gslt_token": "t1"},
            {"id": 2, "docker_container_id": "good_cid", "server_port": 27021, "gslt_token": "t2"},
        ]

        cleaned = backend.cleanup_finished_servers(matches)

        good_container.stop.assert_called_once()
        # Should have cleaned at least the successful one
        assert "good_cid" in cleaned
