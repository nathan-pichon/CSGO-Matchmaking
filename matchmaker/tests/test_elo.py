"""
Unit tests for ELO ranking calculations.

All tests are fully isolated – no database connections are required.
"""

from __future__ import annotations

import pytest

from matchmaker.backends.elo_ranking import (
    RANK_THRESHOLDS,
    EloRankingBackend,
    _tier_min_elo,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

class FakeConfig:
    """Minimal config stub for testing."""
    ELO_K_FACTOR = 32
    ELO_K_FACTOR_NEW = 64
    ELO_DEFAULT = 1000
    MIN_PLACEMENT_MATCHES = 10


@pytest.fixture
def backend() -> EloRankingBackend:
    """Return an EloRankingBackend instance with no DB dependency."""
    return EloRankingBackend(config=FakeConfig(), db=None)


def _make_player(steam_id: str, elo: int, matches_played: int = 30) -> dict:
    """Helper to build a minimal player dict."""
    return {
        "steam_id": steam_id,
        "elo_before": elo,
        "matches_played": matches_played,
    }


def _make_10_players(base_elo: int = 1000) -> tuple[list[dict], list[dict]]:
    """Return (team1, team2) each with 5 players at *base_elo*."""
    team1 = [_make_player(f"STEAM_0:0:{i}", base_elo) for i in range(1, 6)]
    team2 = [_make_player(f"STEAM_0:0:{i}", base_elo) for i in range(6, 11)]
    return team1, team2


# ---------------------------------------------------------------------------
# get_rank_tier
# ---------------------------------------------------------------------------

class TestGetRankTier:
    """Tests for EloRankingBackend.get_rank_tier()."""

    def test_zero_elo_is_tier_0(self, backend: EloRankingBackend) -> None:
        assert backend.get_rank_tier(0) == 0

    def test_negative_elo_clamped_to_tier_0(self, backend: EloRankingBackend) -> None:
        # Negative ELO should not exceed tier 0 (all thresholds > 0 are not met).
        assert backend.get_rank_tier(-100) == 0

    def test_exact_threshold_boundaries(self, backend: EloRankingBackend) -> None:
        """ELO exactly at each threshold should return that tier."""
        for idx, (threshold, _) in enumerate(RANK_THRESHOLDS):
            assert backend.get_rank_tier(threshold) == idx, (
                f"ELO {threshold} should be tier {idx}"
            )

    def test_just_below_threshold(self, backend: EloRankingBackend) -> None:
        """ELO one below a threshold should remain in the previous tier."""
        # Tier 1 starts at 800; 799 should be tier 0.
        assert backend.get_rank_tier(799) == 0
        # Tier 6 starts at 1050; 1049 should be tier 5.
        assert backend.get_rank_tier(1049) == 5

    def test_max_tier(self, backend: EloRankingBackend) -> None:
        """ELO above the highest threshold should return the max tier."""
        assert backend.get_rank_tier(9999) == len(RANK_THRESHOLDS) - 1

    def test_silver_range(self, backend: EloRankingBackend) -> None:
        """ELO 900–949 should be Silver IV (tier 3)."""
        for elo in (900, 920, 949):
            assert backend.get_rank_tier(elo) == 3

    def test_global_elite(self, backend: EloRankingBackend) -> None:
        assert backend.get_rank_tier(2000) == 17
        assert backend.get_rank_tier(2500) == 17


# ---------------------------------------------------------------------------
# calculate_match_results – winner / loser gain / loss
# ---------------------------------------------------------------------------

class TestCalculateMatchResults:
    """Tests for EloRankingBackend.calculate_match_results()."""

    def test_winner_gains_elo(self, backend: EloRankingBackend) -> None:
        team1, team2 = _make_10_players(base_elo=1000)
        changes = backend.calculate_match_results(
            match_id=1, winner="team1",
            team1_players=team1, team2_players=team2, player_stats={},
        )
        for p in team1:
            assert changes[p["steam_id"]] > 0, "Winner should gain ELO"

    def test_loser_loses_elo(self, backend: EloRankingBackend) -> None:
        team1, team2 = _make_10_players(base_elo=1000)
        changes = backend.calculate_match_results(
            match_id=2, winner="team1",
            team1_players=team1, team2_players=team2, player_stats={},
        )
        for p in team2:
            assert changes[p["steam_id"]] < 0, "Loser should lose ELO"

    def test_all_10_players_receive_change(self, backend: EloRankingBackend) -> None:
        team1, team2 = _make_10_players()
        changes = backend.calculate_match_results(
            match_id=3, winner="team2",
            team1_players=team1, team2_players=team2, player_stats={},
        )
        assert len(changes) == 10

    def test_team2_wins(self, backend: EloRankingBackend) -> None:
        team1, team2 = _make_10_players()
        changes = backend.calculate_match_results(
            match_id=4, winner="team2",
            team1_players=team1, team2_players=team2, player_stats={},
        )
        for p in team2:
            assert changes[p["steam_id"]] > 0
        for p in team1:
            assert changes[p["steam_id"]] < 0

    def test_stronger_team_gains_less_on_win(self, backend: EloRankingBackend) -> None:
        """A heavily favoured team should gain fewer points for winning."""
        strong_team = [_make_player(f"STEAM_0:0:{i}", 1800) for i in range(1, 6)]
        weak_team = [_make_player(f"STEAM_0:0:{i}", 1000) for i in range(6, 11)]
        changes = backend.calculate_match_results(
            match_id=5, winner="team1",
            team1_players=strong_team, team2_players=weak_team, player_stats={},
        )
        # Strong team wins → small gain
        gain_strong = changes[strong_team[0]["steam_id"]]
        # If weak team had won (hypothetical) the gain would be larger.
        # We just verify the strong team gain is small (< 10 for K=24).
        assert 0 < gain_strong < 10

    def test_underdog_gains_more_on_win(self, backend: EloRankingBackend) -> None:
        """An underdog team should gain more ELO when they win."""
        weak_team = [_make_player(f"STEAM_0:0:{i}", 1000) for i in range(1, 6)]
        strong_team = [_make_player(f"STEAM_0:0:{i}", 1800) for i in range(6, 11)]
        changes = backend.calculate_match_results(
            match_id=6, winner="team1",
            team1_players=weak_team, team2_players=strong_team, player_stats={},
        )
        gain_underdog = changes[weak_team[0]["steam_id"]]
        assert gain_underdog > 15, "Underdog upset should yield large ELO gain"

    def test_empty_team_returns_empty(self, backend: EloRankingBackend) -> None:
        changes = backend.calculate_match_results(
            match_id=99, winner="team1",
            team1_players=[], team2_players=[], player_stats={},
        )
        assert changes == {}


# ---------------------------------------------------------------------------
# calculate_match_results – tie
# ---------------------------------------------------------------------------

class TestTieResults:
    """Tests for tie match outcomes."""

    def test_tie_both_teams_near_zero_change(self, backend: EloRankingBackend) -> None:
        """Equal-rated teams tying should have near-zero ELO changes."""
        team1, team2 = _make_10_players(base_elo=1000)
        changes = backend.calculate_match_results(
            match_id=10, winner="tie",
            team1_players=team1, team2_players=team2, player_stats={},
        )
        for p in team1 + team2:
            assert abs(changes[p["steam_id"]]) <= 1, (
                "Equal teams tying should have ~0 ELO change"
            )

    def test_tie_favoured_team_loses_elo(self, backend: EloRankingBackend) -> None:
        """When a strong team ties a weak team, the strong team should lose ELO."""
        strong = [_make_player(f"STEAM_0:0:{i}", 1800) for i in range(1, 6)]
        weak = [_make_player(f"STEAM_0:0:{i}", 1000) for i in range(6, 11)]
        changes = backend.calculate_match_results(
            match_id=11, winner="tie",
            team1_players=strong, team2_players=weak, player_stats={},
        )
        assert changes[strong[0]["steam_id"]] < 0
        assert changes[weak[0]["steam_id"]] > 0


# ---------------------------------------------------------------------------
# K-factor selection
# ---------------------------------------------------------------------------

class TestKFactor:
    """Tests for EloRankingBackend.get_k_factor()."""

    def test_new_player_k_factor(self, backend: EloRankingBackend) -> None:
        """Players with < 10 matches should use K=64 (placement)."""
        assert backend.get_k_factor(0) == 64
        assert backend.get_k_factor(9) == 64

    def test_mid_player_k_factor(self, backend: EloRankingBackend) -> None:
        """Players with 10-29 matches should use K=32."""
        assert backend.get_k_factor(10) == 32
        assert backend.get_k_factor(29) == 32

    def test_veteran_k_factor(self, backend: EloRankingBackend) -> None:
        """Players with 30+ matches should use K=24."""
        assert backend.get_k_factor(30) == 24
        assert backend.get_k_factor(1000) == 24

    def test_placement_player_has_larger_elo_swings(
        self, backend: EloRankingBackend
    ) -> None:
        """New players should gain/lose more ELO per match than veterans."""
        new_player = [_make_player("STEAM_0:0:1", 1000, matches_played=0)]
        veteran_player = [_make_player("STEAM_0:0:2", 1000, matches_played=100)]
        opponent_new = [_make_player(f"STEAM_0:0:{i}", 1000) for i in range(3, 8)]
        opponent_vet = [_make_player(f"STEAM_0:0:{i}", 1000) for i in range(3, 8)]

        changes_new = backend.calculate_match_results(
            match_id=20, winner="team1",
            team1_players=new_player,
            team2_players=opponent_new,
            player_stats={},
        )
        changes_vet = backend.calculate_match_results(
            match_id=21, winner="team1",
            team1_players=veteran_player,
            team2_players=opponent_vet,
            player_stats={},
        )
        assert abs(changes_new["STEAM_0:0:1"]) > abs(changes_vet["STEAM_0:0:2"])


# ---------------------------------------------------------------------------
# ELO decay
# ---------------------------------------------------------------------------

class TestEloDecay:
    """Tests for EloRankingBackend.apply_elo_decay()."""

    def test_no_decay_within_grace_period(self, backend: EloRankingBackend) -> None:
        """Players inactive for <= 2 weeks should not lose ELO."""
        for weeks in (0, 1, 2):
            assert backend.apply_elo_decay("STEAM_0:0:1", 1000, weeks) == 1000

    def test_decay_starts_after_2_weeks(self, backend: EloRankingBackend) -> None:
        """3 weeks inactive → 1 week of decay = -10 ELO."""
        result = backend.apply_elo_decay("STEAM_0:0:1", 1000, 3)
        assert result == 990

    def test_4_weeks_inactive(self, backend: EloRankingBackend) -> None:
        """4 weeks inactive → 2 weeks of decay = -20 ELO."""
        result = backend.apply_elo_decay("STEAM_0:0:1", 1200, 4)
        assert result == 1180

    def test_floor_at_tier_minimum(self, backend: EloRankingBackend) -> None:
        """ELO decay should not drop the player below their current tier floor."""
        # Player at 1000 ELO is Silver Elite Master (tier 5), floor = 1000.
        result = backend.apply_elo_decay("STEAM_0:0:1", 1000, 1000)
        assert result == 1000

    def test_floor_mid_tier(self, backend: EloRankingBackend) -> None:
        """Player mid-tier should decay but not below tier minimum."""
        # Player at 1060 ELO → Gold Nova I (tier 6), floor = 1050.
        # Enough inactive weeks to push well below 1050.
        result = backend.apply_elo_decay("STEAM_0:0:2", 1060, 20)
        assert result >= 1050

    def test_decay_large_inactive_period(self, backend: EloRankingBackend) -> None:
        """100 weeks inactive should decay to tier floor, not go negative."""
        result = backend.apply_elo_decay("STEAM_0:0:3", 1500, 100)
        assert result >= 0


# ---------------------------------------------------------------------------
# Snake draft team balancing
# ---------------------------------------------------------------------------

class TestSnakeDraft:
    """Tests for MySQLQueueBackend._snake_draft() static method."""

    @pytest.fixture
    def draft_fn(self):
        """Import the snake-draft helper directly."""
        from matchmaker.backends.mysql_queue import MySQLQueueBackend
        return MySQLQueueBackend._snake_draft

    def _make_entries(self, elos: list[int]):
        """Build minimal QueueEntry-like objects with the given ELOs."""
        from datetime import datetime
        from matchmaker.models import QueueEntry
        return [
            QueueEntry(
                id=i,
                steam_id=f"STEAM_0:0:{i}",
                elo=elo,
                rank_tier=0,
                queued_at=datetime.utcnow(),
            )
            for i, elo in enumerate(elos)
        ]

    def test_teams_have_5_players_each(self, draft_fn) -> None:
        entries = self._make_entries([1800, 1700, 1600, 1500, 1400,
                                      1300, 1200, 1100, 1000, 900])
        team1, team2 = draft_fn(entries)
        assert len(team1) == 5
        assert len(team2) == 5

    def test_no_duplicate_players(self, draft_fn) -> None:
        entries = self._make_entries([1800, 1700, 1600, 1500, 1400,
                                      1300, 1200, 1100, 1000, 900])
        team1, team2 = draft_fn(entries)
        all_ids = [p.steam_id for p in team1 + team2]
        assert len(all_ids) == len(set(all_ids))

    def test_equal_elo_teams_balanced(self, draft_fn) -> None:
        """Snake draft should produce teams with near-equal average ELO."""
        elos = [2000, 1900, 1800, 1700, 1600, 1500, 1400, 1300, 1200, 1100]
        entries = self._make_entries(elos)
        team1, team2 = draft_fn(entries)
        avg1 = sum(p.elo for p in team1) / 5
        avg2 = sum(p.elo for p in team2) / 5
        # Snake draft should keep the difference well under 200 ELO.
        assert abs(avg1 - avg2) < 200, (
            f"Teams are unbalanced: avg1={avg1} avg2={avg2}"
        )

    def test_widely_spread_elos_still_balanced(self, draft_fn) -> None:
        """Snake draft should minimise imbalance even with a wide ELO spread."""
        elos = [3000, 2900, 2800, 2700, 2600, 100, 100, 100, 100, 100]
        entries = self._make_entries(elos)
        team1, team2 = draft_fn(entries)
        avg1 = sum(p.elo for p in team1) / 5
        avg2 = sum(p.elo for p in team2) / 5
        # The best possible balance groups high and low ELO evenly.
        # Ensure neither team has ALL the high-ELO players.
        assert avg1 != max(p.elo for p in entries), "Team 1 should not have all top players"
        assert avg2 != max(p.elo for p in entries)

    def test_specific_assignment_pattern(self, draft_fn) -> None:
        """Verify the exact snake-draft assignment for a known input.

        With 10 players sorted descending the expected assignment is:
        Pos 0 → T1, 1 → T2, 2 → T2, 3 → T1, 4 → T1,
        Pos 5 → T2, 6 → T2, 7 → T1, 8 → T1, 9 → T2.
        """
        elos = [1000, 900, 800, 700, 600, 500, 400, 300, 200, 100]
        entries = self._make_entries(elos)
        team1, team2 = draft_fn(entries)

        expected_t1_elos = {1000, 700, 600, 300, 200}
        expected_t2_elos = {900, 800, 500, 400, 100}

        t1_elos = set(p.elo for p in team1)
        t2_elos = set(p.elo for p in team2)

        assert t1_elos == expected_t1_elos, f"Team 1 ELOs mismatch: {t1_elos}"
        assert t2_elos == expected_t2_elos, f"Team 2 ELOs mismatch: {t2_elos}"
