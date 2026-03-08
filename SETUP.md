# CS:GO Matchmaking — Setup Guide

This guide walks you through installing and configuring the full CS:GO Matchmaking stack from scratch, then explains how to use the web panel and admin interface day-to-day.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Installation](#2-installation)
3. [What the Installer Does](#3-what-the-installer-does)
4. [Post-Install Configuration](#4-post-install-configuration)
5. [Starting & Stopping Services](#5-starting--stopping-services)
6. [Web Panel](#6-web-panel)
7. [Admin Panel](#7-admin-panel)
8. [In-Game Commands](#8-in-game-commands)
9. [Configuration Reference](#9-configuration-reference)
10. [Updating](#10-updating)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Prerequisites

### Server

| Requirement | Minimum |
|---|---|
| OS | Ubuntu 22.04 LTS / Debian 12 / RHEL 9 |
| CPU | 4 cores (2 GHz+) |
| RAM | 8 GB |
| Disk | 30 GB free (CS:GO ~15 GB) |
| Network | 100 Mbps, public IPv4 |

> **macOS** is supported for local development only (Docker + launchd instead of systemd).

### Accounts & Tokens

Before running the installer you need:

- **Steam Game Server Login Tokens (GSLTs)** — one for the lobby server, one per match server slot.
  Generate them at: <https://steamcommunity.com/dev/managegameservers> (App ID `730`).

- **Your Steam ID** in legacy format (`STEAM_0:X:Y`) — needed to seed the first super-admin.
  Find it at <https://steamid.io> by entering your Steam profile URL.

- **(Optional) Discord Webhook URL** — for match notifications.
  Create one under your Discord server → *Settings → Integrations → Webhooks*.

---

## 2. Installation

Clone the repository and run the installer as root:

```bash
git clone https://github.com/yourorg/csgo-matchmaking.git
cd csgo-matchmaking
sudo ./install.sh
```

The wizard guides you through a 9-step interview. Press **Enter** to accept any default shown in brackets.

| Step | What it asks |
|---|---|
| 1 | Public server IP (auto-detected) |
| 2 | Database name, user, and password |
| 3 | RCON password |
| 4 | GSLT tokens for match servers (one per slot) |
| 5 | GSLT token for the lobby server |
| 6 | Lobby port and match server port range |
| 7 | Web panel port and your super-admin Steam ID |
| 8 | Map pool selection |
| 9 | ELO spread, ready-check timeout, matchmaking tuning |

After answering all prompts, the installer runs unattended — expect 10–20 minutes depending on download speed.

### Other install modes

```bash
sudo ./install.sh --update   # Update an existing installation (preserves config.env)
sudo ./install.sh --check    # System requirements check only, no changes made
```

---

## 3. What the Installer Does

The installer runs these steps automatically:

1. **Packages** — installs Docker, MySQL/MariaDB, SteamCMD, Python 3.10+, and build tools via the system package manager (`apt` / `dnf` / `pacman` / `brew`).
2. **Config wizard** — collects answers and writes `config.env`.
3. **Config generation** — generates `SECRET_KEY` and `ADMIN_TOKEN` with `openssl rand -hex 24`, seeds `config.env`.
4. **Database** — creates the MySQL database, user, and imports `database/schema.sql`.
5. **CS:GO download** — uses SteamCMD to download the CS:GO dedicated server files.
6. **SourceMod** — installs MetaMod:Source and SourceMod, copies all `.sp` plugins and `.cfg` files to the lobby server.
7. **Docker** — builds the `csgo-match-server:latest` image used for per-match containers.
8. **Python** — creates two virtual environments (`matchmaker/` and `web-panel/`) and installs dependencies.
9. **Services** — writes and enables three systemd units:
   - `csgo-lobby` — the persistent lobby CS:GO server
   - `csgo-matchmaker` — the Python matchmaking daemon
   - `csgo-webpanel` — the Flask web panel (via gunicorn)

---

## 4. Post-Install Configuration

### Set the super-admin Steam ID

The web panel admin system authenticates through Steam. Before starting the services for the first time, make sure `SUPER_ADMIN_STEAM_ID` is set in `config.env`:

```env
# config.env
SUPER_ADMIN_STEAM_ID=STEAM_0:1:12345678
```

> The installer wizard asks for this in step 7. If you skipped it, edit `config.env` manually and restart the `csgo-webpanel` service — the super-admin is seeded automatically on startup (idempotent).

### Add more admins

Additional admins are managed through the web panel at `/admin/admins` (requires the `superadmin` role). See [Admin Panel → Admin Management](#admin-management).

### Discord notifications (optional)

Paste your webhook URL into `config.env` and restart the matchmaker:

```env
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
```

```bash
sudo systemctl restart csgo-matchmaker
```

---

## 5. Starting & Stopping Services

All three services are managed by systemd and start automatically on boot.

```bash
# Status
sudo systemctl status csgo-lobby
sudo systemctl status csgo-matchmaker
sudo systemctl status csgo-webpanel

# Start / stop / restart
sudo systemctl start   csgo-matchmaker
sudo systemctl stop    csgo-matchmaker
sudo systemctl restart csgo-webpanel

# Live logs
sudo journalctl -fu csgo-matchmaker   # follow matchmaker logs
sudo journalctl -fu csgo-lobby        # follow lobby server logs
sudo journalctl -fu csgo-webpanel     # follow web panel logs
```

---

## 6. Web Panel

The web panel is available at `http://<SERVER_IP>:<WEB_PORT>` (default port `5000`).

### Public pages (no login required)

| URL | Description |
|---|---|
| `/` | Landing page — live stats, top players, recent matches. Redirects to dashboard when signed in. |
| `/leaderboard` | Full ELO leaderboard, paginated, filterable by season. |
| `/matches` | List of all completed matches. |
| `/match/<id>` | Full CS:GO-style scoreboard for a single match. |
| `/player/<steam_id>` | Player profile — ELO history graph, full stats, match history. |

### Signing in

Click **Login** in the top-right corner of any page. You will be redirected to Steam's official login page. After authenticating with Steam, you are returned to your personal dashboard.

> No account creation is needed — your identity comes entirely from your Steam account.

### Player dashboard

After signing in, `/dashboard` shows:
- Your current rank badge and ELO rating
- Win rate, K/D ratio, and total matches played
- Win / Loss / Tie record with a colour-split progress bar
- ELO trend sparkline (last 20 data points)
- Your 10 most recent matches with results and ELO changes

---

## 7. Admin Panel

### Gaining access

Admin access is controlled by the `mm_admins` database table. Only players whose Steam ID appears in this table can access `/admin/`. There are three roles:

| Role | Permissions |
|---|---|
| `moderator` | View dashboard, manage bans, dismiss reports |
| `admin` | All moderator actions + override player ELO |
| `superadmin` | All admin actions + manage admins, start seasons |

The first super-admin is seeded from `SUPER_ADMIN_STEAM_ID` in `config.env` at startup.

### Logging in as an admin

1. Sign into the web panel with your Steam account (click **Login** in the navbar).
2. If your Steam ID is registered in `mm_admins`, an **⚙ Admin** button appears in the top-right corner of every page.
3. Click **⚙ Admin** to enter the administration board.

> If you see the public panel but no Admin button, your Steam ID is not yet registered. Have an existing superadmin add you, or set `SUPER_ADMIN_STEAM_ID` and restart the web panel.

### Admin dashboard (`/admin/`)

Shows live server stats:
- Active matches currently in progress
- Players currently in the matchmaking queue
- Active bans (count of players currently banned)

### Ban management (`/admin/bans`)

- **View** all active bans with player name, reason, and expiry date.
- **Ban a player** by Steam ID, with a reason and duration in minutes (`0` = permanent).
- **Unban a player** immediately.

### ELO override (`/admin/setelo`) — `admin` role

Manually set a player's ELO rating. Use for correcting obvious placement errors or testing.

### Report review (`/admin/reports`) — `moderator` role

Shows players with 3 or more unique reporters in the last 30 days, sorted by report count. Dismiss reports after reviewing.

### Admin management (`/admin/admins`) — `superadmin` role

Add, remove, and change the role of admin users. You cannot modify your own account from this page.

| Field | Description |
|---|---|
| Steam ID | The player's legacy Steam ID (`STEAM_0:X:Y`) |
| Role | `moderator`, `admin`, or `superadmin` |
| Notes | Internal notes (visible to other superadmins) |

### Season management (`/admin/seasons`) — `superadmin` role

Start a new competitive season, which:
1. Closes the current season (sets its end date to today).
2. Creates a new season record.
3. Applies a **soft ELO reset** to all players: `new_elo = reset_to + (old_elo - reset_to) / 2` (only for players above the reset floor).
4. Logs all ELO changes with `change_reason = 'season_reset'` for audit purposes.

> The default reset floor is **1000 ELO**. Players below the floor keep their current ELO.

---

## 8. In-Game Commands

Players type these commands in the in-game chat while connected to the **lobby server**.

### Queue

| Command | Description |
|---|---|
| `!queue` / `!q` | Join the matchmaking queue |
| `!leave` | Leave the queue |
| `!status` | Show your queue position and estimated wait time |

### Stats

| Command | Description |
|---|---|
| `!rank` | Show your current ELO rating and rank badge |
| `!top` | Top 10 players by ELO |
| `!stats` | Your full stats (K/D, win rate, matches played) |
| `!lastmatch` | Summary of your most recent match |
| `!recent` | Players from your last 5 matches |

### Social

| Command | Description |
|---|---|
| `!party` | Create or manage a party |
| `!invite <name>` | Invite a player to your party |
| `!avoid <name>` | Avoid a player for 7 days (max 10 active avoids) |
| `!avoidlist` | List your current avoid list |

### In-match commands (on the **match server**)

| Command | Description |
|---|---|
| `!ff` / `!surrender` | Start a surrender vote (needs 4/5 of your team; 2 min cooldown) |
| `!pause` | Request a tactical timeout (1 per team per match) |
| `!unpause` | Signal you are ready to resume |
| `!report <name>` | Report a player for misconduct |

---

## 9. Configuration Reference

All settings live in `config.env` at the project root. After editing, restart the relevant service(s).

```env
# ── Database ──────────────────────────────────────────────────────────────────
DB_HOST=localhost        # MySQL host
DB_PORT=3306             # MySQL port
DB_USER=csgo_mm          # Database user
DB_PASS=CHANGE_ME        # Database password
DB_NAME=csgo_matchmaking # Database name

# ── Networking ────────────────────────────────────────────────────────────────
SERVER_IP=0.0.0.0        # Public IP (auto-detected by installer)
LOBBY_IP=0.0.0.0         # Lobby server bind address
LOBBY_PORT=27015         # Lobby server port
RCON_PASSWORD=CHANGE_ME  # RCON password for match server control

# ── Matchmaking ───────────────────────────────────────────────────────────────
POLL_INTERVAL=2.0             # Seconds between matchmaker queue polls
PLAYERS_PER_TEAM=5            # Players per side (5 = 5v5)
MAX_ELO_SPREAD=200            # Initial max ELO gap allowed in a match
ELO_SPREAD_INCREASE_INTERVAL=60   # Seconds before spread widens
ELO_SPREAD_INCREASE_AMOUNT=50     # How much spread widens each interval
READY_CHECK_TIMEOUT=30        # Seconds to accept/decline a match
WARMUP_TIMEOUT=180            # Seconds before match is cancelled if players don't connect
MIN_PLACEMENT_MATCHES=10      # Matches before ELO stabilises (placement period)

# ── ELO ───────────────────────────────────────────────────────────────────────
ELO_DEFAULT=1000         # Starting ELO for new players
ELO_K_FACTOR=32          # ELO volatility for established players
ELO_K_FACTOR_NEW=64      # ELO volatility during placement matches

# ── Web Panel ─────────────────────────────────────────────────────────────────
WEB_HOST=0.0.0.0         # Bind address for gunicorn
WEB_PORT=5000            # HTTP port for the web panel
SECRET_KEY=CHANGE_ME     # Flask session secret (generated by installer)
ADMIN_TOKEN=CHANGE_ME    # Bearer token for API/curl admin access
SUPER_ADMIN_STEAM_ID=    # STEAM_0:X:Y of the first super-admin

# ── Notifications ─────────────────────────────────────────────────────────────
NOTIFICATION_BACKEND=discord        # discord | slack | none
DISCORD_WEBHOOK_URL=                # Leave empty to disable

# ── Docker ────────────────────────────────────────────────────────────────────
DOCKER_IMAGE=csgo-match-server:latest
DOCKER_NETWORK=host
```

---

## 10. Updating

```bash
git pull
sudo ./install.sh --update
```

The `--update` flag re-runs all install steps while preserving your existing `config.env` values. The database step runs idempotent `ALTER TABLE IF NOT EXISTS` / `CREATE TABLE IF NOT EXISTS` blocks — no data is lost.

After updating, restart all services:

```bash
sudo systemctl restart csgo-lobby csgo-matchmaker csgo-webpanel
```

---

## 11. Troubleshooting

### Web panel shows "Login" but admin button doesn't appear after signing in

Your Steam ID is not registered in `mm_admins`. Check:

```bash
# Find your Steam ID
# Visit https://steamid.io and paste your Steam profile URL

# Verify it is in the database
mysql -u csgo_mm -p csgo_matchmaking \
  -e "SELECT steam_id, role FROM mm_admins;"

# If not present, add it manually (or set SUPER_ADMIN_STEAM_ID and restart)
mysql -u csgo_mm -p csgo_matchmaking \
  -e "INSERT INTO mm_admins (steam_id, role, added_by) VALUES ('STEAM_0:X:Y', 'superadmin', NULL);"

sudo systemctl restart csgo-webpanel
```

### Steam callback returns an error

The Steam OpenID callback URL must be publicly reachable. If you are running behind a reverse proxy (nginx/Caddy), make sure:
- `X-Forwarded-Proto` is set to `https` if using TLS
- The `WEB_HOST` in `config.env` is set to your public domain (not `0.0.0.0`) so that the Discord rank-up notification links work correctly

For local development, Steam OpenID requires a publicly reachable URL — use a tool like [ngrok](https://ngrok.com) to tunnel your local port.

### Matchmaker not creating matches

```bash
sudo journalctl -fu csgo-matchmaker --since "5 minutes ago"
```

Common causes:
- Database connection failure — check `DB_HOST`, `DB_USER`, `DB_PASS`
- No GSLT tokens in `mm_gslt_tokens` — the installer populates this; add tokens manually if needed
- No ports available in `mm_server_ports` — all match slots are in use

### Lobby server not starting

```bash
sudo systemctl status csgo-lobby
sudo journalctl -u csgo-lobby --since "10 minutes ago"
```

Common causes:
- Invalid `LOBBY_GSLT` — regenerate at <https://steamcommunity.com/dev/managegameservers>
- Port `27015` already in use — change `LOBBY_PORT` in `config.env`
- CS:GO files corrupted — re-run `sudo ./install.sh --update`

### Players can't connect to match servers

- Verify `SERVER_IP` in `config.env` is your public IP, not `0.0.0.0`
- Check that match server ports (`27020`–`27039` by default) are open in your firewall:
  ```bash
  sudo ufw allow 27015:27040/udp
  sudo ufw allow 27015:27040/tcp
  sudo ufw allow 5000/tcp   # web panel
  ```
- Check Docker is running: `sudo systemctl status docker`

### Check the install log

The installer writes a full log to `/var/log/csgo-mm-install.log`. Review it for any step that failed:

```bash
sudo tail -100 /var/log/csgo-mm-install.log
```
