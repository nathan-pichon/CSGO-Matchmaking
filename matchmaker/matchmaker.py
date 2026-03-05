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
            SELECT mp.*, p.matches_played
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

        # Send result notification.
        top_fragger: dict = {}
        if player_stats:
            top_sid = max(player_stats, key=lambda s: player_stats[s].get("kills", 0))
            top_fragger = {
                "steam_id": top_sid,
                **player_stats[top_sid],
                "elo_change": elo_changes.get(top_sid, 0),
            }

        try:
            self._notify.notify_match_result(
                match_id=match_id,
                winner=winner,
                team1_score=match.get("team1_score", 0),
                team2_score=match.get("team2_score", 0),
                top_player=top_fragger,
            )
        except Exception as exc:
            logger.warning("notify_match_result failed: %s", exc)

        logger.info(
            "_process_match_result: match_id=%d winner=%s elo_changes=%s",
            match_id, winner,
            {k: v for k, v in elo_changes.items()},
        )

    def _step_cleanup_servers(self) -> None:
        """Destroy containers and release ports/GSLTs for finished matches."""
        try:
            matches = self._db.get_matches_needing_cleanup()
            if not matches:
                return

            cleaned_ids = self._server.cleanup_finished_servers(matches)
            cleaned_set = set(cleaned_ids)

            for match in matches:
                container_id = match.get("docker_container_id")
                if container_id and container_id not in cleaned_set:
                    # Server could not be destroyed – skip cleanup for now.
                    continue

                match_id = match["id"]
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
        ``WARMUP_TIMEOUT`` seconds is cancelled, resources are released,
        and players are re-queued.
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

                self._db.execute(
                    """
                    UPDATE mm_matches
                    SET status = 'cancelled', cancel_reason = 'warmup_timeout'
                    WHERE id = %s
                    """,
                    (match_id,),
                )

                # Re-queue the players who were matched to this game.
                self._queue.cancel_match_queue(match_id, requeue=True)

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
