"""
Discord webhook notification backend for the CS:GO matchmaking daemon.

Implements :class:`~matchmaker.interfaces.notification.NotificationBackend`
by posting rich embeds to a Discord channel via an incoming webhook URL.

All public methods are no-ops when ``DISCORD_WEBHOOK_URL`` is not configured,
and they silently log a warning (never raise) when the HTTP request fails.
"""

from __future__ import annotations

import logging
from typing import Optional

import requests

from matchmaker.backends.elo_ranking import RANK_THRESHOLDS
from matchmaker.interfaces.notification import NotificationBackend

logger = logging.getLogger(__name__)

# Discord embed colour constants (decimal).
_COLOR_BLUE = 0x3498DB
_COLOR_GREEN = 0x2ECC71
_COLOR_GOLD = 0xF1C40F
_COLOR_RED = 0xE74C3C

# Request timeout in seconds.
_TIMEOUT = 5


def _tier_name(tier: int) -> str:
    """Return the display name for a rank tier index.

    Args:
        tier: Rank tier index (0-17).

    Returns:
        Display name string.
    """
    if 0 <= tier < len(RANK_THRESHOLDS):
        return RANK_THRESHOLDS[tier][1]
    return f"Tier {tier}"


class DiscordNotifier(NotificationBackend):
    """Posts matchmaking event notifications to a Discord channel.

    Args:
        config: Application :class:`~matchmaker.config.Config` instance.
            ``DISCORD_WEBHOOK_URL`` is read from this object.
    """

    def __init__(self, config: object) -> None:
        self._webhook_url: str = getattr(config, "DISCORD_WEBHOOK_URL", "")
        web_host = getattr(config, "WEB_HOST", "0.0.0.0")
        web_port = getattr(config, "WEB_PORT", 5000)
        # Build a base URL for player profiles; falls back to empty string.
        if web_host and web_host != "0.0.0.0":
            self._web_base: str = f"http://{web_host}:{web_port}"
        else:
            self._web_base = ""

    # ---------------------------------------------------------------------- #
    # Internal helpers
    # ---------------------------------------------------------------------- #

    def _post(self, payload: dict) -> None:
        """POST a JSON payload to the Discord webhook.

        Failures are logged as warnings and silently swallowed so they never
        crash the daemon.

        Args:
            payload: Discord message payload dict (``content`` / ``embeds``).
        """
        if not self._webhook_url:
            return
        try:
            resp = requests.post(
                self._webhook_url,
                json=payload,
                timeout=_TIMEOUT,
            )
            if resp.status_code not in (200, 204):
                logger.warning(
                    "Discord webhook returned HTTP %d: %s",
                    resp.status_code, resp.text[:200],
                )
        except requests.exceptions.RequestException as exc:
            logger.warning("Discord webhook request failed: %s", exc)

    @staticmethod
    def _avg_elo(players: list[dict]) -> float:
        """Return average ELO for a list of player dicts.

        Args:
            players: List of dicts each containing an ``elo`` key.

        Returns:
            Float average, or 0 if the list is empty.
        """
        if not players:
            return 0.0
        return sum(p.get("elo", 0) for p in players) / len(players)

    # ---------------------------------------------------------------------- #
    # NotificationBackend implementation
    # ---------------------------------------------------------------------- #

    def notify_match_found(
        self,
        match_id: int,
        map_name: str,
        team1: list[dict],
        team2: list[dict],
    ) -> None:
        """Post a match-found embed showing teams and average ELOs.

        Args:
            match_id: Database ID of the match.
            map_name: Map selected for this match.
            team1: List of player dicts (``steam_id``, ``elo``, ``rank_tier``).
            team2: Same for team 2.
        """
        if not self._webhook_url:
            return

        t1_avg = self._avg_elo(team1)
        t2_avg = self._avg_elo(team2)
        t1_tiers = ", ".join(_tier_name(p.get("rank_tier", 0)) for p in team1)
        t2_tiers = ", ".join(_tier_name(p.get("rank_tier", 0)) for p in team2)

        embed = {
            "title": f":crossed_swords:  Match #{match_id} Found",
            "color": _COLOR_BLUE,
            "fields": [
                {"name": "Map", "value": map_name, "inline": True},
                {"name": "\u200b", "value": "\u200b", "inline": True},
                {"name": "\u200b", "value": "\u200b", "inline": True},
                {
                    "name": f":blue_square: Team 1  (avg {t1_avg:.0f} ELO)",
                    "value": t1_tiers or "—",
                    "inline": True,
                },
                {
                    "name": f":orange_square: Team 2  (avg {t2_avg:.0f} ELO)",
                    "value": t2_tiers or "—",
                    "inline": True,
                },
            ],
            "footer": {"text": "CS:GO Matchmaking"},
        }
        self._post({"embeds": [embed]})

    @staticmethod
    def _build_scoreboard(players: list[dict], elo_changes: dict[str, int]) -> str:
        """Build a compact scoreboard string for a team embed field.

        Args:
            players: List of stat dicts (``name``, ``kills``, ``deaths``,
                ``assists``, ``steam_id``).
            elo_changes: Mapping of steam_id → ELO delta.

        Returns:
            Formatted string suitable for a Discord embed field value
            (max 1024 chars).
        """
        lines = ["```", "Name             K  D  A  ELO"]
        for p in players:
            name = (p.get("name") or p.get("steam_id", "?"))[:15].ljust(15)
            k = p.get("kills", 0)
            d = p.get("deaths", 0)
            a = p.get("assists", 0)
            delta = elo_changes.get(p.get("steam_id", ""), 0)
            sign = "+" if delta >= 0 else ""
            lines.append(f"{name} {k:>2} {d:>2} {a:>2}  {sign}{delta}")
        lines.append("```")
        result = "\n".join(lines)
        return result[:1024]

    def notify_match_result(
        self,
        match_id: int,
        winner: str,
        team1_score: int,
        team2_score: int,
        top_player: dict,
        player_stats: list[dict] | None = None,
        elo_changes: dict[str, int] | None = None,
    ) -> None:
        """Post a match-result embed with scores, ELO changes, and scoreboards.

        Args:
            match_id: Database ID of the match.
            winner: ``'team1'``, ``'team2'``, or ``'tie'``.
            team1_score: Rounds won by team 1.
            team2_score: Rounds won by team 2.
            top_player: Stat dict for the top fragger with keys
                ``steam_id``, ``kills``, ``deaths``, ``assists``,
                ``elo_change``.
            player_stats: Optional list of all player stat dicts (each with
                ``team`` key ``'team1'`` or ``'team2'``) for full scoreboards.
            elo_changes: Optional mapping of steam_id → ELO delta.
        """
        if not self._webhook_url:
            return

        if winner == "team1":
            winner_label = ":blue_square: Team 1"
            color = _COLOR_BLUE
        elif winner == "team2":
            winner_label = ":orange_square: Team 2"
            color = _COLOR_GOLD
        else:
            winner_label = ":handshake: Tie"
            color = _COLOR_GREEN

        top_sid = top_player.get("steam_id", "?")
        top_k = top_player.get("kills", 0)
        top_d = top_player.get("deaths", 0)
        top_a = top_player.get("assists", 0)
        top_elo = top_player.get("elo_change", 0)
        elo_sign = "+" if top_elo >= 0 else ""

        fields = [
            {"name": "Winner", "value": winner_label, "inline": True},
            {"name": "Score", "value": f"{team1_score} – {team2_score}", "inline": True},
            {
                "name": ":star: Top Fragger",
                "value": f"`{top_sid}`\n{top_k}/{top_d}/{top_a}  ELO {elo_sign}{top_elo}",
                "inline": False,
            },
        ]

        if player_stats:
            elo_map = elo_changes or {}
            t1 = [p for p in player_stats if p.get("team") == "team1"]
            t2 = [p for p in player_stats if p.get("team") == "team2"]
            fields.append({
                "name": ":blue_square: Team 1",
                "value": self._build_scoreboard(t1, elo_map) or "—",
                "inline": True,
            })
            fields.append({
                "name": ":orange_square: Team 2",
                "value": self._build_scoreboard(t2, elo_map) or "—",
                "inline": True,
            })

        embed = {
            "title": f":trophy:  Match #{match_id} Result",
            "color": color,
            "fields": fields,
            "footer": {"text": "CS:GO Matchmaking"},
        }
        self._post({"embeds": [embed]})

    def notify_rank_up(
        self,
        steam_id: str,
        name: str,
        old_tier: int,
        new_tier: int,
    ) -> None:
        """Post a rank-up notification embed.

        Args:
            steam_id: Player's legacy Steam ID.
            name: Player display name.
            old_tier: Previous rank tier index.
            new_tier: New (higher) rank tier index.
        """
        if not self._webhook_url:
            return

        # Rank tier emoji progression (Silver → Gold → MG → DMG → LE → LEM → Supreme → Global)
        _RANK_EMOJI = [
            "⬜", "⬜", "⬜", "⬜", "⬜",   # Silver I–V
            "🟡", "🟡", "🟡", "🟡", "🟡",  # Gold Nova I–Master
            "🔵", "🔵", "🔵",               # MG1, MG2, MGE
            "🔴",                            # DMG
            "🟣", "🟣",                     # LE, LEM
            "🔶",                            # Supreme
            "⭐",                            # Global Elite
        ]
        new_emoji = _RANK_EMOJI[new_tier] if new_tier < len(_RANK_EMOJI) else "🏆"

        profile_link = (
            f"\n[View Profile]({self._web_base}/player/{steam_id})"
            if self._web_base else ""
        )

        embed = {
            "title": f":arrow_up:  Rank Up!  {new_emoji}",
            "color": _COLOR_GOLD,
            "description": (
                f"**{name}** (`{steam_id}`) has ranked up!\n"
                f"{_tier_name(old_tier)}  →  **{_tier_name(new_tier)}**"
                f"{profile_link}"
            ),
            "footer": {"text": "CS:GO Matchmaking"},
        }
        self._post({"embeds": [embed]})

    def notify_system_error(self, error_msg: str) -> None:
        """Post a high-visibility system error notification with @here mention.

        Args:
            error_msg: Human-readable error description.
        """
        if not self._webhook_url:
            return

        embed = {
            "title": ":red_circle:  Matchmaker Error",
            "color": _COLOR_RED,
            "description": f"```\n{error_msg[:1900]}\n```",
            "footer": {"text": "CS:GO Matchmaking Daemon"},
        }
        self._post({"content": "@here", "embeds": [embed]})
