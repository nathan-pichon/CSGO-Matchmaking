-- ============================================================
-- CS:GO Matchmaking System - Database Schema
-- ============================================================
-- Designed to coexist peacefully with Levels Ranks tables.
-- All matchmaking tables are prefixed with mm_.
-- Levels Ranks uses lvl_base (read-only from our side).
--
-- This schema is fully idempotent: safe to re-run at any time.
-- Run with: mysql -u root -p csgo_matchmaking < schema.sql
-- ============================================================

CREATE DATABASE IF NOT EXISTS csgo_matchmaking
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE csgo_matchmaking;

-- ============================================================
-- 1. SEASONS
-- Must exist before mm_players (foreign key reference).
-- Tracks competitive seasons with ELO resets.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_seasons (
  id            INT           NOT NULL AUTO_INCREMENT,
  name          VARCHAR(64)   NOT NULL,
  start_date    DATE          NOT NULL,
  end_date      DATE          NULL,
  is_active     TINYINT(1)    NOT NULL DEFAULT 0,
  elo_reset_to  INT           NOT NULL DEFAULT 1000 COMMENT 'ELO value to soft-reset to at season start',
  created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  INDEX idx_active (is_active)
) ENGINE=InnoDB COMMENT='Competitive seasons with ELO reset support';

-- ============================================================
-- 2. PLAYERS
-- Authoritative player record. ELO here is the ranking ELO,
-- separate from Levels Ranks experience points.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_players (
  steam_id          VARCHAR(32)     NOT NULL COMMENT 'SteamID in STEAM_X:Y:Z format',
  steam_id64        BIGINT UNSIGNED NOT NULL COMMENT '64-bit SteamID (steamid64)',
  name              VARCHAR(64)     NOT NULL DEFAULT 'Unknown',
  elo               INT             NOT NULL DEFAULT 1000 COMMENT 'Current ELO rating',
  elo_peak          INT             NOT NULL DEFAULT 1000 COMMENT 'Highest ELO ever achieved',
  rank_tier         TINYINT         NOT NULL DEFAULT 5 COMMENT '0=Silver I ... 17=Global Elite',
  matches_played    INT             NOT NULL DEFAULT 0,
  matches_won       INT             NOT NULL DEFAULT 0,
  matches_lost      INT             NOT NULL DEFAULT 0,
  matches_tied      INT             NOT NULL DEFAULT 0,
  win_streak        INT             NOT NULL DEFAULT 0 COMMENT 'Current consecutive wins',
  best_streak       INT             NOT NULL DEFAULT 0 COMMENT 'Best all-time win streak',
  total_kills       INT             NOT NULL DEFAULT 0,
  total_deaths      INT             NOT NULL DEFAULT 0,
  total_assists     INT             NOT NULL DEFAULT 0,
  total_headshots   INT             NOT NULL DEFAULT 0,
  total_mvps        INT             NOT NULL DEFAULT 0,
  last_match        DATETIME        NULL,
  last_queue        DATETIME        NULL,
  created_at        DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  is_banned         TINYINT(1)      NOT NULL DEFAULT 0,
  ban_until         DATETIME        NULL,
  season_id         INT             NOT NULL DEFAULT 1,
  PRIMARY KEY (steam_id),
  UNIQUE KEY uq_steam64 (steam_id64),
  INDEX idx_elo (elo),
  INDEX idx_rank_tier (rank_tier),
  INDEX idx_season (season_id),
  INDEX idx_last_match (last_match),
  CONSTRAINT fk_player_season FOREIGN KEY (season_id)
    REFERENCES mm_seasons (id) ON UPDATE CASCADE
) ENGINE=InnoDB COMMENT='Player records with ELO and aggregate statistics';

-- ============================================================
-- 3. QUEUE
-- Polled by the Python matchmaker daemon every 2 seconds.
-- Each row represents one player's current queue entry.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_queue (
  id              INT           NOT NULL AUTO_INCREMENT,
  steam_id        VARCHAR(32)   NOT NULL,
  elo             INT           NOT NULL COMMENT 'ELO snapshot at queue time',
  rank_tier       TINYINT       NOT NULL DEFAULT 5,
  queued_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status          ENUM(
    'waiting',      -- in queue, waiting for match
    'ready_check',  -- match found, awaiting accept/decline
    'matched',      -- accepted, being redirected to match server
    'expired',      -- timed out (15 min in queue)
    'cancelled'     -- declined ready check or match cancelled
  )               NOT NULL DEFAULT 'waiting',
  ready           TINYINT(1)    NOT NULL DEFAULT 0 COMMENT '1 when player accepted ready check',
  match_id        INT           NULL COMMENT 'Set when matched',
  map_preference  VARCHAR(32)   NULL COMMENT 'Optional preferred map (e.g. de_mirage)',
  PRIMARY KEY (id),
  -- A player can only have one active queue entry
  UNIQUE KEY uq_steam_active (steam_id, status),
  INDEX idx_status_elo (status, elo),
  INDEX idx_queued_at (queued_at),
  INDEX idx_match_id (match_id),
  CONSTRAINT fk_queue_player FOREIGN KEY (steam_id)
    REFERENCES mm_players (steam_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB COMMENT='Active queue entries polled by the matchmaker daemon';

-- ============================================================
-- 4. GSLT TOKEN POOL
-- One GSLT token per match server. Claimed before container
-- spin-up, released after container destruction.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_gslt_tokens (
  id                  INT           NOT NULL AUTO_INCREMENT,
  token               VARCHAR(64)   NOT NULL COMMENT 'Steam GSLT token string',
  in_use              TINYINT(1)    NOT NULL DEFAULT 0,
  assigned_match_id   INT           NULL,
  last_used           DATETIME      NULL,
  created_at          DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_token (token),
  INDEX idx_available (in_use)
) ENGINE=InnoDB COMMENT='Pool of GSLT tokens, one per match server instance';

-- ============================================================
-- 5. SERVER PORT POOL
-- Pre-allocated port ranges to avoid Docker port conflicts.
-- Lobby: 27015 (hardcoded). Match servers: 27020-27039.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_server_ports (
  port                INT           NOT NULL COMMENT 'Main server port (UDP/TCP)',
  tv_port             INT           NOT NULL COMMENT 'SourceTV port',
  in_use              TINYINT(1)    NOT NULL DEFAULT 0,
  assigned_match_id   INT           NULL,
  PRIMARY KEY (port),
  UNIQUE KEY uq_tv_port (tv_port),
  INDEX idx_available (in_use)
) ENGINE=InnoDB COMMENT='Pre-allocated port pool for match server containers';

-- ============================================================
-- 6. MATCHES
-- Each row represents one 5v5 competitive match.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_matches (
  id                    INT           NOT NULL AUTO_INCREMENT,
  match_token           VARCHAR(64)   NOT NULL COMMENT 'Random hex token, used as server password',
  map_name              VARCHAR(32)   NOT NULL DEFAULT 'de_dust2',
  server_port           INT           NOT NULL,
  server_ip             VARCHAR(45)   NOT NULL,
  server_password       VARCHAR(32)   NOT NULL COMMENT 'First 12 chars of match_token',
  gslt_token            VARCHAR(64)   NOT NULL,
  docker_container_id   VARCHAR(80)   NULL COMMENT 'Docker container short ID',
  status                ENUM(
    'creating',   -- container being spun up
    'warmup',     -- waiting for all players to connect
    'live',       -- match in progress
    'overtime',   -- match in OT
    'finished',   -- match complete, stats saved
    'cancelled',  -- cancelled (player no-show, error, etc.)
    'error'       -- unexpected failure
  )                     NOT NULL DEFAULT 'creating',
  team1_score           TINYINT       NOT NULL DEFAULT 0,
  team2_score           TINYINT       NOT NULL DEFAULT 0,
  winner                ENUM('team1', 'team2', 'tie') NULL,
  cancel_reason         VARCHAR(255)  NULL,
  cleaned_up            TINYINT(1)    NOT NULL DEFAULT 0 COMMENT '1 after container destroyed and ports released',
  cleanup_attempts      TINYINT       NOT NULL DEFAULT 0 COMMENT 'Failed cleanup attempts; forced clean at 5',
  started_at            DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  live_at               DATETIME      NULL COMMENT 'When knife round ends / match goes live',
  ended_at              DATETIME      NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_token (match_token),
  INDEX idx_status (status),
  INDEX idx_started (started_at),
  INDEX idx_cleanup (status, cleaned_up)
) ENGINE=InnoDB COMMENT='Match records including server details and results';

-- ============================================================
-- 7. MATCH PLAYERS
-- Per-player statistics for each match.
-- One row per player per match.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_match_players (
  id              INT           NOT NULL AUTO_INCREMENT,
  match_id        INT           NOT NULL,
  steam_id        VARCHAR(32)   NOT NULL,
  team            ENUM('team1', 'team2') NOT NULL,
  is_captain      TINYINT(1)    NOT NULL DEFAULT 0 COMMENT 'Highest ELO player on each team',
  kills           INT           NOT NULL DEFAULT 0,
  deaths          INT           NOT NULL DEFAULT 0,
  assists         INT           NOT NULL DEFAULT 0,
  headshots       INT           NOT NULL DEFAULT 0,
  mvps            INT           NOT NULL DEFAULT 0,
  score           INT           NOT NULL DEFAULT 0 COMMENT 'CS:GO scoreboard score',
  damage          INT           NOT NULL DEFAULT 0 COMMENT 'Total damage dealt',
  connected       TINYINT(1)    NOT NULL DEFAULT 0 COMMENT '1 if player connected to match server',
  connected_at    DATETIME      NULL,
  abandoned       TINYINT(1)    NOT NULL DEFAULT 0 COMMENT '1 if player disconnected early',
  elo_before      INT           NOT NULL DEFAULT 0 COMMENT 'ELO before this match',
  elo_after       INT           NULL,
  elo_change      INT           NULL COMMENT 'Positive = gain, negative = loss',
  PRIMARY KEY (id),
  UNIQUE KEY uq_match_player (match_id, steam_id),
  INDEX idx_steam (steam_id),
  INDEX idx_match (match_id),
  CONSTRAINT fk_mp_match FOREIGN KEY (match_id)
    REFERENCES mm_matches (id) ON DELETE CASCADE,
  CONSTRAINT fk_mp_player FOREIGN KEY (steam_id)
    REFERENCES mm_players (steam_id) ON UPDATE CASCADE
) ENGINE=InnoDB COMMENT='Per-player statistics for each match';

-- ============================================================
-- 8. ELO HISTORY
-- Append-only log of every ELO change for graphs and auditing.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_elo_history (
  id              INT           NOT NULL AUTO_INCREMENT,
  steam_id        VARCHAR(32)   NOT NULL,
  match_id        INT           NULL COMMENT 'NULL for non-match changes (decay, admin)',
  elo_before      INT           NOT NULL,
  elo_after       INT           NOT NULL,
  change_reason   ENUM(
    'match',          -- result of a competitive match
    'decay',          -- inactivity decay
    'placement',      -- placement match bonus/adjustment
    'admin',          -- manual admin override
    'season_reset'    -- soft reset at new season start
  )               NOT NULL DEFAULT 'match',
  created_at      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  INDEX idx_steam_time (steam_id, created_at),
  CONSTRAINT fk_elo_player FOREIGN KEY (steam_id)
    REFERENCES mm_players (steam_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB COMMENT='Append-only ELO change log for graphs and auditing';

-- ============================================================
-- 9. BANS
-- Matchmaking bans (separate from game bans).
-- Both temporary and permanent bans.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_bans (
  id              INT           NOT NULL AUTO_INCREMENT,
  steam_id        VARCHAR(32)   NOT NULL,
  reason          VARCHAR(255)  NOT NULL,
  banned_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at      DATETIME      NULL COMMENT 'NULL = permanent ban',
  banned_by       VARCHAR(32)   NULL COMMENT 'Admin SteamID or "system"',
  is_active       TINYINT(1)    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  INDEX idx_steam_active (steam_id, is_active),
  INDEX idx_expires (expires_at, is_active),
  CONSTRAINT fk_ban_player FOREIGN KEY (steam_id)
    REFERENCES mm_players (steam_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB COMMENT='Matchmaking ban records';

-- ============================================================
-- 10. MAP POOL
-- Active competitive maps with selection weight.
-- ============================================================
CREATE TABLE IF NOT EXISTS mm_map_pool (
  id            INT           NOT NULL AUTO_INCREMENT,
  map_name      VARCHAR(32)   NOT NULL COMMENT 'Internal CS:GO map name (e.g. de_dust2)',
  display_name  VARCHAR(64)   NOT NULL COMMENT 'Human-friendly name (e.g. Dust II)',
  is_active     TINYINT(1)    NOT NULL DEFAULT 1,
  weight        INT           NOT NULL DEFAULT 1 COMMENT 'Higher = more likely in random selection',
  PRIMARY KEY (id),
  UNIQUE KEY uq_map (map_name),
  INDEX idx_active (is_active)
) ENGINE=InnoDB COMMENT='Active map pool for match selection';

-- ============================================================
-- SEED DATA
-- Default values to get the system running immediately.
-- All use INSERT IGNORE to be safe on re-runs.
-- ============================================================

-- Default season
INSERT IGNORE INTO mm_seasons (id, name, start_date, is_active, elo_reset_to)
VALUES (1, 'Season 1', CURDATE(), 1, 1000);

-- Default map pool (official competitive maps)
INSERT IGNORE INTO mm_map_pool (map_name, display_name, is_active, weight) VALUES
  ('de_dust2',    'Dust II',    1, 2),
  ('de_mirage',   'Mirage',     1, 2),
  ('de_inferno',  'Inferno',    1, 2),
  ('de_nuke',     'Nuke',       1, 1),
  ('de_overpass', 'Overpass',   1, 1),
  ('de_ancient',  'Ancient',    1, 1),
  ('de_vertigo',  'Vertigo',    1, 1);

-- Default server port pool (10 match servers: 27020-27029)
-- Lobby server uses 27015 (not in this pool)
INSERT IGNORE INTO mm_server_ports (port, tv_port) VALUES
  (27020, 27120),
  (27021, 27121),
  (27022, 27122),
  (27023, 27123),
  (27024, 27124),
  (27025, 27125),
  (27026, 27126),
  (27027, 27127),
  (27028, 27128),
  (27029, 27129);

-- ============================================================
-- USEFUL VIEWS (optional but helpful for web panel / debugging)
-- ============================================================

CREATE OR REPLACE VIEW mm_player_stats AS
SELECT
  p.steam_id,
  p.steam_id64,
  p.name,
  p.elo,
  p.elo_peak,
  p.rank_tier,
  p.matches_played,
  p.matches_won,
  p.matches_lost,
  p.matches_tied,
  CASE
    WHEN p.matches_played > 0
    THEN ROUND(p.matches_won * 100.0 / p.matches_played, 1)
    ELSE 0
  END AS win_rate_pct,
  p.total_kills,
  p.total_deaths,
  CASE
    WHEN p.total_deaths > 0
    THEN ROUND(p.total_kills * 1.0 / p.total_deaths, 2)
    ELSE p.total_kills
  END AS kd_ratio,
  CASE
    WHEN p.total_kills > 0
    THEN ROUND(p.total_headshots * 100.0 / p.total_kills, 1)
    ELSE 0
  END AS hs_pct,
  p.win_streak,
  p.best_streak,
  p.last_match,
  p.created_at
FROM mm_players p;

CREATE OR REPLACE VIEW mm_leaderboard AS
SELECT
  ROW_NUMBER() OVER (ORDER BY p.elo DESC) AS `rank`,
  p.steam_id,
  p.name,
  p.elo,
  p.rank_tier,
  p.matches_played,
  CASE
    WHEN p.matches_played > 0
    THEN ROUND(p.matches_won * 100.0 / p.matches_played, 1)
    ELSE 0
  END AS win_rate_pct,
  CASE
    WHEN p.total_deaths > 0
    THEN ROUND(p.total_kills * 1.0 / p.total_deaths, 2)
    ELSE p.total_kills
  END AS kd_ratio
FROM mm_players p
WHERE p.matches_played >= 1
  AND p.is_banned = 0
ORDER BY p.elo DESC;

-- ============================================================
-- IDEMPOTENT MIGRATIONS
-- Safe to re-run on existing databases.
-- New installs: the columns already exist from CREATE TABLE above.
-- ============================================================

-- Add cleanup_attempts to mm_matches (added in v1.1.0)
SET @col_exists = (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME   = 'mm_matches'
    AND COLUMN_NAME  = 'cleanup_attempts'
);
SET @sql = IF(@col_exists = 0,
  'ALTER TABLE mm_matches ADD COLUMN cleanup_attempts TINYINT NOT NULL DEFAULT 0 COMMENT ''Failed cleanup attempts; forced clean at 5'' AFTER cleaned_up',
  'SELECT 1 /* cleanup_attempts already exists */'
);
PREPARE _migration FROM @sql;
EXECUTE _migration;
DEALLOCATE PREPARE _migration;
