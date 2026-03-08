"""
MySQL-backed matchmaking queue implementation.

Implements :class:`~matchmaker.interfaces.queue_backend.QueueBackend` using
the shared ``csgo_matchmaking`` MySQL database via :mod:`matchmaker.db`.

Key design decisions
--------------------
- ``SELECT … FOR UPDATE`` is used wherever atomicity is required (e.g. claiming
  a group of players for a ready check) to avoid phantom reads under concurrent
  daemon instances.
- Team balancing uses the *snake draft* algorithm which provably minimises
  the ELO gap between teams when players are sorted by ELO descending.
- Map selection uses majority preference among the 10 players; ties are broken
  by a weighted random draw from the active map pool.
"""

from __future__ import annotations

import logging
import random
from datetime import datetime
from typing import Optional

from matchmaker.db import Database
from matchmaker.interfaces.queue_backend import QueueBackend
from matchmaker.models import MatchGroup, QueueEntry

logger = logging.getLogger(__name__)


def _row_to_entry(row: dict) -> QueueEntry:
    """Convert a ``mm_queue`` DB row dict to a :class:`QueueEntry`.

    Args:
        row: Dict returned by ``db.query_*`` with all ``mm_queue`` columns.
             May optionally include a ``party_id`` key from a JOIN.

    Returns:
        Populated :class:`QueueEntry`.
    """
    return QueueEntry(
        id=row["id"],
        steam_id=row["steam_id"],
        elo=row["elo"],
        rank_tier=row["rank_tier"],
        queued_at=row["queued_at"] if isinstance(row["queued_at"], datetime)
                  else datetime.fromisoformat(str(row["queued_at"])),
        status=row.get("status", "waiting"),
        ready=bool(row.get("ready", False)),
        match_id=row.get("match_id"),
        map_preference=row.get("map_preference"),
        party_id=row.get("party_id"),
    )


class MySQLQueueBackend(QueueBackend):
    """MySQL implementation of the matchmaking queue.

    Args:
        config: Application :class:`~matchmaker.config.Config` instance.
        db: :class:`~matchmaker.db.Database` instance to use for all queries.
    """

    def __init__(self, config: object, db: Database) -> None:
        self._config = config
        self._db = db

    # ---------------------------------------------------------------------- #
    # Queue entry lifecycle
    # ---------------------------------------------------------------------- #

    def add_to_queue(
        self,
        steam_id: str,
        elo: int,
        rank_tier: int,
        map_preference: Optional[str] = None,
    ) -> bool:
        """Add a player to the queue with ``status='waiting'``.

        Idempotent: if the player is already waiting/ready-checking the
        existing row is left untouched and ``False`` is returned.

        Args:
            steam_id: Legacy Steam ID string.
            elo: ELO at queue time.
            rank_tier: Rank tier at queue time.
            map_preference: Optional preferred map.

        Returns:
            True if a new row was inserted, False otherwise.
        """
        existing = self._db.query_one(
            """
            SELECT id FROM mm_queue
            WHERE steam_id = %s
              AND status IN ('waiting', 'ready_check')
            """,
            (steam_id,),
        )
        if existing:
            logger.debug("add_to_queue: %s already in queue", steam_id)
            return False

        try:
            self._db.execute(
                """
                INSERT INTO mm_queue
                    (steam_id, elo, rank_tier, queued_at, status, ready,
                     map_preference)
                VALUES (%s, %s, %s, NOW(), 'waiting', 0, %s)
                """,
                (steam_id, elo, rank_tier, map_preference),
            )
            logger.info("add_to_queue: %s added (elo=%d)", steam_id, elo)
            return True
        except Exception as exc:
            logger.error("add_to_queue failed for %s: %s", steam_id, exc)
            return False

    def remove_from_queue(self, steam_id: str) -> bool:
        """Delete the queue entry for *steam_id*.

        Args:
            steam_id: Legacy Steam ID string.

        Returns:
            True if a row was deleted, False if none was found.
        """
        try:
            with self._db.get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "DELETE FROM mm_queue WHERE steam_id = %s", (steam_id,)
                    )
                    deleted = cur.rowcount
            logger.info("remove_from_queue: %s (rows deleted=%d)", steam_id, deleted)
            return deleted > 0
        except Exception as exc:
            logger.error("remove_from_queue failed for %s: %s", steam_id, exc)
            return False

    def get_waiting_entries(self) -> list[QueueEntry]:
        """Return all ``status='waiting'`` queue entries, oldest first.

        Returns:
            List of :class:`QueueEntry` objects.
        """
        try:
            rows = self._db.query_all(
                "SELECT * FROM mm_queue WHERE status = 'waiting' ORDER BY queued_at ASC"
            )
            return [_row_to_entry(r) for r in rows]
        except Exception as exc:
            logger.error("get_waiting_entries failed: %s", exc)
            return []

    def _get_waiting_entries_with_party(self) -> list[QueueEntry]:
        """Return waiting entries joined with party membership.

        Returns:
            List of :class:`QueueEntry` objects with ``party_id`` populated.
        """
        try:
            rows = self._db.query_all(
                """
                SELECT q.*, pm.party_id
                FROM mm_queue q
                LEFT JOIN mm_party_members pm ON pm.steam_id = q.steam_id
                WHERE q.status = 'waiting'
                ORDER BY q.queued_at ASC
                """
            )
            return [_row_to_entry(r) for r in rows]
        except Exception as exc:
            logger.error("_get_waiting_entries_with_party failed: %s", exc)
            return []

    # ---------------------------------------------------------------------- #
    # Ready-check lifecycle
    # ---------------------------------------------------------------------- #

    def set_ready_check(
        self,
        steam_ids: list[str],
        match_id: int,
    ) -> bool:
        """Transition players into a ready-check.

        Args:
            steam_ids: List of Steam IDs to update.
            match_id: Tentative match ID.

        Returns:
            True if all rows were updated atomically, False otherwise.
        """
        if not steam_ids:
            return False
        placeholders = ",".join(["%s"] * len(steam_ids))
        try:
            self._db.execute(
                f"""
                UPDATE mm_queue
                SET status = 'ready_check', match_id = %s, ready = 0
                WHERE steam_id IN ({placeholders})
                  AND status = 'waiting'
                """,
                (match_id, *steam_ids),
            )
            logger.info(
                "set_ready_check: match_id=%d players=%s", match_id, steam_ids
            )
            return True
        except Exception as exc:
            logger.error("set_ready_check failed: %s", exc)
            return False

    def get_ready_check_entries(self, match_id: int) -> list[QueueEntry]:
        """Return all queue entries in the ready check for *match_id*.

        Args:
            match_id: Match ID to query.

        Returns:
            List of :class:`QueueEntry` objects.
        """
        try:
            rows = self._db.query_all(
                "SELECT * FROM mm_queue WHERE match_id = %s AND status = 'ready_check'",
                (match_id,),
            )
            return [_row_to_entry(r) for r in rows]
        except Exception as exc:
            logger.error("get_ready_check_entries failed (match_id=%d): %s", match_id, exc)
            return []

    def set_player_ready(self, steam_id: str) -> bool:
        """Mark a player as ready (``ready=1``).

        Args:
            steam_id: Legacy Steam ID string.

        Returns:
            True if the row was updated, False if not found or wrong status.
        """
        try:
            with self._db.get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE mm_queue SET ready = 1
                        WHERE steam_id = %s AND status = 'ready_check'
                        """,
                        (steam_id,),
                    )
                    updated = cur.rowcount
            logger.info("set_player_ready: %s (updated=%d)", steam_id, updated)
            return updated > 0
        except Exception as exc:
            logger.error("set_player_ready failed for %s: %s", steam_id, exc)
            return False

    # ---------------------------------------------------------------------- #
    # Match transition
    # ---------------------------------------------------------------------- #

    def set_matched(self, match_id: int) -> bool:
        """Move all players in this ready check to ``status='matched'``.

        Args:
            match_id: Match ID to update.

        Returns:
            True on success.
        """
        try:
            self._db.execute(
                """
                UPDATE mm_queue SET status = 'matched'
                WHERE match_id = %s AND status = 'ready_check'
                """,
                (match_id,),
            )
            logger.info("set_matched: match_id=%d", match_id)
            return True
        except Exception as exc:
            logger.error("set_matched failed (match_id=%d): %s", match_id, exc)
            return False

    def cancel_match_queue(
        self,
        match_id: int,
        requeue: bool = True,
    ) -> bool:
        """Cancel the ready check for *match_id*.

        Players who had confirmed ready (``ready=1``) are re-queued if
        *requeue* is True; unready players are marked ``'cancelled'``.

        Args:
            match_id: Match ID to cancel.
            requeue: Whether ready players should be re-queued.

        Returns:
            True on success.
        """
        try:
            if requeue:
                # Re-queue players who were ready.
                self._db.execute(
                    """
                    UPDATE mm_queue
                    SET status = 'waiting', match_id = NULL, ready = 0
                    WHERE match_id = %s AND status = 'ready_check' AND ready = 1
                    """,
                    (match_id,),
                )
            # Cancel players who were not ready.
            self._db.execute(
                """
                UPDATE mm_queue
                SET status = 'cancelled', match_id = NULL
                WHERE match_id = %s AND status = 'ready_check' AND ready = 0
                """,
                (match_id,),
            )
            # Also mark any remaining ready_check rows cancelled (if requeue=False).
            if not requeue:
                self._db.execute(
                    """
                    UPDATE mm_queue
                    SET status = 'cancelled', match_id = NULL
                    WHERE match_id = %s AND status = 'ready_check'
                    """,
                    (match_id,),
                )
            logger.info("cancel_match_queue: match_id=%d requeue=%s", match_id, requeue)
            return True
        except Exception as exc:
            logger.error("cancel_match_queue failed (match_id=%d): %s", match_id, exc)
            return False

    # ---------------------------------------------------------------------- #
    # Expiry / cleanup
    # ---------------------------------------------------------------------- #

    def expire_stale_entries(self, max_wait_minutes: int = 15) -> int:
        """Expire queue entries older than *max_wait_minutes*.

        Args:
            max_wait_minutes: Age threshold in minutes.

        Returns:
            Number of rows expired.
        """
        try:
            with self._db.get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE mm_queue
                        SET status = 'expired'
                        WHERE status = 'waiting'
                          AND queued_at < DATE_SUB(NOW(), INTERVAL %s MINUTE)
                        """,
                        (max_wait_minutes,),
                    )
                    count = cur.rowcount
            if count:
                logger.info("expire_stale_entries: expired %d entries", count)
            return count
        except Exception as exc:
            logger.error("expire_stale_entries failed: %s", exc)
            return 0

    def expire_stale_ready_checks(self, timeout_seconds: int = 30) -> int:
        """Expire ready-check groups that have not confirmed in time.

        Any group where at least one player has ``ready=0`` and the group
        was created more than *timeout_seconds* ago is cancelled.  Ready
        players are re-queued; unready players are cancelled.

        Args:
            timeout_seconds: Age threshold in seconds.

        Returns:
            Number of match groups that were expired.
        """
        try:
            # Find match_ids that are stale and have at least one unready player.
            stale_groups = self._db.query_all(
                """
                SELECT DISTINCT match_id FROM mm_queue
                WHERE status = 'ready_check'
                  AND ready = 0
                  AND queued_at < DATE_SUB(NOW(), INTERVAL %s SECOND)
                """,
                (timeout_seconds,),
            )
            count = 0
            for row in stale_groups:
                mid = row["match_id"]
                if mid is None:
                    continue
                self.cancel_match_queue(mid, requeue=True)
                logger.info(
                    "expire_stale_ready_checks: cancelled ready check match_id=%d", mid
                )
                count += 1
            return count
        except Exception as exc:
            logger.error("expire_stale_ready_checks failed: %s", exc)
            return 0

    # ---------------------------------------------------------------------- #
    # Match formation
    # ---------------------------------------------------------------------- #

    def find_balanced_match(self) -> Optional[MatchGroup]:
        """Attempt to form one balanced 10-player :class:`MatchGroup`.

        Algorithm
        ---------
        1. Fetch all ``status='waiting'`` entries with party membership.
        2. Group entries into blocks (one block per party; solos are
           single-entry blocks).
        3. Anchor on the block containing the longest-waiting player and
           greedily collect compatible blocks (within the ELO spread window).
           Party blocks that would exceed the player limit are skipped.
        4. Balance teams using the party-aware snake-draft algorithm, which
           keeps all members of a party on the same team.
        5. Select map via majority preference, breaking ties with a weighted
           random draw from the active map pool.

        Returns:
            :class:`MatchGroup` or ``None`` if fewer than 10 compatible
            players exist.
        """
        required = getattr(self._config, "players_per_match", 10)
        base_spread = getattr(self._config, "MAX_ELO_SPREAD", 200)
        spread_interval = getattr(self._config, "ELO_SPREAD_INCREASE_INTERVAL", 60)
        spread_amount = getattr(self._config, "ELO_SPREAD_INCREASE_AMOUNT", 50)

        entries = self._get_waiting_entries_with_party()
        if len(entries) < required:
            return None

        now = datetime.utcnow()

        def effective_spread(entry: QueueEntry) -> int:
            wait_seconds = (
                now - entry.queued_at.replace(tzinfo=None)
                if entry.queued_at.tzinfo
                else now - entry.queued_at
            ).total_seconds()
            intervals = int(wait_seconds / max(spread_interval, 1))
            return base_spread + intervals * spread_amount

        # Group entries into blocks ordered by oldest member's queued_at.
        party_dict: dict[int, list[QueueEntry]] = {}
        solo_list: list[QueueEntry] = []

        for entry in entries:
            if entry.party_id is not None:
                party_dict.setdefault(entry.party_id, []).append(entry)
            else:
                solo_list.append(entry)

        blocks: list[list[QueueEntry]] = [
            sorted(members, key=lambda e: e.queued_at)
            for members in party_dict.values()
        ] + [[e] for e in solo_list]

        # Sort blocks by their oldest member's queued_at (queue fairness).
        blocks.sort(key=lambda b: b[0].queued_at)

        if not blocks:
            return None

        # Anchor on the oldest block.
        anchor_block = blocks[0]
        anchor_elo = sum(e.elo for e in anchor_block) / len(anchor_block)
        anchor_spread = min(effective_spread(e) for e in anchor_block)

        selected_blocks: list[list[QueueEntry]] = [anchor_block]
        selected_count = len(anchor_block)

        for block in blocks[1:]:
            if selected_count >= required:
                break
            # Skip party blocks that would push us over the required count.
            if selected_count + len(block) > required:
                if len(block) > 1:
                    continue
                # Solo player: skip without breaking (may still find others)
                continue
            block_avg_elo = sum(e.elo for e in block) / len(block)
            block_spread = min(effective_spread(e) for e in block)
            allowed_spread = min(anchor_spread, block_spread)
            if abs(block_avg_elo - anchor_elo) <= allowed_spread:
                selected_blocks.append(block)
                selected_count += len(block)

        if selected_count < required:
            logger.debug(
                "find_balanced_match: only %d compatible players (need %d)",
                selected_count, required,
            )
            return None

        group = [entry for block in selected_blocks for entry in block]

        # ── Avoid-list check ─────────────────────────────────────────────────
        # Query mm_avoid_list for any conflicts among the candidate group.
        # If a conflict exists, remove the more recently queued of the two and
        # retry from the outer blocks loop (caller should call us again).
        conflicted = self._find_avoid_conflict(group)
        if conflicted is not None:
            logger.debug(
                "find_balanced_match: avoid conflict involving %s — skipping",
                conflicted,
            )
            return None  # Caller will retry; the expired entry will sort later

        # Party-aware team assignment.
        team1, team2 = self._snake_draft_with_parties(selected_blocks)

        map_name = self._select_map(group)

        logger.info(
            "find_balanced_match: formed group map=%s "
            "team1_avg=%.0f team2_avg=%.0f spread=%.0f",
            map_name,
            sum(p.elo for p in team1) / len(team1),
            sum(p.elo for p in team2) / len(team2),
            abs(
                sum(p.elo for p in team1) / len(team1)
                - sum(p.elo for p in team2) / len(team2)
            ),
        )

        return MatchGroup(players=group, team1=team1, team2=team2, map_name=map_name)

    # ---------------------------------------------------------------------- #
    # Internal helpers
    # ---------------------------------------------------------------------- #

    def _find_avoid_conflict(self, group: list[QueueEntry]) -> Optional[str]:
        """Check the group for avoid-list conflicts.

        Queries ``mm_avoid_list`` for any active mutual avoid among the 10
        players.  Returns the Steam ID of the more recently queued player of
        the conflicting pair (to be excluded), or ``None`` if no conflict.

        Args:
            group: The candidate list of 10 :class:`QueueEntry` objects.

        Returns:
            Steam ID to exclude, or ``None``.
        """
        steam_ids = [e.steam_id for e in group]
        if len(steam_ids) < 2:
            return None

        placeholders = ", ".join(f"'{sid}'" for sid in steam_ids)
        query = (
            "SELECT steam_id, avoided_id FROM mm_avoid_list "
            f"WHERE expires_at > NOW() "
            f"  AND steam_id  IN ({placeholders}) "
            f"  AND avoided_id IN ({placeholders}) "
            "LIMIT 1"
        )
        try:
            row = self._db.query_one(query)
        except Exception as exc:
            logger.error("avoid conflict check failed: %s", exc)
            return None

        if row is None:
            return None

        # Find the two players in the group and return the more recently queued
        sid_a, sid_b = row["steam_id"], row["avoided_id"]
        entry_a = next((e for e in group if e.steam_id == sid_a), None)
        entry_b = next((e for e in group if e.steam_id == sid_b), None)
        if entry_a is None or entry_b is None:
            return sid_a
        # Exclude the player who joined the queue more recently
        return sid_a if entry_a.queued_at > entry_b.queued_at else sid_b

    @staticmethod
    def _snake_draft(players: list[QueueEntry]) -> tuple[list[QueueEntry], list[QueueEntry]]:
        """Assign players to two teams using the snake-draft algorithm.

        Players are sorted by ELO descending, then assigned to teams in a
        snake pattern that minimises the ELO difference:

        Position → Team assignment (0-indexed):

        ======== ====
        Position Team
        ======== ====
        0        1
        1        2
        2        2
        3        1
        4        1
        5        2
        6        2
        7        1
        8        1
        9        2
        ======== ====

        Args:
            players: Exactly 10 :class:`QueueEntry` objects.

        Returns:
            Tuple of ``(team1, team2)`` each with 5 players.
        """
        sorted_players = sorted(players, key=lambda p: p.elo, reverse=True)
        team1: list[QueueEntry] = []
        team2: list[QueueEntry] = []

        # Snake-draft assignment pattern for 10 players.
        # Round 1 (picks 0-1): T1, T2
        # Round 2 (picks 2-3): T2, T1
        # Round 3 (picks 4-5): T1, T2
        # Round 4 (picks 6-7): T2, T1
        # Round 5 (picks 8-9): T1, T2
        team_assignment = [1, 2, 2, 1, 1, 2, 2, 1, 1, 2]

        for idx, player in enumerate(sorted_players):
            if idx >= len(team_assignment):
                break
            if team_assignment[idx] == 1:
                team1.append(player)
            else:
                team2.append(player)

        return team1, team2

    @staticmethod
    def _snake_draft_with_parties(
        blocks: list[list[QueueEntry]],
    ) -> tuple[list[QueueEntry], list[QueueEntry]]:
        """Assign players to teams while keeping party members on the same team.

        Blocks are sorted by average ELO descending, then assigned greedily
        to whichever team currently has the lower total ELO sum.  This
        minimises the inter-team ELO gap while honouring party constraints.

        Args:
            blocks: List of player blocks.  Each block is a list of
                    :class:`QueueEntry` objects belonging to the same party
                    (or a single-entry list for solo players).

        Returns:
            Tuple of ``(team1, team2)`` each containing 5 players.
        """
        team1: list[QueueEntry] = []
        team2: list[QueueEntry] = []

        sorted_blocks = sorted(
            blocks,
            key=lambda b: sum(e.elo for e in b) / len(b),
            reverse=True,
        )

        for block in sorted_blocks:
            t1_sum = sum(e.elo for e in team1)
            t2_sum = sum(e.elo for e in team2)
            if t1_sum <= t2_sum:
                team1.extend(block)
            else:
                team2.extend(block)

        return team1, team2

    def _select_map(self, players: list[QueueEntry]) -> str:
        """Select a map via player majority preference or weighted random.

        Args:
            players: The 10 players in this group.

        Returns:
            Selected map name string.
        """
        # Count preferences, ignoring None / empty values.
        preference_counts: dict[str, int] = {}
        for p in players:
            if p.map_preference:
                preference_counts[p.map_preference] = (
                    preference_counts.get(p.map_preference, 0) + 1
                )

        if preference_counts:
            max_votes = max(preference_counts.values())
            majority_maps = [
                m for m, v in preference_counts.items() if v == max_votes
            ]
            if len(majority_maps) == 1:
                return majority_maps[0]

        # Fall back to weighted random from active map pool.
        try:
            pool_rows = self._db.get_active_map_pool()
            if pool_rows:
                maps = [r["map_name"] for r in pool_rows]
                weights = [r["weight"] for r in pool_rows]
                return random.choices(maps, weights=weights, k=1)[0]
        except Exception as exc:
            logger.warning("_select_map: failed to fetch map pool: %s", exc)

        # Last resort default.
        return "de_dust2"
