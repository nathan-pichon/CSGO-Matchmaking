"""
Database access layer for the CS:GO matchmaking daemon.

Uses ``mysql.connector.pooling`` to manage a thread-safe connection pool.
All public methods use parameterized queries to prevent SQL injection.
The module exposes a :class:`Database` class and a module-level singleton
:func:`get_db` factory.
"""

from __future__ import annotations

import logging
import secrets
import string
import threading
from contextlib import contextmanager
from typing import Any, Generator, Optional

import mysql.connector
from mysql.connector import pooling

logger = logging.getLogger(__name__)

# Number of pooled connections to pre-allocate.
_POOL_SIZE = 10


class Database:
    """Thread-safe MySQL connection pool with high-level helper methods.

    Args:
        host: MySQL server hostname or IP.
        port: MySQL server port.
        user: MySQL username.
        password: MySQL password.
        database: Database (schema) name.
        pool_size: Number of connections to keep in the pool.
    """

    def __init__(
        self,
        host: str,
        port: int,
        user: str,
        password: str,
        database: str,
        pool_size: int = _POOL_SIZE,
    ) -> None:
        self._pool_config = {
            "pool_name": "mm_pool",
            "pool_size": pool_size,
            "pool_reset_session": True,
            "host": host,
            "port": port,
            "user": user,
            "password": password,
            "database": database,
            "autocommit": False,
            "charset": "utf8mb4",
            "collation": "utf8mb4_unicode_ci",
            "time_zone": "+00:00",
            # Raise PoolError after 10 s instead of blocking indefinitely.
            "connection_timeout": 10,
        }
        self._pool: Optional[pooling.MySQLConnectionPool] = None
        self._lock = threading.Lock()

    # ---------------------------------------------------------------------- #
    # Connection pool management
    # ---------------------------------------------------------------------- #

    def _ensure_pool(self) -> pooling.MySQLConnectionPool:
        """Lazily initialise the connection pool (thread-safe)."""
        if self._pool is None:
            with self._lock:
                if self._pool is None:
                    self._pool = pooling.MySQLConnectionPool(**self._pool_config)
                    logger.info(
                        "MySQL connection pool created (size=%d) → %s:%s/%s",
                        self._pool_config["pool_size"],
                        self._pool_config["host"],
                        self._pool_config["port"],
                        self._pool_config["database"],
                    )
        return self._pool

    @contextmanager
    def get_connection(self) -> Generator[mysql.connector.MySQLConnection, None, None]:
        """Context manager that yields a pooled connection.

        The connection is automatically returned to the pool when the
        ``with`` block exits.  On exception the connection is rolled back
        before being returned.

        Yields:
            A :class:`mysql.connector.MySQLConnection` instance.
        """
        pool = self._ensure_pool()
        conn = pool.get_connection()
        try:
            yield conn
            conn.commit()
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            raise
        finally:
            conn.close()

    # ---------------------------------------------------------------------- #
    # Low-level query helpers
    # ---------------------------------------------------------------------- #

    def execute(
        self,
        query: str,
        params: Optional[tuple | list | dict] = None,
    ) -> None:
        """Execute a DML statement (INSERT / UPDATE / DELETE).

        Args:
            query: Parameterized SQL string.
            params: Positional or named bind parameters.
        """
        with self.get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(query, params or ())

    def query_one(
        self,
        query: str,
        params: Optional[tuple | list | dict] = None,
    ) -> Optional[dict]:
        """Execute a SELECT and return the first row as a dict.

        Args:
            query: Parameterized SQL string.
            params: Positional or named bind parameters.

        Returns:
            A dict mapping column names to values, or ``None`` if no row
            matched.
        """
        with self.get_connection() as conn:
            with conn.cursor(dictionary=True) as cur:
                cur.execute(query, params or ())
                return cur.fetchone()

    def query_all(
        self,
        query: str,
        params: Optional[tuple | list | dict] = None,
    ) -> list[dict]:
        """Execute a SELECT and return all rows as a list of dicts.

        Args:
            query: Parameterized SQL string.
            params: Positional or named bind parameters.

        Returns:
            Possibly empty list of row dicts.
        """
        with self.get_connection() as conn:
            with conn.cursor(dictionary=True) as cur:
                cur.execute(query, params or ())
                return cur.fetchall()

    def execute_transaction(
        self,
        queries_and_params: list[tuple[str, Optional[tuple | list | dict]]],
    ) -> None:
        """Execute multiple statements in a single atomic transaction.

        Args:
            queries_and_params: List of ``(query, params)`` tuples.  All
                statements are committed together; if any raises, all are
                rolled back.
        """
        with self.get_connection() as conn:
            with conn.cursor() as cur:
                for query, params in queries_and_params:
                    cur.execute(query, params or ())

    # ---------------------------------------------------------------------- #
    # Player helpers
    # ---------------------------------------------------------------------- #

    def get_player(self, steam_id: str) -> Optional[dict]:
        """Fetch a player row from ``mm_players`` by Steam ID.

        Args:
            steam_id: Legacy Steam ID string.

        Returns:
            Row dict or ``None``.
        """
        return self.query_one(
            "SELECT * FROM mm_players WHERE steam_id = %s",
            (steam_id,),
        )

    def upsert_player(
        self,
        steam_id: str,
        steam_id64: int,
        name: str,
        default_elo: int = 1000,
    ) -> None:
        """Insert a new player or update their ``steam_id64`` / ``name``.

        The ELO and stats columns are only populated on first insert; they
        are NOT overwritten on subsequent calls to avoid clobbering earned
        progress.

        Args:
            steam_id: Legacy Steam ID string (primary key).
            steam_id64: 64-bit Steam ID.
            name: Player display name (from Steam profile).
            default_elo: Starting ELO for brand-new players.
        """
        self.execute(
            """
            INSERT INTO mm_players
                (steam_id, steam_id64, name, elo, rank_tier,
                 matches_played, matches_won, matches_lost, matches_tied,
                 total_kills, total_deaths, total_assists,
                 total_headshots, total_mvps, is_banned)
            VALUES
                (%s, %s, %s, %s, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            ON DUPLICATE KEY UPDATE
                steam_id64 = VALUES(steam_id64),
                name = VALUES(name)
            """,
            (steam_id, steam_id64, name, default_elo),
        )

    # ---------------------------------------------------------------------- #
    # Queue helpers
    # ---------------------------------------------------------------------- #

    def get_waiting_queue(self) -> list[dict]:
        """Return all queue entries with ``status='waiting'``, oldest first.

        Returns:
            List of row dicts from ``mm_queue``.
        """
        return self.query_all(
            """
            SELECT * FROM mm_queue
            WHERE status = 'waiting'
            ORDER BY queued_at ASC
            """,
        )

    # ---------------------------------------------------------------------- #
    # Resource allocation
    # ---------------------------------------------------------------------- #

    def claim_free_port(self) -> Optional[dict]:
        """Atomically claim an unused server port.

        Uses ``SELECT … FOR UPDATE`` inside a transaction to prevent two
        concurrent callers from claiming the same port.

        Returns:
            Row dict with ``port`` and ``tv_port`` columns, or ``None`` if
            no ports are available.
        """
        with self.get_connection() as conn:
            with conn.cursor(dictionary=True) as cur:
                cur.execute(
                    """
                    SELECT port, tv_port FROM mm_server_ports
                    WHERE in_use = 0
                    LIMIT 1
                    FOR UPDATE
                    """
                )
                row = cur.fetchone()
                if row:
                    cur.execute(
                        "UPDATE mm_server_ports SET in_use = 1 WHERE port = %s",
                        (row["port"],),
                    )
                return row

    def claim_free_gslt(self) -> Optional[dict]:
        """Atomically claim an unused GSLT token.

        Uses ``SELECT … FOR UPDATE`` inside a transaction to prevent races.

        Returns:
            Row dict with ``id`` and ``token`` columns, or ``None`` if no
            tokens are available.
        """
        with self.get_connection() as conn:
            with conn.cursor(dictionary=True) as cur:
                cur.execute(
                    """
                    SELECT id, token FROM mm_gslt_tokens
                    WHERE in_use = 0
                    LIMIT 1
                    FOR UPDATE
                    """
                )
                row = cur.fetchone()
                if row:
                    cur.execute(
                        "UPDATE mm_gslt_tokens SET in_use = 1 WHERE id = %s",
                        (row["id"],),
                    )
                return row

    def release_port(self, port: int) -> None:
        """Mark a server port as free.

        Args:
            port: The port number to release.
        """
        self.execute(
            """
            UPDATE mm_server_ports
            SET in_use = 0, assigned_match_id = NULL
            WHERE port = %s
            """,
            (port,),
        )

    def release_gslt(self, token: str) -> None:
        """Mark a GSLT token as free.

        Args:
            token: The token string to release.
        """
        self.execute(
            """
            UPDATE mm_gslt_tokens
            SET in_use = 0, assigned_match_id = NULL, last_used = NOW()
            WHERE token = %s
            """,
            (token,),
        )

    # ---------------------------------------------------------------------- #
    # Match management
    # ---------------------------------------------------------------------- #

    def create_match(
        self,
        match_token: str,
        map_name: str,
        port: int,
        ip: str,
        password: str,
        gslt: str,
        team1_ids: list[str],
        team2_ids: list[str],
    ) -> int:
        """Create a new match row and its associated player rows.

        All operations are executed in a single transaction.

        Args:
            match_token: Unique token string for the match.
            map_name: Starting map.
            port: Game server port.
            ip: Server IP address (public).
            password: Server connect password.
            gslt: GSLT token string.
            team1_ids: List of Steam IDs for team 1.
            team2_ids: List of Steam IDs for team 2.

        Returns:
            The auto-incremented ``id`` of the new match row.
        """
        with self.get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO mm_matches
                        (match_token, map_name, server_port, server_ip,
                         server_password, gslt_token, status)
                    VALUES (%s, %s, %s, %s, %s, %s, 'creating')
                    """,
                    (match_token, map_name, port, ip, password, gslt),
                )
                match_id: int = cur.lastrowid  # type: ignore[assignment]

                # Update resource tables with the assigned match ID.
                cur.execute(
                    "UPDATE mm_server_ports SET assigned_match_id = %s WHERE port = %s",
                    (match_id, port),
                )
                cur.execute(
                    "UPDATE mm_gslt_tokens SET assigned_match_id = %s WHERE token = %s",
                    (match_id, gslt),
                )

                # Insert mm_match_players rows.
                for steam_id in team1_ids:
                    # Fetch elo_before from mm_players
                    cur.execute(
                        "SELECT elo FROM mm_players WHERE steam_id = %s",
                        (steam_id,),
                    )
                    player_row = cur.fetchone()
                    elo_before = player_row[0] if player_row else 1000
                    cur.execute(
                        """
                        INSERT INTO mm_match_players
                            (match_id, steam_id, team, is_captain,
                             kills, deaths, assists, headshots, mvps,
                             score, damage, connected, abandoned,
                             elo_before, elo_after, elo_change)
                        VALUES (%s, %s, 'team1', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, %s, %s, 0)
                        """,
                        (match_id, steam_id, elo_before, elo_before),
                    )

                for steam_id in team2_ids:
                    cur.execute(
                        "SELECT elo FROM mm_players WHERE steam_id = %s",
                        (steam_id,),
                    )
                    player_row = cur.fetchone()
                    elo_before = player_row[0] if player_row else 1000
                    cur.execute(
                        """
                        INSERT INTO mm_match_players
                            (match_id, steam_id, team, is_captain,
                             kills, deaths, assists, headshots, mvps,
                             score, damage, connected, abandoned,
                             elo_before, elo_after, elo_change)
                        VALUES (%s, %s, 'team2', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, %s, %s, 0)
                        """,
                        (match_id, steam_id, elo_before, elo_before),
                    )

                return match_id

    def update_match_container(self, match_id: int, container_id: str) -> None:
        """Store the Docker container ID for a match and set status to warmup.

        Args:
            match_id: Database ID of the match.
            container_id: Docker container ID string.
        """
        self.execute(
            """
            UPDATE mm_matches
            SET docker_container_id = %s, status = 'warmup', started_at = NOW()
            WHERE id = %s
            """,
            (container_id, match_id),
        )

    def get_matches_needing_cleanup(self) -> list[dict]:
        """Return matches that have ended but have not been cleaned up yet.

        Returns:
            List of row dicts for matches with ``cleaned_up = 0`` and status
            in ``('finished', 'cancelled', 'error')``.
        """
        return self.query_all(
            """
            SELECT * FROM mm_matches
            WHERE cleaned_up = 0
              AND status IN ('finished', 'cancelled', 'error')
            """
        )

    def mark_match_cleaned(self, match_id: int) -> None:
        """Set ``cleaned_up = 1`` for a match.

        Args:
            match_id: Database ID of the match.
        """
        self.execute(
            "UPDATE mm_matches SET cleaned_up = 1 WHERE id = %s",
            (match_id,),
        )

    # ---------------------------------------------------------------------- #
    # Map pool
    # ---------------------------------------------------------------------- #

    def get_active_maps(self) -> list[str]:
        """Return the list of active map names, ordered by weight descending.

        Returns:
            List of ``map_name`` strings.
        """
        rows = self.query_all(
            "SELECT map_name FROM mm_map_pool WHERE is_active = 1 ORDER BY weight DESC"
        )
        return [r["map_name"] for r in rows]

    def get_active_map_pool(self) -> list[dict]:
        """Return full rows for active maps including weight.

        Returns:
            List of row dicts with ``map_name`` and ``weight`` keys.
        """
        return self.query_all(
            "SELECT map_name, weight FROM mm_map_pool WHERE is_active = 1"
        )

    # ---------------------------------------------------------------------- #
    # Fully-ready match groups
    # ---------------------------------------------------------------------- #

    def get_fully_ready_match_groups(self) -> list[dict]:
        """Return match IDs where every player in the ready check is ready.

        A group is "fully ready" when all ``mm_queue`` rows with that
        ``match_id`` and ``status='ready_check'`` have ``ready = 1``.

        Returns:
            List of dicts with ``match_id`` key.
        """
        return self.query_all(
            """
            SELECT match_id
            FROM mm_queue
            WHERE status = 'ready_check'
            GROUP BY match_id
            HAVING COUNT(*) = SUM(ready)
            """
        )

    # ---------------------------------------------------------------------- #
    # ELO / history helpers
    # ---------------------------------------------------------------------- #

    def record_elo_history(
        self,
        steam_id: str,
        match_id: int,
        elo_before: int,
        elo_after: int,
        change_reason: str = "match",
    ) -> None:
        """Insert a row into ``mm_elo_history``.

        Args:
            steam_id: Player's legacy Steam ID.
            match_id: Database ID of the triggering match.
            elo_before: ELO before the change.
            elo_after: ELO after the change.
            change_reason: Short description (e.g. ``'match'``, ``'decay'``).
        """
        self.execute(
            """
            INSERT INTO mm_elo_history
                (steam_id, match_id, elo_before, elo_after, change_reason)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (steam_id, match_id, elo_before, elo_after, change_reason),
        )

    def update_player_after_match(
        self,
        steam_id: str,
        match_id: int,
        elo_change: int,
        won: bool,
        lost: bool,
        tied: bool,
        kills: int,
        deaths: int,
        assists: int,
        headshots: int,
        mvps: int,
    ) -> None:
        """Apply match results to a player's aggregate stats.

        Updates ``mm_players`` totals and the per-match ``mm_match_players``
        row atomically.

        Args:
            steam_id: Player's legacy Steam ID.
            match_id: Database ID of the match.
            elo_change: Signed ELO delta to apply.
            won: True if the player's team won.
            lost: True if the player's team lost.
            tied: True if the match was a tie.
            kills: Kills in this match.
            deaths: Deaths in this match.
            assists: Assists in this match.
            headshots: Headshot kills in this match.
            mvps: MVP stars earned in this match.
        """
        self.execute_transaction(
            [
                (
                    """
                    UPDATE mm_players SET
                        elo = GREATEST(0, elo + %s),
                        rank_tier = (
                            SELECT COALESCE(MAX(tier_index), 0)
                            FROM (
                                SELECT 0  AS tier_index, 0    AS min_elo
                                UNION ALL SELECT 1,  800
                                UNION ALL SELECT 2,  850
                                UNION ALL SELECT 3,  900
                                UNION ALL SELECT 4,  950
                                UNION ALL SELECT 5,  1000
                                UNION ALL SELECT 6,  1050
                                UNION ALL SELECT 7,  1100
                                UNION ALL SELECT 8,  1150
                                UNION ALL SELECT 9,  1200
                                UNION ALL SELECT 10, 1300
                                UNION ALL SELECT 11, 1400
                                UNION ALL SELECT 12, 1500
                                UNION ALL SELECT 13, 1600
                                UNION ALL SELECT 14, 1700
                                UNION ALL SELECT 15, 1800
                                UNION ALL SELECT 16, 1900
                                UNION ALL SELECT 17, 2000
                            ) AS tiers
                            WHERE min_elo <= GREATEST(0, elo + %s)
                        ),
                        matches_played = matches_played + 1,
                        matches_won    = matches_won    + %s,
                        matches_lost   = matches_lost   + %s,
                        matches_tied   = matches_tied   + %s,
                        total_kills    = total_kills    + %s,
                        total_deaths   = total_deaths   + %s,
                        total_assists  = total_assists  + %s,
                        total_headshots = total_headshots + %s,
                        total_mvps     = total_mvps     + %s,
                        last_match     = NOW()
                    WHERE steam_id = %s
                    """,
                    (
                        elo_change,
                        elo_change,
                        int(won),
                        int(lost),
                        int(tied),
                        kills,
                        deaths,
                        assists,
                        headshots,
                        mvps,
                        steam_id,
                    ),
                ),
                (
                    """
                    UPDATE mm_match_players
                    SET elo_change = %s,
                        elo_after  = elo_before + %s,
                        kills      = %s,
                        deaths     = %s,
                        assists    = %s,
                        headshots  = %s,
                        mvps       = %s
                    WHERE match_id = %s AND steam_id = %s
                    """,
                    (
                        elo_change,
                        elo_change,
                        kills,
                        deaths,
                        assists,
                        headshots,
                        mvps,
                        match_id,
                        steam_id,
                    ),
                ),
            ]
        )


# --------------------------------------------------------------------------- #
# Module-level singleton
# --------------------------------------------------------------------------- #

_db_instance: Optional[Database] = None
_db_lock = threading.Lock()


def get_db(
    host: str = "127.0.0.1",
    port: int = 3306,
    user: str = "root",
    password: str = "",
    database: str = "csgo_matchmaking",
    pool_size: int = _POOL_SIZE,
) -> Database:
    """Return the module-level :class:`Database` singleton.

    The first call creates the pool; subsequent calls return the existing
    instance.  Pass configuration only on the first call.

    Args:
        host: MySQL host.
        port: MySQL port.
        user: MySQL username.
        password: MySQL password.
        database: Schema name.
        pool_size: Connection pool size.

    Returns:
        The :class:`Database` singleton.
    """
    global _db_instance
    if _db_instance is None:
        with _db_lock:
            if _db_instance is None:
                _db_instance = Database(
                    host=host,
                    port=port,
                    user=user,
                    password=password,
                    database=database,
                    pool_size=pool_size,
                )
    return _db_instance
