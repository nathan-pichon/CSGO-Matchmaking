# Configuration Reference — `config.env`

This document describes all configuration variables available in the `config.env` file.
Copy `config.example.env` to `config.env` and adjust each value to your environment before first startup.

> **Important:** Never commit your `config.env` file to a public repository. It contains secrets (passwords, keys, webhooks).

---

## Table of Contents

1. [Database](#database)
2. [Lobby Server](#lobby-server)
3. [Matchmaking](#matchmaking)
4. [ELO System](#elo-system)
5. [Backends](#backends)
6. [Docker](#docker)
7. [Web Panel](#web-panel)
8. [Discord](#discord)
9. [Levels Ranks (LR)](#levels-ranks-lr)
10. [ELO Ranking System — Tiers](#elo-ranking-system--tiers)

---

## Database

These variables configure the connection to the MariaDB/MySQL database used by all components.

| Variable  | Default Value      | Description |
|-----------|--------------------|-------------|
| `DB_HOST` | `localhost`        | IP address or hostname of the database server. Use `db` if routing through a Docker Compose network. |
| `DB_PORT` | `3306`             | TCP port of the MySQL/MariaDB server. Only change if your instance listens on a non-standard port. |
| `DB_USER` | `csgo_mm`          | MySQL username. Must match the user created during installation. |
| `DB_PASS` | `CHANGE_ME`        | MySQL user password. **Must be changed** before going to production. |
| `DB_NAME` | `csgo_matchmaking` | Database name. The database must exist and the user must have full privileges on it. |

**Notes:**
- In a Docker Compose environment, `DB_HOST` should match the service name (e.g. `db`) rather than `localhost`.
- Ensure that `DB_PORT` is reachable from the lobby server, matchmaker, and web panel.

---

## Lobby Server

These variables control the listen addresses of the SourceMod game server and lobby component.

| Variable        | Default Value | Description |
|-----------------|---------------|-------------|
| `SERVER_IP`     | `0.0.0.0`     | Public IP address or main listen interface of the game server. Use `0.0.0.0` to listen on all interfaces, or specify a precise IP to restrict access. |
| `LOBBY_IP`      | `0.0.0.0`     | Listen address of the CS:GO lobby server. Generally the same as `SERVER_IP`. |
| `LOBBY_PORT`    | `27015`        | UDP/TCP port of the lobby server. This is the port players connect to via `connect IP:27015`. |
| `RCON_PASSWORD` | `CHANGE_ME`   | RCON password for the lobby server. Used by the matchmaker to send remote commands (moving players, messages, etc.). **Must be changed.** |

**Notes:**
- If deploying behind a firewall or NAT, `SERVER_IP` must contain the server's actual public IP.
- The `LOBBY_PORT` must be open for UDP in your firewall.
- A weak `RCON_PASSWORD` exposes your server to malicious takeovers.

---

## Matchmaking

These variables drive the matchmaker's behaviour: check frequency, team composition, and timeouts.

| Variable                        | Default Value | Description |
|---------------------------------|---------------|-------------|
| `POLL_INTERVAL`                 | `2.0`         | Interval in seconds between each queue check cycle by the matchmaker. A lower value reduces match formation latency but increases database load. Recommended: `1.0` to `5.0`. |
| `PLAYERS_PER_TEAM`              | `5`           | Number of players per team. Standard CS:GO value: `5`. For test modes or custom games, you can reduce to `1` or `2`. |
| `MAX_ELO_SPREAD`                | `200`         | Maximum ELO difference allowed between players at initial match formation. A lower spread guarantees more balanced matches but increases wait times. |
| `ELO_SPREAD_INCREASE_INTERVAL`  | `60`          | Time in seconds after which the ELO spread tolerance is widened if no match could be formed. Reduces wait times when the player population is low. |
| `ELO_SPREAD_INCREASE_AMOUNT`    | `50`          | ELO value added to the spread tolerance at each interval defined by `ELO_SPREAD_INCREASE_INTERVAL`. |
| `READY_CHECK_TIMEOUT`           | `30`          | Time in seconds given to players to accept or decline a match during the ready check phase. Players who do not respond within this window receive a temporary ban. |
| `WARMUP_TIMEOUT`                | `180`         | Maximum duration in seconds of the warmup phase on the match server, waiting for all players to connect. After this, the match is cancelled and players are sent back to the lobby. |
| `MIN_PLACEMENT_MATCHES`         | `10`          | Number of mandatory placement matches before a player is considered "ranked". During this period, the ELO K-factor is higher (`ELO_K_FACTOR_NEW`). |

**Notes:**
- `PLAYERS_PER_TEAM` changes the total number of players required to start a match: `PLAYERS_PER_TEAM × 2`.
- The progressive widening algorithm (`ELO_SPREAD_INCREASE_INTERVAL` + `ELO_SPREAD_INCREASE_AMOUNT`) applies individually to each queued player based on their personal wait time.

---

## ELO System

These variables configure the ELO calculation engine used for point gains and losses after each match.

| Variable           | Default Value | Description |
|--------------------|---------------|-------------|
| `ELO_K_FACTOR`     | `32`          | Standard K-factor applied to players who have completed their placement period (≥ `MIN_PLACEMENT_MATCHES` matches). Determines the maximum ELO change per match. |
| `ELO_K_FACTOR_NEW` | `64`          | K-factor used during the placement period (< `MIN_PLACEMENT_MATCHES` matches). Higher value allows rapid positioning in the rankings. |
| `ELO_DEFAULT`      | `1000`        | ELO score assigned to any new player with no existing score. Corresponds to the Master Guardian I rank. |

**Notes:**
- A higher K-factor means larger ELO gains and losses per match.
- A K-factor of `32` corresponds to the classic value used in chess for established players.
- A third tier (e.g. K=24 for veteran players with more than 30 matches) can be implemented directly in the matchmaker code.

---

## Backends

These variables select the modular implementations used for each subsystem. Each backend corresponds to a swappable driver.

| Variable                | Default Value | Possible Values              | Description |
|-------------------------|---------------|------------------------------|-------------|
| `QUEUE_BACKEND`         | `mysql`       | `mysql`                      | Queue management driver. Currently only `mysql` is supported. |
| `SERVER_BACKEND`        | `docker`      | `docker`                     | Match server provisioning driver. `docker` launches one container per match. |
| `NOTIFICATION_BACKEND`  | `discord`     | `discord`, `none`            | External notification driver. `discord` sends messages via webhook. `none` disables notifications. |
| `RANKING_BACKEND`       | `elo`         | `elo`                        | Ranking algorithm used for score calculation. Currently only `elo` is supported. |

---

## Docker

These variables control the behaviour of the Docker backend, responsible for launching match server containers.

| Variable         | Default Value              | Description |
|------------------|----------------------------|-------------|
| `DOCKER_IMAGE`   | `csgo-match-server:latest` | Name and tag of the Docker image used to launch each match server. The image must be built or available locally before the matchmaker's first startup. |
| `DOCKER_NETWORK` | `host`                     | Docker network to which match containers are attached. `host` gives direct access to the host's network interfaces, which is recommended for game servers (optimal network performance). Use a named network if you want to isolate containers. |

**Notes:**
- `host` network mode is only available on Linux. On macOS or Windows, use a named Docker network.
- Ensure the Docker daemon is accessible by the matchmaker process (membership in the `docker` group or root access).

---

## Web Panel

These variables configure the HTTP server for the admin and statistics panel.

| Variable     | Default Value | Description |
|--------------|---------------|-------------|
| `WEB_HOST`   | `0.0.0.0`     | Listen interface of the Flask web server. `0.0.0.0` exposes the panel on all interfaces. Specify `127.0.0.1` to restrict to local access (recommended if a reverse proxy is used). |
| `WEB_PORT`   | `5000`        | TCP port on which the web panel is accessible. Default: `http://IP:5000`. |
| `SECRET_KEY` | `CHANGE_ME`   | Flask secret key used to sign session cookies. **Must be a long, unique random string in production.** Generate one with: `python3 -c "import secrets; print(secrets.token_hex(32))"` |

**Notes:**
- In production, place the web panel behind a reverse proxy (nginx, Caddy) with HTTPS.
- Never leave `SECRET_KEY` at its default `CHANGE_ME` value in production.

---

## Discord

| Variable              | Default Value | Description |
|-----------------------|---------------|-------------|
| `DISCORD_WEBHOOK_URL` | *(empty)*     | Discord webhook URL to which match notifications (match start, result, errors) are sent. Leave empty to disable, or set `NOTIFICATION_BACKEND=none`. |

**Notes:**
- To create a webhook: Discord channel settings → Integrations → Webhooks → New Webhook.
- The webhook receives a message at each match start and end, as well as on critical matchmaker errors.

---

## Levels Ranks (LR)

| Variable        | Default Value | Description |
|-----------------|---------------|-------------|
| `LR_TABLE_NAME` | `lvl_base`    | Name of the MySQL table used by the Levels Ranks SourceMod plugin. Only change this if your LR installation uses a custom table name. |

---

## ELO Ranking System — Tiers

The ranking is divided into **18 tiers** inspired by the CS:GO rank system. The displayed tier is automatically determined from the player's current ELO score.

| Tier | Rank                          | ELO Range   |
|------|-------------------------------|-------------|
| 1    | Silver I                      | 0 – 99      |
| 2    | Silver II                     | 100 – 199   |
| 3    | Silver III                    | 200 – 299   |
| 4    | Silver IV                     | 300 – 399   |
| 5    | Silver Elite                  | 400 – 499   |
| 6    | Silver Elite Master           | 500 – 599   |
| 7    | Gold Nova I                   | 600 – 699   |
| 8    | Gold Nova II                  | 700 – 799   |
| 9    | Gold Nova III                 | 800 – 899   |
| 10   | Gold Nova Master              | 900 – 999   |
| 11   | Master Guardian I             | 1000 – 1099 |
| 12   | Master Guardian II            | 1100 – 1199 |
| 13   | Master Guardian Elite         | 1200 – 1299 |
| 14   | Distinguished Master Guardian | 1300 – 1499 |
| 15   | Legendary Eagle               | 1500 – 1699 |
| 16   | Legendary Eagle Master        | 1700 – 1899 |
| 17   | Supreme Master First Class    | 1900 – 2099 |
| 18   | Global Elite                  | 2100+       |

**How ELO is calculated:**

After each match, the ELO gain or loss is computed using the classic ELO formula:

```
New_ELO = Old_ELO + K × (Actual_Score - Expected_Score)
```

- `Actual_Score` is `1` for a win, `0` for a loss.
- `Expected_Score` is calculated from the two teams' respective ELOs (averaged).
- `K` equals `ELO_K_FACTOR_NEW` (64) during placement matches, and `ELO_K_FACTOR` (32) thereafter.

**Example:**

A player at 1050 ELO (Master Guardian I) faces a team averaging 1200 ELO.
- Expected score ≈ 0.32 (the opposing team is favoured)
- On **win**: approximately +22 ELO → 1072
- On **loss**: approximately -10 ELO → 1040

The **Distinguished Master Guardian** (1300–1499) tiers and above have wider ranges, making progression harder and rewarding consistency.
