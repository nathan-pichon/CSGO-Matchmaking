"""
Data models for the CS:GO matchmaking daemon.

All models use Python dataclasses for lightweight, typed data containers.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


@dataclass
class Player:
    """Represents a registered player in the matchmaking system.

    Attributes:
        steam_id: Legacy Steam ID string (e.g. STEAM_0:1:12345).
        steam_id64: 64-bit Steam ID integer used by the Steam API.
        name: Player display name.
        elo: Current ELO rating.
        rank_tier: Current rank tier index (0-17).
        matches_played: Total number of competitive matches played.
        matches_won: Total wins.
        matches_lost: Total losses.
        matches_tied: Total ties.
        is_banned: Whether the player is currently banned.
        ban_until: Datetime when the ban expires, or None if not banned.
    """

    steam_id: str
    steam_id64: int
    name: str
    elo: int
    rank_tier: int
    matches_played: int = 0
    matches_won: int = 0
    matches_lost: int = 0
    matches_tied: int = 0
    is_banned: bool = False
    ban_until: Optional[datetime] = None


@dataclass
class QueueEntry:
    """Represents a single player's entry in the matchmaking queue.

    Attributes:
        id: Database primary key for the queue row.
        steam_id: Legacy Steam ID string.
        elo: ELO at the time of queuing.
        rank_tier: Rank tier at the time of queuing.
        queued_at: Datetime when the player entered the queue.
        status: Current queue status ('waiting', 'ready_check', 'matched',
                'expired', 'cancelled').
        ready: Whether the player has confirmed the ready check.
        match_id: The match ID this entry is associated with, if any.
        map_preference: Optional preferred map name.
    """

    id: int
    steam_id: str
    elo: int
    rank_tier: int
    queued_at: datetime
    status: str = "waiting"
    ready: bool = False
    match_id: Optional[int] = None
    map_preference: Optional[str] = None


@dataclass
class MatchGroup:
    """Represents a balanced group of 10 players ready to form a match.

    Attributes:
        players: All 10 queue entries in this group.
        team1: The 5 players assigned to team 1.
        team2: The 5 players assigned to team 2.
        map_name: The map selected for this match.
    """

    players: list[QueueEntry] = field(default_factory=list)
    team1: list[QueueEntry] = field(default_factory=list)
    team2: list[QueueEntry] = field(default_factory=list)
    map_name: str = ""

    @property
    def team1_avg_elo(self) -> float:
        """Return the average ELO of team 1."""
        if not self.team1:
            return 0.0
        return sum(p.elo for p in self.team1) / len(self.team1)

    @property
    def team2_avg_elo(self) -> float:
        """Return the average ELO of team 2."""
        if not self.team2:
            return 0.0
        return sum(p.elo for p in self.team2) / len(self.team2)

    @property
    def elo_balance(self) -> float:
        """Return the absolute ELO difference between teams."""
        return abs(self.team1_avg_elo - self.team2_avg_elo)

    def all_steam_ids(self) -> list[str]:
        """Return all steam IDs in this group."""
        return [p.steam_id for p in self.players]

    def team1_steam_ids(self) -> list[str]:
        """Return team 1 steam IDs."""
        return [p.steam_id for p in self.team1]

    def team2_steam_ids(self) -> list[str]:
        """Return team 2 steam IDs."""
        return [p.steam_id for p in self.team2]


@dataclass
class MatchResult:
    """Represents the final result of a completed match.

    Attributes:
        match_id: Database ID of the match.
        winner: Which side won ('team1', 'team2', or 'tie').
        team1_score: Rounds won by team 1.
        team2_score: Rounds won by team 2.
        players: List of per-player stat dicts. Each dict contains keys:
                 steam_id, kills, deaths, assists, headshots, mvps, score,
                 damage, team, elo_before, elo_after, elo_change.
    """

    match_id: int
    winner: str
    team1_score: int
    team2_score: int
    players: list[dict] = field(default_factory=list)

    @property
    def is_tie(self) -> bool:
        """Return True if the match ended in a tie."""
        return self.winner == "tie"

    def get_top_fragger(self) -> Optional[dict]:
        """Return the player dict with the most kills, or None if no players."""
        if not self.players:
            return None
        return max(self.players, key=lambda p: p.get("kills", 0))

    def get_player_stats(self, steam_id: str) -> Optional[dict]:
        """Return the stats dict for a specific player, or None if not found."""
        for p in self.players:
            if p.get("steam_id") == steam_id:
                return p
        return None
