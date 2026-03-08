"""
Main matchmaking daemon entry point.

The :class:`MatchmakingDaemon` class orchestrates the entire matchmaking
pipeline:

1. **Match formation** – polls the queue for balanced 10-player groups.
2. **Ready checks** – prompts players to confirm and times out no-shows.
3. **Server creation** – spins up Docker containers for confirmed matches.
4. **Result processing** – applies ELO changes after matches finish.
5. **Cleanup** – destroys containers and releases ports/GSLTs.
6. **Stale entry expiry** – removes players who waited too long.

The daemon runs until it receives ``SIGINT`` or ``SIGTERM``, at which point
it completes the current tick and exits cleanly.

Usage::

    python -m matchmaker.matchmaker
"""

from __future__ import annotations

import logging
import signal
import time
import traceback
from datetime import datetime, timedelta
from typing import Optional

from matchmaker.config import Config, get_config
from matchmaker.db import Database, get_db
from matchmaker.factory import (
    create_notification_backend,
    create_queue_backend,
    create_ranking_backend,
    create_server_backend,
)
from matchmaker.interfaces.notification import NotificationBackend
from matchmaker.interfaces.queue_backend import QueueBackend
from matchmaker.interfaces.ranking import RankingBackend
from matchmaker.interfaces.server_backend import ServerBackend
from matchmaker.utils import generate_password, setup_logging

logger = logging.getLogger(__name__)

# Maximum consecutive errors before the daemon sleeps with exponential backoff.
_MAX_CONSECUTIVE_ERRORS = 5
_BACKOFF_BASE_SECONDS = 5
_BACKOFF_MAX_SECONDS = 120

# ---------------------------------------------------------------------------
# Abandon-ban escalation table
# Offense level → ban duration in minutes.
# After ABANDON_DECAY_DAYS days without another abandon, the effective offense
# level drops by 1 (floor 0), so the next ban is one step lighter.
# ---------------------------------------------------------------------------
_ABANDON_BAN_MINUTES: dict[int, int] = {
    1: 30,      # first offense  → 30 minutes
    2: 120,     # second offense → 2 hours
    3: 1440,    # third offense  → 24 hours
    4: 10080,   # fourth offense → 7 days
}
_ABANDON_BAN_MAX_MINUTES: int = 43200   # fifth+ offense → 30 days
_ABANDON_DECAY_DAYS:      int = 14      # days of good behaviour to drop one level


class MatchmakingDaemon:
    """CS:GO matchmaking orchestration daemon.

    Wires together all configured backends and drives the main poll loop.

    Args:
        config: Optional pre-loaded :class:`~matchmaker.config.Config`.
            If *None*, the module-level singleton is used.
        db: Optional pre-connected :class:`~matchmaker.db.Database`.
            If *None*, a new instance is created from *config*.
    """

    def __init__(
        self,
        config: Optional[Config] = None,
        db: Optional[Database] = None,
    ) -> None:
        self._config: Config = config or get_config()
        self._db: Database = db or get_db(
            host=self._config.DB_HOST,
            port=self._config.DB_PORT,
            user=self._config.DB_USER,
            password=self._config.DB_PASS,
            database=self._config.DB_NAME,
        )

        # Initialise backends via factory.
        self._queue: QueueBackend = create_queue_backend(self._config, self._db)
        self._server: ServerBackend = create_server_backend(self._config)
        self._ranking: RankingBackend = create_ranking_backend(self._config, self._db)
        self._notify: NotificationBackend = create_notification_backend(self._config)

        self._running: bool = False
        self._consecutive_errors: int = 0

        logger.info(
            "MatchmakingDaemon initialised: queue=%s server=%s ranking=%s notify=%s",
            type(self._queue).__name__,
            type(self._server).__name__,
            type(self._ranking).__name__,
            type(self._notify).__name__,
        )

    # ---------------------------------------------------------------------- #
    # Signal handling
    # ---------------------------------------------------------------------- #

    def _shutdown(self, signum: int, frame: object) -> None:  # noqa: ARG002
        """Handle SIGINT / SIGTERM for graceful shutdown.

        Sets the :attr:`_running` flag to False so the main loop exits after
        completing the current tick.

        Args:
            signum: Signal number received.
            frame: Current stack frame (unused).
        """
        sig_name = signal.Signals(signum).name
        logger.info("Received %s – shutting down after current tick…", sig_name)
        self._running = False

    # ---------------------------------------------------------------------- #
    # Public entry point
    # ---------------------------------------------------------------------- #

    def run(self) -> None:
        """Start the daemon's main poll loop.

        Registers SIGINT/SIGTERM handlers and calls :meth:`_loop_tick` every
        :attr:`~matchmaker.config.Config.POLL_INTERVAL` seconds.  Uses
        exponential backoff when database errors occur consecutively.
        """
        signal.signal(signal.SIGINT, self._shutdown)
        signal.signal(signal.SIGTERM, self._shutdown)

        self._running = True
        logger.info(
            "MatchmakingDaemon running (poll_interval=%.1fs)",
            self._config.POLL_INTERVAL,
        )

        while self._running:
            start = time.monotonic()
            try:
                self._loop_tick()
                self._consecutive_errors = 0
            except Exception as exc:  # noqa: BLE001
                self._consecutive_errors += 1
                logger.error(
                    "Unhandled exception in _loop_tick (consecutive=%d): %s\n%s",
                    self._consecutive_errors,
                    exc,
                    traceback.format_exc(),
                )
                try:
                    self._notify.notify_system_error(
                        f"Daemon loop error #{self._consecutive_errors}: {exc}"
                    )
                except Exception:  # noqa: BLE001
                    pass

                if self._consecutive_errors >= _MAX_CONSECUTIVE_ERRORS:
                    backoff = min(
                        _BACKOFF_BASE_SECONDS * (2 ** (self._consecutive_errors - _MAX_CONSECUTIVE_ERRORS)),
                        _BACKOFF_MAX_SECONDS,
                    )
                    logger.warning(
                        "Too many consecutive errors; backing off for %.0fs", backoff
                    )
                    time.sleep(backoff)
                    continue

            elapsed = time.monotonic() - start
            sleep_time = max(0.0, self._config.POLL_INTERVAL - elapsed)
            if self._running:
                time.sleep(sleep_time)

        logger.info("MatchmakingDaemon stopped.")

    # ---------------------------------------------------------------------- #
    # Main loop body
    # ---------------------------------------------------------------------- #

    def _loop_tick(self) -> None:
        """Execute one complete poll-loop iteration.

        Steps (in order):

        1. Attempt to form a balanced match group and start a ready check.
        2. Expire stale ready checks (time out no-shows).
        3. For each fully-ready group, create a game server.
        4. Process finished matches – apply ELO, notify results.
        5. Bulk-clean containers for finished / cancelled matches.
        6. Expire stale queue entries.
        7. Cancel warmup matches that have timed out.
        """
        self._step_find_and_ready_check()
        self._step_expire_stale_ready_checks()
        self._step_create_servers()
        self._step_process_finished_matches()
        self._step_cleanup_servers()
        self._step_expire_stale_queue_entries()
        self._step_cancel_timed_out_warmups()

    # ---------------------------------------------------------------------- #
    # Individual pipeline steps
    # ---------------------------------------------------------------------- #

    # ---------------------------------------------------------------------- #
    # Abandon-ban helpers
    # ---------------------------------------------------------------------- #

    @staticmethod
    def _get_abandon_ban_minutes(offense_level: int) -> int:
        """Return the ban duration in minutes for the given offense level.

        Args:
            offense_level: 1-based offense count after decay has been applied.

        Returns:
            Integer minutes to ban.
        """
        return _ABANDON_BAN_MINUTES.get(offense_level, _ABANDON_BAN_MAX_MINUTES)

    def _apply_abandon_penalty(
        self,
        steam_id: str,
        abandon_count: int,
        last_abandon_at: Optional[datetime],
    ) -> None:
        """Insert a matchmaking ban for a player who abandoned a live match.

        Implements progressive escalation with a 14-day decay window:
        if the player's last abandon was more than ``_ABANDON_DECAY_DAYS``
        days ago, their effective offense level drops by one before the new
        ban is calculated.

        Args:
            steam_id:        Player's legacy Steam ID.
            abandon_count:   Current ``mm_players.abandon_count`` value.
            last_abandon_at: Timestamp of previous abandon, or ``None``.
        """
        # Decay: one level of forgiveness after 14 clean days.
        effective_count = abandon_count
        if abandon_count > 0 and last_abandon_at is not None:
            days_since = (datetime.utcnow() - last_abandon_at).days
            if days_since > _ABANDON_DECAY_DAYS:
                effective_count = max(0, abandon_count - 1)
                logger.info(
                    "_apply_abandon_penalty: decay applied steam_id=%s "
                    "abandon_count=%d → effective=%d (last=%s)",
                    steam_id, abandon_count, effective_count, last_abandon_at,
                )

        new_count  = effective_count + 1
        ban_min    = self._get_abandon_ban_minutes(new_count)
        reason     = f"Match abandon (offense #{new_count})"

        try:
            self._db.execute(
                """
                INSERT INTO mm_bans
                  (steam_id, reason, expires_at, banned_by, is_active)
                VALUES
                  (%s, %s, DATE_ADD(NOW(), INTERVAL %s MINUTE), 'system', 1)
                """,
                (steam_id, reason, ban_min),
            )
            self._db.execute(
                """
                UPDATE mm_players
                SET is_banned       = 1,
                    ban_until       = DATE_ADD(NOW(), INTERVAL %s MINUTE),
                    abandon_count   = %s,
                    last_abandon_at = NOW()
                WHERE steam_id = %s
                """,
                (ban_min, new_count, steam_id),
            )
            logger.info(
                "_apply_abandon_penalty: steam_id=%s offense=#%d ban=%dmin",
                steam_id, new_count, ban_min,
            )
        except Exception as exc:
            logger.error(
                "_apply_abandon_penalty: DB error for %s: %s", steam_id, exc
            )

    def _step_find_and_ready_check(self) -> None:
        """Find a balanced 10-player group and start a ready check.

        Creates a provisional match row in the database and transitions all
        10 players into the ``ready_check`` queue status.
        """
        try:
            group = self._queue.find_balanced_match()
            if group is None:
                return

            # Allocate a server port and GSLT token before creating the match.
            port_row = self._db.claim_free_port()
            if not port_row:
                logger.warning(
                    "_step_find_and_ready_check: no free server ports available"
                )
                return

            gslt_row = self._db.claim_free_gslt()
            if not gslt_row:
                logger.warning(
                    "_step_find_and_ready_check: no free GSLT tokens available"
                )
                self._db.release_port(port_row["port"])
                return

            password = generate_password(16)
            match_token = generate_password(24)

            match_id = self._db.create_match(
                match_token=match_token,
                map_name=group.map_name,
                port=port_row["port"],
                ip=self._config.SERVER_IP,
                password=password,
                gslt=gslt_row["token"],
                team1_ids=group.team1_steam_ids(),
                team2_ids=group.team2_steam_ids(),
            )

            steam_ids = group.all_steam_ids()
            self._queue.set_ready_check(steam_ids, match_id)

            # Notify Discord that a match has been found.
            team1_dicts = [
                {"steam_id": p.steam_id, "elo": p.elo, "rank_tier": p.rank_tier}
                for p in group.team1
            ]
            team2_dicts = [
                {"steam_id": p.steam_id, "elo": p.elo, "rank_tier": p.rank_tier}
                for p in group.team2
            ]
            try:
                self._notify.notify_match_found(
                    match_id, group.map_name, team1_dicts, team2_dicts
                )
            except Exception as exc:
                logger.warning("notify_match_found failed: %s", exc)

            logger.info(
                "_step_find_and_ready_check: match_id=%d map=%s "
                "team1_avg=%.0f team2_avg=%.0f",
                match_id, group.map_name,
                group.team1_avg_elo, group.team2_avg_elo,
            )

        except Exception as exc:
            logger.error("_step_find_and_ready_check error: %s", exc, exc_info=True)

    def _step_expire_stale_ready_checks(self) -> None:
        """Time out ready checks where not all players confirmed.

        Players who were ready are re-queued; players who failed to ready
        receive a ``'cancelled'`` status (optionally with a cooldown).
        """
        try:
            expired = self._queue.expire_stale_ready_checks(
                timeout_seconds=self._config.READY_CHECK_TIMEOUT
            )
            if expired:
                logger.info(
                    "_step_expire_stale_ready_checks: expired %d groups", expired
                )
        except Exception as exc:
            logger.error("_step_expire_stale_ready_checks error: %s", exc, exc_info=True)

    def _step_create_servers(self) -> None:
        """Spin up Docker containers for fully-confirmed match groups."""
        try:
            ready_groups = self._db.get_fully_ready_match_groups()
            for group_row in ready_groups:
                match_id = group_row["match_id"]
                self._create_server_for_match(match_id)
        except Exception as exc:
            logger.error("_step_create_servers error: %s", exc, exc_info=True)

    def _create_server_for_match(self, match_id: int) -> None:
        """Start a Docker container for a single confirmed match.

        Fetches the match row, transitions queue entries to ``'matched'``,
        and calls :meth:`~matchmaker.interfaces.server_backend.ServerBackend.create_server`.

        Args:
            match_id: Database ID of the match to create a server for.
        """
        match = self._db.query_one(
            "SELECT * FROM mm_matches WHERE id = %s", (match_id,)
        )
        if not match:
            logger.warning("_create_server_for_match: match_id=%d not found", match_id)
            return

        if match.get("status") != "creating":
            # Already being processed (another daemon instance or re-entry).
            return

        # Fetch player rows to build team lists.
        player_rows = self._db.query_all(
            "SELECT steam_id, team FROM mm_match_players WHERE match_id = %s",
            (match_id,),
        )
        team1_ids = [r["steam_id"] for r in player_rows if r["team"] == "team1"]
        team2_ids = [r["steam_id"] for r in player_rows if r["team"] == "team2"]

        try:
            container_id = self._server.create_server(
                match_id=match_id,
                match_token=match["match_token"],
                server_port=match["server_port"],
                tv_port=match["server_port"] + 1,   # TV port = game port + 1
                gslt_token=match["gslt_token"],
                map_name=match["map_name"],
                team1_steam_ids=team1_ids,
                team2_steam_ids=team2_ids,
                db_config=self._config.db_config,
            )
        except Exception as exc:
            logger.error(
                "_create_server_for_match: failed to create container for "
                "match_id=%d: %s",
                match_id, exc, exc_info=True,
            )
            # Mark the match as error and release resources.
            self._db.execute(
                "UPDATE mm_matches SET status = 'error' WHERE id = %s",
                (match_id,),
            )
            self._db.release_port(match["server_port"])
            self._db.release_gslt(match["gslt_token"])
            self._queue.cancel_match_queue(match_id, requeue=True)
            return

        self._db.update_match_container(match_id, container_id)
        self._queue.set_matched(match_id)

        logger.info(
            "_create_server_for_match: match_id=%d container=%s port=%d",
            match_id, container_id, match["server_port"],
        )

    def _step_process_finished_matches(self) -> None:
        """Detect finished matches, apply ELO, and send result notifications."""
        try:
            finished = self._db.query_all(
                """
                SELECT * FROM mm_matches
                WHERE status = 'finished'
                  AND winner IS NOT NULL
                  AND cleaned_up = 0
                """
            )
            for match in finished:
                self._process_match_result(match)
        except Exception as exc:
            logger.error("_step_process_finished_matches error: %s", exc, exc_info=True)

    def _process_match_result(self, match: dict) -> None:
        """Apply ELO changes for a finished match and notify.

        Args:
            match: Row dict from ``mm_matches`` for the finished match.
        """
        match_id: int = match["id"]
        winner: str = match.get("winner", "tie")

        # Check if we've already processed ELO for this match (elo_change != 0
        # for at least one player indicates processing happened).
        already_processed = self._db.query_one(
            """
            SELECT id FROM mm_match_players
            WHERE match_id = %s AND elo_change != 0
            LIMIT 1
            """,
            (match_id,),
        )
        if already_processed:
            logger.debug(
                "_process_match_result: match_id=%d already processed, skipping",
                match_id,
            )
            return

        player_rows = self._db.query_all(
            """
            SELECT mp.*, p.matches_played, p.abandon_count, p.last_abandon_at
            FROM mm_match_players mp
            JOIN mm_players p ON p.steam_id = mp.steam_id
            WHERE mp.match_id = %s
            """,
            (match_id,),
        )

        team1_players = [
            {
                "steam_id": r["steam_id"],
                "elo_before": r["elo_before"],
                "matches_played": r.get("matches_played", 0),
            }
            for r in player_rows
            if r["team"] == "team1"
        ]
        team2_players = [
            {
                "steam_id": r["steam_id"],
                "elo_before": r["elo_before"],
                "matches_played": r.get("matches_played", 0),
            }
            for r in player_rows
            if r["team"] == "team2"
        ]

        # Build a stat dict from the match_players rows.
        player_stats = {
            r["steam_id"]: {
                "kills": r.get("kills", 0),
                "deaths": r.get("deaths", 0),
                "assists": r.get("assists", 0),
                "headshots": r.get("headshots", 0),
                "mvps": r.get("mvps", 0),
                "score": r.get("score", 0),
                "damage": r.get("damage", 0),
                "team": r["team"],
            }
            for r in player_rows
        }

        try:
            elo_changes = self._ranking.calculate_match_results(
                match_id=match_id,
                winner=winner,
                team1_players=team1_players,
                team2_players=team2_players,
                player_stats=player_stats,
            )
        except Exception as exc:
            logger.error(
                "_process_match_result: ELO calculation failed match_id=%d: %s",
                match_id, exc, exc_info=True,
            )
            return

        # ── Abandon ELO override ─────────────────────────────────────────────
        # Any player who abandoned while their team was winning (or tied)
        # receives the loss delta instead of their normal result.
        # This is computed *after* the base calculation so we can reuse the
        # K-factor and expected-score helpers from the ranking backend.
        abandoned_rows = [r for r in player_rows if r.get("abandoned")]
        if abandoned_rows:
            team1_avg = (
                sum(p["elo_before"] for p in team1_players) / len(team1_players)
                if team1_players else 0.0
            )
            team2_avg = (
                sum(p["elo_before"] for p in team2_players) / len(team2_players)
                if team2_players else 0.0
            )
            for r in abandoned_rows:
                sid  = r["steam_id"]
                team = r["team"]
                on_winning_team = (
                    (team == "team1" and winner == "team1")
                    or (team == "team2" and winner == "team2")
                )
                # Override only if the player would have gained ELO (won/tied).
                if on_winning_team or winner == "tie":
                    k = self._ranking.get_k_factor(r.get("matches_played", 0))
                    expected = self._ranking.expected_score(
                        team1_avg if team == "team1" else team2_avg,
                        team2_avg if team == "team1" else team1_avg,
                    )
                    original = elo_changes.get(sid, 0)
                    elo_changes[sid] = round(k * (0.0 - expected))
                    logger.info(
                        "_process_match_result: abandon ELO override "
                        "steam_id=%s original=%+d → overridden=%+d",
                        sid, original, elo_changes[sid],
                    )

        # Apply ELO updates and track rank-ups.
        for r in player_rows:
            sid = r["steam_id"]
            delta = elo_changes.get(sid, 0)
            team = r["team"]

            won = (team == "team1" and winner == "team1") or (
                team == "team2" and winner == "team2"
            )
            lost = (team == "team1" and winner == "team2") or (
                team == "team2" and winner == "team1"
            )
            tied = winner == "tie"

            old_tier = r.get("rank_tier") or self._ranking.get_rank_tier(r["elo_before"])
            new_elo = max(0, r["elo_before"] + delta)
            new_tier = self._ranking.get_rank_tier(new_elo)

            try:
                self._db.update_player_after_match(
                    steam_id=sid,
                    match_id=match_id,
                    elo_change=delta,
                    won=won,
                    lost=lost,
                    tied=tied,
                    kills=r.get("kills", 0),
                    deaths=r.get("deaths", 0),
                    assists=r.get("assists", 0),
                    headshots=r.get("headshots", 0),
                    mvps=r.get("mvps", 0),
                )
            except Exception as exc:
                logger.error(
                    "_process_match_result: update failed for %s: %s", sid, exc
                )
                continue

            # Notify rank-ups.
            if new_tier > old_tier:
                player_info = self._db.get_player(sid)
                player_name = player_info.get("name", sid) if player_info else sid
                try:
                    self._notify.notify_rank_up(sid, player_name, old_tier, new_tier)
                except Exception as exc:
                    logger.warning("notify_rank_up failed for %s: %s", sid, exc)

        # ── Abandon penalties ────────────────────────────────────────────────
        # Applied after stats are saved so the ban does not interfere with
        # the update_player_after_match write.
        for r in abandoned_rows:
            self._apply_abandon_penalty(
                steam_id=r["steam_id"],
                abandon_count=r.get("abandon_count", 0),
                last_abandon_at=r.get("last_abandon_at"),
            )

        # Send result notification.
        top_fragger: dict = {}
        if player_stats:
            top_sid = max(player_stats, key=lambda s: player_stats[s].get("kills", 0))
            top_fragger = {
                "steam_id": top_sid,
                **player_stats[top_sid],
                "elo_change": elo_changes.get(top_sid, 0),
            }

        # Build enriched per-team stat list for Discord scoreboard.
        stats_list = [
            {"steam_id": sid, "team": data.get("team"), **data,
             "elo_change": elo_changes.get(sid, 0)}
            for sid, data in player_stats.items()
        ] if player_stats else None

        try:
            self._notify.notify_match_result(
                match_id=match_id,
                winner=winner,
                team1_score=match.get("team1_score", 0),
                team2_score=match.get("team2_score", 0),
                top_player=top_fragger,
                player_stats=stats_list,
                elo_changes=elo_changes,
            )
        except Exception as exc:
            logger.warning("notify_match_result failed: %s", exc)

        logger.info(
            "_process_match_result: match_id=%d winner=%s elo_changes=%s",
            match_id, winner,
            {k: v for k, v in elo_changes.items()},
        )

    # Maximum cleanup attempts before the daemon force-marks a match cleaned.
    _CLEANUP_MAX_ATTEMPTS = 5

    def _step_cleanup_servers(self) -> None:
        """Destroy containers and release ports/GSLTs for finished matches.

        Each match tracks the number of failed cleanup attempts in
        ``cleanup_attempts``. After :attr:`_CLEANUP_MAX_ATTEMPTS` failures
        the match is force-marked as cleaned (``cleaned_up=1``) so it no
        longer blocks resources forever, and an ERROR is logged for manual
        investigation of the orphaned container.
        """
        try:
            matches = self._db.get_matches_needing_cleanup()
            if not matches:
                return

            cleaned_ids = self._server.cleanup_finished_servers(matches)
            cleaned_set = set(cleaned_ids)

            for match in matches:
                match_id = match["id"]
                container_id = match.get("docker_container_id")
                cleanup_attempts = int(match.get("cleanup_attempts", 0))

                if container_id and container_id not in cleaned_set:
                    # Container could not be destroyed this tick.
                    new_attempts = cleanup_attempts + 1
                    self._db.execute(
                        "UPDATE mm_matches SET cleanup_attempts = %s WHERE id = %s",
                        (new_attempts, match_id),
                    )

                    if new_attempts >= self._CLEANUP_MAX_ATTEMPTS:
                        # Force-mark as cleaned to avoid infinite loop.
                        logger.error(
                            "_step_cleanup_servers: match_id=%d container=%s "
                            "could not be destroyed after %d attempts — "
                            "force-marking cleaned_up=1 and releasing resources. "
                            "Manual container removal may be required.",
                            match_id, container_id, new_attempts,
                        )
                        try:
                            self._db.mark_match_cleaned(match_id)
                            if match.get("server_port"):
                                self._db.release_port(match["server_port"])
                            if match.get("gslt_token"):
                                self._db.release_gslt(match["gslt_token"])
                        except Exception as exc:
                            logger.error(
                                "_step_cleanup_servers: force-clean DB error "
                                "match_id=%d: %s",
                                match_id, exc,
                            )
                    else:
                        logger.warning(
                            "_step_cleanup_servers: match_id=%d container=%s "
                            "not cleaned yet (attempt %d/%d)",
                            match_id, container_id,
                            new_attempts, self._CLEANUP_MAX_ATTEMPTS,
                        )
                    continue

                try:
                    self._db.mark_match_cleaned(match_id)
                    if match.get("server_port"):
                        self._db.release_port(match["server_port"])
                    if match.get("gslt_token"):
                        self._db.release_gslt(match["gslt_token"])
                    logger.info(
                        "_step_cleanup_servers: cleaned match_id=%d", match_id
                    )
                except Exception as exc:
                    logger.error(
                        "_step_cleanup_servers: cleanup DB error match_id=%d: %s",
                        match_id, exc,
                    )

        except Exception as exc:
            logger.error("_step_cleanup_servers error: %s", exc, exc_info=True)

    def _step_expire_stale_queue_entries(self) -> None:
        """Expire queue entries that have been waiting too long."""
        try:
            expired = self._queue.expire_stale_entries(max_wait_minutes=15)
            if expired:
                logger.info(
                    "_step_expire_stale_queue_entries: expired %d entries", expired
                )
        except Exception as exc:
            logger.error(
                "_step_expire_stale_queue_entries error: %s", exc, exc_info=True
            )

    def _step_cancel_timed_out_warmups(self) -> None:
        """Cancel warmup matches where the server never went live in time.

        Any match with ``status='warmup'`` and ``started_at`` older than
        ``WARMUP_TIMEOUT`` seconds is cancelled.

        Behaviour per player:

        * **Absent** (``connected=0``) — receive a 5-minute no-show ban.
          Their queue entry is marked ``cancelled`` so they do not
          auto-requeue while banned.
        * **Present** (``connected=1``) — no penalty.  Their queue entry
          is reset to ``waiting`` with the *original* ``queued_at``
          timestamp so they retain their place in line.
        """
        try:
            timeout_dt = datetime.utcnow() - timedelta(
                seconds=self._config.WARMUP_TIMEOUT
            )
            timed_out = self._db.query_all(
                """
                SELECT * FROM mm_matches
                WHERE status = 'warmup'
                  AND started_at < %s
                """,
                (timeout_dt,),
            )

            for match in timed_out:
                match_id = match["id"]
                logger.warning(
                    "_step_cancel_timed_out_warmups: cancelling match_id=%d "
                    "(warmup timeout after %ds)",
                    match_id, self._config.WARMUP_TIMEOUT,
                )

                # Classify players as absent or present.
                player_rows = self._db.query_all(
                    "SELECT steam_id, connected FROM mm_match_players WHERE match_id = %s",
                    (match_id,),
                )
                absent_ids  = [r["steam_id"] for r in player_rows if not r.get("connected")]
                present_ids = [r["steam_id"] for r in player_rows if     r.get("connected")]

                # Short no-show ban for absent players (does not increment
                # abandon_count — missing warmup is less severe than leaving
                # a live match).
                for sid in absent_ids:
                    try:
                        self._db.execute(
                            """
                            INSERT INTO mm_bans
                              (steam_id, reason, expires_at, banned_by, is_active)
                            VALUES
                              (%s, 'No-show at match start',
                               DATE_ADD(NOW(), INTERVAL 5 MINUTE), 'system', 1)
                            """,
                            (sid,),
                        )
                        self._db.execute(
                            """
                            UPDATE mm_players
                            SET is_banned = 1,
                                ban_until = DATE_ADD(NOW(), INTERVAL 5 MINUTE)
                            WHERE steam_id = %s
                            """,
                            (sid,),
                        )
                        logger.info(
                            "_step_cancel_timed_out_warmups: no-show ban "
                            "steam_id=%s match_id=%d",
                            sid, match_id,
                        )
                    except Exception as exc:
                        logger.warning(
                            "_step_cancel_timed_out_warmups: ban error "
                            "steam_id=%s: %s",
                            sid, exc,
                        )

                # Cancel the match record.
                self._db.execute(
                    """
                    UPDATE mm_matches
                    SET status = 'cancelled', cancel_reason = 'warmup_timeout'
                    WHERE id = %s
                    """,
                    (match_id,),
                )

                # Absent players: cancel their queue entry (they are banned
                # and must re-queue manually once the ban expires).
                for sid in absent_ids:
                    try:
                        self._db.execute(
                            "UPDATE mm_queue SET status = 'cancelled' "
                            "WHERE steam_id = %s AND status = 'matched'",
                            (sid,),
                        )
                    except Exception as exc:
                        logger.warning(
                            "_step_cancel_timed_out_warmups: cancel queue "
                            "error steam_id=%s: %s",
                            sid, exc,
                        )

                # Present players: restore queue entry to 'waiting' keeping
                # the original queued_at so they keep their position.
                for sid in present_ids:
                    try:
                        self._db.execute(
                            "UPDATE mm_queue SET status = 'waiting', match_id = NULL "
                            "WHERE steam_id = %s AND status = 'matched'",
                            (sid,),
                        )
                    except Exception as exc:
                        logger.warning(
                            "_step_cancel_timed_out_warmups: requeue error "
                            "steam_id=%s: %s",
                            sid, exc,
                        )

                logger.info(
                    "_step_cancel_timed_out_warmups: match_id=%d cancelled "
                    "absent=%d present=%d (requeued)",
                    match_id, len(absent_ids), len(present_ids),
                )

        except Exception as exc:
            logger.error(
                "_step_cancel_timed_out_warmups error: %s", exc, exc_info=True
            )


# ---------------------------------------------------------------------------
# Module entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """Entry point when the module is run directly.

    Sets up logging, loads configuration, and starts the daemon.
    """
    from matchmaker.config import get_config

    cfg = get_config()
    setup_logging(level="INFO")

    logger.info("Starting CS:GO Matchmaking Daemon")
    logger.info("Config: %r", cfg)

    daemon = MatchmakingDaemon(config=cfg)
    daemon.run()


if __name__ == "__main__":
    main()
