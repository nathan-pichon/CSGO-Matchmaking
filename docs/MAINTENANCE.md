# Maintenance Guide — CS:GO Matchmaking

This document covers routine maintenance, monitoring, and administration operations for the CS:GO Matchmaking system.

---

## Table of Contents

1. [Service Management](#1-service-management)
2. [Match Container Monitoring](#2-match-container-monitoring)
3. [Health Check](#3-health-check)
4. [Backup and Restore](#4-backup-and-restore)
5. [Updates](#5-updates)
6. [GSLT Token Management](#6-gslt-token-management)
7. [Port Pool Management](#7-port-pool-management)
8. [Database Administration](#8-database-administration)
9. [Season Management](#9-season-management)
10. [Logs and Debugging](#10-logs-and-debugging)

---

## 1. Service Management

Systemd services are configured to start automatically on boot (enabled by `install.sh`, with `Restart=always`). Any unexpected interruption triggers an automatic restart of the affected service.

### Start All Services

```bash
sudo systemctl start csgo-lobby csgo-matchmaker csgo-webpanel
```

### Stop All Services

```bash
sudo systemctl stop csgo-lobby csgo-matchmaker csgo-webpanel
```

### Restart a Specific Service

```bash
sudo systemctl restart csgo-matchmaker
```

> Replace `csgo-matchmaker` with `csgo-lobby` or `csgo-webpanel` as needed.

### Check Service Status

```bash
sudo systemctl status csgo-matchmaker
```

### View Live Logs

```bash
sudo journalctl -u csgo-matchmaker -f
```

### View Recent Logs

```bash
sudo journalctl -u csgo-matchmaker --since "1 hour ago"
```

---

## 2. Match Container Monitoring

Each active match runs in a dedicated Docker container, named according to the scheme `csgo-match-<ID>`.

### List Active Containers

```bash
docker ps --filter "name=csgo-match-"
```

### Display Container Logs

```bash
docker logs csgo-match-<ID>
```

### List All Match Containers (Including Stopped)

```bash
docker ps -a --filter "name=csgo-match-"
```

### Stop a Stuck Container

```bash
docker stop csgo-match-<ID>
```

> Replace `<ID>` with the match identifier (visible in the `NAMES` column of `docker ps`).

---

## 3. Health Check

The `health_check.sh` script performs a comprehensive 10-point check of the system's state.

### Full Check

```bash
./scripts/health_check.sh
```

Points checked:
- MySQL connection
- Docker daemon
- Matchmaker service
- Lobby service
- Web panel service
- Available disk space
- GSLT token pool
- Port pool
- Stale matches (stuck)

### JSON Output (for Prometheus / Grafana)

```bash
./scripts/health_check.sh --json
```

---

## 4. Backup and Restore

### Manual Backup

```bash
./scripts/backup.sh
```

Generates a timestamped MySQL dump in the `./backups/` directory. The 30 most recent backups are kept; older ones are automatically deleted.

### Interactive Restore

```bash
./scripts/restore.sh
```

The script is interactive: it stops the matchmaker, restores the selected database backup, then restarts the service.

### Automatic Backup via Cron

Add the following line to the crontab (`crontab -e`) to trigger a nightly backup at 3:00 AM:

```
0 3 * * * /path/to/CSGO-Matchmaking/scripts/backup.sh
```

> Replace `/path/to/CSGO-Matchmaking` with the absolute path to the project on your server.

---

## 5. Updates

### Update Code and Reinstall

```bash
git pull && sudo ./install.sh --update
```

### Update Only CS:GO Game Files

```bash
./scripts/update_server.sh
```

### Rebuild Docker Image After Modifying Match-Server

```bash
docker build -t csgo-match-server:latest -f match-server/Dockerfile match-server/
```

### Redeploy Docker Services

```bash
docker compose up -d --build matchmaker webpanel
```

---

## 6. GSLT Token Management

GSLT (Game Server Login Token) tokens are required to host official CS:GO servers. They are managed via the `mm_gslt_tokens` table.

### Check Pool Status

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "SELECT * FROM mm_gslt_tokens;"
```

### Add a New Token

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "INSERT INTO mm_gslt_tokens (token) VALUES ('TOKEN');"
```

> Replace `TOKEN` with the GSLT obtained from [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers) (AppID 730).

### Expired Token

1. Regenerate the token at [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers) (AppID 730).
2. Update the token in the database.

### Release a Stuck Token

If a token is marked `in_use` but no corresponding container exists:

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "UPDATE mm_gslt_tokens SET in_use=0, assigned_match_id=NULL WHERE token='TOKEN';"
```

---

## 7. Port Pool Management

Each match server uses a dedicated UDP port. The pool is managed in the `mm_server_ports` table.

### Check Pool Status

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "SELECT * FROM mm_server_ports;"
```

### Release a Stuck Port

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "UPDATE mm_server_ports SET in_use=0 WHERE port=27020;"
```

### Add Additional Ports

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "INSERT INTO mm_server_ports (port, tv_port) VALUES (27030, 27130);"
```

---

## 8. Database Administration

### Connect to the Database

```bash
mysql -u csgo_mm -p csgo_matchmaking
```

### Useful Queries

**Queue status:**

```sql
SELECT status, COUNT(*) FROM mm_queue GROUP BY status;
```

**Active matches:**

```sql
SELECT id, map_name, status, server_ip, server_port
FROM mm_matches
WHERE status IN ('creating', 'warmup', 'live');
```

**Top player rankings:**

```sql
SELECT name, elo, rank_tier, matches_played
FROM mm_players
ORDER BY elo DESC
LIMIT 10;
```

**Active bans:**

```sql
SELECT steam_id, reason, expires_at
FROM mm_bans
WHERE is_active = 1;
```

**Clean up old queue entries:**

```sql
DELETE FROM mm_queue
WHERE status IN ('matched', 'expired', 'cancelled')
  AND queued_at < DATE_SUB(NOW(), INTERVAL 7 DAY);
```

---

## 9. Season Management

### Start a New Season (Partial ELO Reset)

The following script closes the current season, creates a new one, and applies a progressive ELO reset (average between current ELO and 1000) before recalculating ranks.

```sql
-- Close the current season
UPDATE mm_seasons SET is_active = 0 WHERE is_active = 1;

-- Create the new season
INSERT INTO mm_seasons (name, started_at, is_active) VALUES ('Season 2', NOW(), 1);

-- Partial ELO reset (average between current ELO and 1000)
UPDATE mm_players SET elo = FLOOR((elo + 1000) / 2);

-- Recalculate ranks based on new ELO
UPDATE mm_players SET rank_tier = CASE
    WHEN elo >= 2100 THEN 17
    WHEN elo >= 1900 THEN 16
    WHEN elo >= 1700 THEN 15
    WHEN elo >= 1500 THEN 14
    WHEN elo >= 1300 THEN 13
    WHEN elo >= 1200 THEN 12
    WHEN elo >= 1100 THEN 11
    WHEN elo >= 1000 THEN 10
    WHEN elo >= 900  THEN 9
    WHEN elo >= 800  THEN 8
    WHEN elo >= 700  THEN 7
    WHEN elo >= 600  THEN 6
    WHEN elo >= 500  THEN 5
    WHEN elo >= 400  THEN 4
    WHEN elo >= 300  THEN 3
    WHEN elo >= 200  THEN 2
    WHEN elo >= 100  THEN 1
    ELSE 0
END;
```

> It is recommended to perform this operation during a low-activity period and to take a backup first via `./scripts/backup.sh`.

---

## 10. Logs and Debugging

### Filter Matchmaker Errors (Last 24 Hours)

```bash
sudo journalctl -u csgo-matchmaker --since "1 day ago" | grep ERROR
```

### Check Firewall Status

```bash
sudo ufw status
```

or, with iptables:

```bash
sudo iptables -L
```

### Check That a Port Is Listening

```bash
ss -ulnp | grep 27015
```

### Identify Slow or Blocked MySQL Queries

```bash
mysql -u root -p -e "SHOW PROCESSLIST;"
```

---

*Documentation generated on 2026-03-05. Update this document whenever infrastructure changes are made.*
