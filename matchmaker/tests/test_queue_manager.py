"""
Unit tests for the MySQL queue backend.

All database calls are mocked – no real MySQL connection is required.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from unittest.mock import MagicMock, patch

import pytest

from matchmaker.backends.mysql_queue import MySQLQueueBackend, _row_to_entry
from matchmaker.models import MatchGroup, QueueEntry


# ---------------------------------------------------------------------------
# Helpers / fixtures
# ---------------------------------------------------------------------------

class FakeConfig:
    """Minimal config stub for testing."""
    MAX_ELO_SPREAD = 200
    ELO_SPREAD_INCREASE_INTERVAL = 60
    ELO_SPREAD_INCREASE_AMOUNT = 50
    players_per_match = 10
    PLAYERS_PER_TEAM = 5


def _make_entry(
    i: int,
    elo: int = 1000,
    status: str = "waiting",
    queued_seconds_ago: int = 0,
    map_preference: str | None = None,
) -> QueueEntry:
    """Build a QueueEntry for testing."""
    return QueueEntry(
        id=i,
        steam_id=f"STEAM_0:0:{i}",
        elo=elo,
        rank_tier=5,
        queued_at=datetime.utcnow() - timedelta(seconds=queued_seconds_ago),
        status=status,
        map_preference=map_preference,
    )


def _make_backend(
    waiting_entries: list[QueueEntry] | None = None,
    map_pool: list[dict] | None = None,
) -> MySQLQueueBackend:
    """Build a MySQLQueueBackend with a mocked Database."""
    mock_db = MagicMock()
    backend = MySQLQueueBackend(config=FakeConfig(), db=mock_db)

    # Stub get_waiting_entries to return the provided entries.
    entries = waiting_entries or []
    backend.get_waiting_entries = MagicMock(return_value=entries)

    # Stub map pool.
    pool = map_pool or [
        {"map_name": "de_dust2", "weight": 10},
        {"map_name": "de_mirage", "weight": 8},
    ]
    mock_db.get_active_map_pool.return_value = pool

    return backend


# ---------------------------------------------------------------------------
# find_balanced_match – player count checks
# ---------------------------------------------------------------------------

class TestFindBalancedMatch:
    """Tests for MySQLQueueBackend.find_balanced_match()."""

    def test_returns_none_with_fewer_than_10_players(self) -> None:
        backend = _make_backend(waiting_entries=[_make_entry(i) for i in range(9)])
        assert backend.find_balanced_match() is None

    def test_returns_none_with_zero_players(self) -> None:
        backend = _make_backend(waiting_entries=[])
        assert backend.find_balanced_match() is None

    def test_returns_match_group_with_exactly_10_players(self) -> None:
        entries = [_make_entry(i, elo=1000) for i in range(10)]
        backend = _make_backend(waiting_entries=entries)
        result = backend.find_balanced_match()
        assert result is not None
        assert isinstance(result, MatchGroup)

    def test_returns_match_group_with_more_than_10_players(self) -> None:
        entries = [_make_entry(i, elo=1000) for i in range(15)]
        backend = _make_backend(waiting_entries=entries)
        result = backend.find_balanced_match()
        assert result is not None
        assert len(result.players) == 10

    def test_match_group_has_correct_team_sizes(self) -> None:
        entries = [_make_entry(i, elo=1000 + i * 10) for i in range(10)]
        backend = _make_backend(waiting_entries=entries)
        result = backend.find_balanced_match()
        assert result is not None
        assert len(result.team1) == 5
        assert len(result.team2) == 5

    def test_match_group_map_is_set(self) -> None:
        entries = [_make_entry(i, elo=1000) for i in range(10)]
        backend = _make_backend(waiting_entries=entries)
        result = backend.find_balanced_match()
        assert result is not None
        assert result.map_name != ""

    def test_returns_none_when_elo_spread_too_large(self) -> None:
        """Players with ELO spread > MAX_ELO_SPREAD should not be grouped."""
        # Player 0 at 1000 ELO; players 1-9 at 2000 ELO – spread = 1000 > 200.
        entries = [_make_entry(0, elo=1000)] + [
            _make_entry(i, elo=2000) for i in range(1, 10)
        ]
        backend = _make_backend(waiting_entries=entries)
        result = backend.find_balanced_match()
        # Can't form a group: anchor at 1000 and next 9 are 1000 away.
        assert result is None


# ---------------------------------------------------------------------------
# ELO spread expansion over time
# ---------------------------------------------------------------------------

class TestEloSpreadExpansion:
    """Test that ELO spread widens as players wait longer."""

    def test_players_matched_after_long_wait_despite_spread(self) -> None:
        """Players who waited > 1 interval should get expanded spread."""
        # Anchor at 1000 ELO, waited 120 s (2 intervals × 50 = +100 spread).
        # Other 9 players at 1250 ELO → spread = 250.
        # Base spread = 200, after 2 intervals = 300 → should match.
        anchor = _make_entry(0, elo=1000, queued_seconds_ago=120)
        others = [_make_entry(i, elo=1250, queued_seconds_ago=120) for i in range(1, 10)]
        entries = [anchor] + others
        backend = _make_backend(waiting_entries=entries)
        result = backend.find_balanced_match()
        assert result is not None, (
            "Players should be matched after spread expansion"
        )

    def test_freshly_queued_players_not_matched_over_base_spread(self) -> None:
        """Freshly queued players must stay within base spread."""
        anchor = _make_entry(0, elo=1000, queued_seconds_ago=0)
        others = [_make_entry(i, elo=1300, queued_seconds_ago=0) for i in range(1, 10)]
        entries = [anchor] + others
        backend = _make_backend(waiting_entries=entries)
        result = backend.find_balanced_match()
        # 300 ELO spread > 200 base → should not match.
        assert result is None


# ---------------------------------------------------------------------------
# Map preference selection
# ---------------------------------------------------------------------------

class TestMapPreferenceSelection:
    """Test map selection logic."""

    def _run_with_preferences(
        self,
        preferences: list[str | None],
        map_pool: list[dict] | None = None,
    ) -> str:
        entries = [
            _make_entry(i, elo=1000, map_preference=pref)
            for i, pref in enumerate(preferences)
        ]
        pool = map_pool or [{"map_name": "de_dust2", "weight": 10}]
        backend = _make_backend(waiting_entries=entries, map_pool=pool)
        result = backend.find_balanced_match()
        assert result is not None
        return result.map_name

    def test_majority_preference_selected(self) -> None:
        """6 out of 10 preferring a map should select that map."""
        prefs = ["de_mirage"] * 6 + ["de_dust2"] * 4
        map_name = self._run_with_preferences(prefs)
        assert map_name == "de_mirage"

    def test_unanimous_preference_selected(self) -> None:
        prefs = ["de_inferno"] * 10
        pool = [{"map_name": "de_inferno", "weight": 10}]
        map_name = self._run_with_preferences(prefs, map_pool=pool)
        assert map_name == "de_inferno"

    def test_no_preference_falls_back_to_pool(self) -> None:
        prefs = [None] * 10
        pool = [{"map_name": "de_overpass", "weight": 10}]
        map_name = self._run_with_preferences(prefs, map_pool=pool)
        assert map_name == "de_overpass"

    def test_tied_preference_resolved_from_pool(self) -> None:
        """A tie in preferences should fall back to the map pool."""
        prefs = ["de_dust2"] * 5 + ["de_mirage"] * 5
        pool = [{"map_name": "de_nuke", "weight": 100}]
        map_name = self._run_with_preferences(prefs, map_pool=pool)
        # Tied preference → pool fallback → de_nuke (only option with weight).
        assert map_name == "de_nuke"


# ---------------------------------------------------------------------------
# Stale entry expiry
# ---------------------------------------------------------------------------

class TestStaleEntryExpiry:
    """Tests for expire_stale_entries()."""

    def test_expire_calls_db_update(self) -> None:
        mock_db = MagicMock()
        # Simulate 3 rows updated.
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_cursor.rowcount = 3
        mock_cursor.__enter__ = MagicMock(return_value=mock_cursor)
        mock_cursor.__exit__ = MagicMock(return_value=False)
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)
        mock_conn.cursor.return_value = mock_cursor
        mock_db.get_connection.return_value = mock_conn

        backend = MySQLQueueBackend(config=FakeConfig(), db=mock_db)
        count = backend.expire_stale_entries(max_wait_minutes=15)

        assert count == 3
        # Verify that get_connection was called (i.e. DB interaction occurred).
        mock_db.get_connection.assert_called()

    def test_expire_returns_zero_on_db_error(self) -> None:
        mock_db = MagicMock()
        mock_db.get_connection.side_effect = Exception("DB is down")

        backend = MySQLQueueBackend(config=FakeConfig(), db=mock_db)
        count = backend.expire_stale_entries(max_wait_minutes=15)

        assert count == 0, "Should return 0 gracefully on DB error"

    def test_expire_stale_ready_checks_returns_zero_when_none(self) -> None:
        mock_db = MagicMock()
        mock_db.query_all.return_value = []  # No stale groups.

        backend = MySQLQueueBackend(config=FakeConfig(), db=mock_db)
        count = backend.expire_stale_ready_checks(timeout_seconds=30)

        assert count == 0

    def test_expire_stale_ready_checks_cancels_groups(self) -> None:
        mock_db = MagicMock()
        mock_db.query_all.return_value = [
            {"match_id": 42},
            {"match_id": 43},
        ]
        mock_db.execute = MagicMock()

        # Also stub the context manager for cancel_match_queue DB calls.
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_cursor.rowcount = 1
        mock_cursor.__enter__ = MagicMock(return_value=mock_cursor)
        mock_cursor.__exit__ = MagicMock(return_value=False)
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)
        mock_conn.cursor.return_value = mock_cursor
        mock_db.get_connection.return_value = mock_conn

        backend = MySQLQueueBackend(config=FakeConfig(), db=mock_db)
        count = backend.expire_stale_ready_checks(timeout_seconds=30)

        assert count == 2


# ---------------------------------------------------------------------------
# _row_to_entry helper
# ---------------------------------------------------------------------------

class TestRowToEntry:
    """Tests for the _row_to_entry conversion helper."""

    def test_basic_conversion(self) -> None:
        row = {
            "id": 7,
            "steam_id": "STEAM_0:1:99",
            "elo": 1200,
            "rank_tier": 9,
            "queued_at": datetime(2024, 1, 1, 12, 0, 0),
            "status": "waiting",
            "ready": False,
            "match_id": None,
            "map_preference": "de_dust2",
        }
        entry = _row_to_entry(row)
        assert entry.id == 7
        assert entry.steam_id == "STEAM_0:1:99"
        assert entry.elo == 1200
        assert entry.rank_tier == 9
        assert entry.status == "waiting"
        assert entry.ready is False
        assert entry.map_preference == "de_dust2"

    def test_status_defaults_to_waiting(self) -> None:
        row = {
            "id": 1,
            "steam_id": "STEAM_0:0:1",
            "elo": 1000,
            "rank_tier": 5,
            "queued_at": datetime.utcnow(),
        }
        entry = _row_to_entry(row)
        assert entry.status == "waiting"

    def test_ready_coerced_to_bool(self) -> None:
        row = {
            "id": 2,
            "steam_id": "STEAM_0:0:2",
            "elo": 1000,
            "rank_tier": 5,
            "queued_at": datetime.utcnow(),
            "ready": 1,  # MySQL returns int
        }
        entry = _row_to_entry(row)
        assert entry.ready is True
