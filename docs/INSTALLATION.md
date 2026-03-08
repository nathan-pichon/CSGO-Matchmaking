# Installation Guide

This guide covers the complete installation of the CS:GO Legacy Matchmaking system from scratch, up to a fully operational server ready to accept players.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Obtaining GSLT Tokens](#2-obtaining-gslt-tokens)
3. [Automated Installation (Recommended)](#3-automated-installation-recommended)
4. [Post-Installation Verification](#4-post-installation-verification)
5. [First Tests](#5-first-tests)
6. [Troubleshooting](#6-troubleshooting)

---

## 1. Prerequisites

### Minimum Hardware

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB | 8 GB+ |
| CPU | 2 cores | 4 cores |
| Disk | 50 GB | 100 GB |
| OS | Linux 64-bit | Ubuntu 22.04 LTS |
| Network | 100 Mbit/s | 1 Gbit/s dedicated |

> **Tip**: CS:GO alone takes up ~25 GB. Each active match server consumes an additional ~500 MB RAM and ~200 MB disk.

### Supported Distributions

- **Ubuntu** 20.04, 22.04, 24.04 (LTS, recommended)
- **Debian** 11 (Bullseye), 12 (Bookworm)
- **CentOS** 7, Stream 8/9
- **Rocky Linux / AlmaLinux** 8, 9
- **Fedora** 36+
- **Arch Linux** (rolling)

### Required Steam Account

- A Steam account **with CS:GO** (required to obtain GSLTs)
- Internet access during installation (downloads ~25 GB)
- `root` or `sudo` access on the server

---

## 2. Obtaining GSLT Tokens

**Game Server Login Tokens (GSLT)** are mandatory to run CS:GO servers visible on the internet. Each server instance (lobby + each match server) requires a unique token.

> **Important**: The AppID for CS:GO Legacy is **730**. Using the wrong AppID will invalidate the tokens.

### Procedure

1. Go to [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers)
2. Sign in with your Steam account
3. In the **App ID** field, enter: `730`
4. In **Memo**, enter a descriptive name (e.g. `csgo-lobby`, `csgo-match-01`)
5. Click **Create**
6. Copy the generated token (format: `XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX`, 32 characters)
7. **Repeat** for each server:
   - 1 token for the lobby server
   - 1 token per match slot (the system supports 10 simultaneous matches by default, so 10 tokens)

**Recommended total: 11 tokens** (1 lobby + 10 matches)

> **Note**: A Steam account can create up to 1000 tokens. Expired or revoked tokens can be regenerated from the same page.

### Validating a Token

A valid token looks like: `A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4`

The installer will automatically validate the format of each token entered.

---

## 3. Automated Installation (Recommended)

### Step 1: Clone the Repository

```bash
git clone https://github.com/nathan-pichon/CSGO-Matchmaking.git
cd CSGO-Matchmaking
```

### Step 2: Run the Wizard

```bash
chmod +x install.sh
sudo ./install.sh
```

> **Estimated duration**: 30 to 60 minutes (depends on connection speed for the ~25 GB CS:GO download)

### What the Wizard Does

The wizard is interactive and guides you through each step:

#### Environment Detection
- Automatically identifies your Linux distribution and package manager
- Checks that system resources are sufficient (RAM, CPU, disk)
- Detects your server's public IP address (with the option to confirm or correct it)

#### Dependency Installation
Automatically installs based on your distro:
- **Docker CE** and **docker-compose** (or Docker Compose V2)
- **MySQL 8.0** or **MariaDB**
- **Python 3.10+** and `pip`
- **SteamCMD** (Steam command-line client)
- Required system tools (curl, wget, git, etc.)

#### Interactive Configuration

The wizard walks through **9 steps**. Press Enter to accept any default shown in brackets.

| Step | What it asks | Default |
|------|-------------|---------|
| 1 | Public server IP | Auto-detected |
| 2 | Database name, user, and password | Randomly generated password |
| 3 | RCON password | Randomly generated |
| 4 | GSLT tokens for match servers (one per slot, up to 10) | — |
| 5 | GSLT token for the lobby server | — |
| 6 | Lobby port and match server port range | `27015`, `27020–27029` |
| 7 | Web panel port and your super-admin Steam ID | `5000`, — |
| 8 | Map pool selection | All 7 default maps |
| 9 | ELO spread, ready-check timeout, matchmaking tuning | See `config.env` defaults |

> **Super-admin Steam ID**: enter your SteamID64 (17 digits, from [steamid.io](https://steamid.io)) or the legacy `STEAM_0:X:Y` format. The wizard converts automatically. This is the account that gains admin access when you first sign in through Steam.

#### Downloads and Installation
- Downloads CS:GO Legacy via SteamCMD (~25 GB)
- Downloads and installs SourceMod + MetaMod:Source
- Installs additional plugins: **Levels Ranks** and **ServerRedirect** (GAMMACASE)
- Copies compiled lobby plugins (`.smx`) from the repository to SourceMod folders
- Compiles match-server plugins (`.sp` → `.smx`) using the installed `spcomp` binary
- Configures `databases.cfg` files for MySQL connection

#### Database
- Creates the `csgo_matchmaking` database
- Creates the `csgo_mm` MySQL user with appropriate permissions
- Applies the complete schema (`database/schema.sql`) — idempotent, can be re-run
- Seeds initial data: Season 1, map pool, port pool (27020–27029)

#### Config File Generation
- Generates `config.env` with all your values
- Generates SourceMod config files (`databases.cfg`, `csgo_matchmaking.cfg`)

#### Docker Build
- Builds the Docker image for match servers: `csgo-match-server:latest`
- Verifies the image is accessible

#### Systemd Services
Creates, enables, and **immediately starts** 3 services:

```
csgo-lobby.service      # CS:GO lobby server (srcds) — started only if CS:GO files are present
csgo-matchmaker.service # Python matchmaking daemon
csgo-webpanel.service   # Flask web interface
```

All three services are configured with `Restart=always` — they restart automatically on crash and at boot.

#### Firewall
Opens the required ports automatically using the first available tool in priority order: `ufw` → `firewalld` → `iptables`. Rules are idempotent — safe to re-run.

#### Final Validation
Automatically tests:
- MySQL connection
- Docker API access
- Port availability
- Service startup

### Re-running the Wizard (Update)

```bash
sudo ./install.sh --update
```

The `--update` mode re-runs only the necessary steps without overwriting your existing `config.env`.

---

## 4. Post-Installation Verification

### Check Services

```bash
# Status of all services
sudo systemctl status csgo-lobby csgo-matchmaker csgo-webpanel

# View live logs
sudo journalctl -u csgo-matchmaker -f
sudo journalctl -u csgo-lobby -f
sudo journalctl -u csgo-webpanel -f
```

### Check the Database

```bash
mysql -u csgo_mm -p csgo_matchmaking

# In MySQL:
SHOW TABLES;
SELECT * FROM mm_seasons;
SELECT * FROM mm_server_ports;
SELECT COUNT(*) FROM mm_gslt_tokens;
```

### Check Docker

```bash
# The image should be present
docker images | grep csgo-match-server

# No match containers should be running yet
docker ps --filter "name=csgo-match-"
```

### Check Open Ports

```bash
# Verify that ports are listening
ss -ulnp | grep 27015   # Lobby UDP
ss -tlnp | grep 5000    # Web panel TCP

# Check firewall (UFW)
sudo ufw status
```

### Full Health Check Script

```bash
./scripts/health_check.sh
```

This script checks 10 critical points and displays a colour-coded report. All indicators must be green before inviting players.

---

## 5. First Tests

### 1. Connect to the Lobby Server

From CS:GO Legacy (console, `~` key):
```
connect YOUR_IP:27015
```

You should see the server load and the plugin's welcome message appear in chat.

### 2. Test Basic Commands

In the lobby server chat:
```
!rank          # Should display your rank (initial ELO 1000)
!status        # Should display "0 players in queue"
!queue         # Adds you to the queue
!leave         # Removes you from the queue
!top           # Displays the leaderboard (empty at start)
```

### 3. Force a Match (Test with a Single Player)

As an admin (see [admin commands](USAGE.md#admin-commands)):
```
!mm_forcestart
```

This starts a match with players currently in queue, even if fewer than 10. Useful for testing the full flow.

### 4. Check the Web Panel

Open in a browser: `http://YOUR_IP:5000` (or the port you chose during the wizard).

The leaderboard and landing page should load. Click **Login** in the top-right corner to sign in with Steam. If your Steam account's SteamID matches `SUPER_ADMIN_STEAM_ID` in `config.env`, an **⚙ Admin** button will appear, granting access to the admin panel.

---

## 6. Troubleshooting

### Plugins Not Loading

**Symptom**: Commands like `!queue` don't work, no welcome message.

**Cause**: The `.smx` files (compiled plugins) are not in the right folder.

**Fix**:
```bash
# Check for plugins
ls -la /home/steam/csgo-dedicated/csgo/addons/sourcemod/plugins/
# Should contain: csgo_mm_queue.smx, csgo_mm_notify.smx, etc.

# If empty, re-run the installer — it compiles and deploys all plugins:
sudo ./install.sh --update

# Or compile manually after SourceMod is installed:
SPCOMP=/opt/csgo-server/csgo/addons/sourcemod/scripting/spcomp
$SPCOMP lobby-server/sourcemod/scripting/csgo_mm_queue.sp \
    -i lobby-server/sourcemod/scripting/include \
    -o /opt/csgo-server/csgo/addons/sourcemod/plugins/csgo_mm_queue.smx
```

### Matchmaker Not Starting

**Symptom**: `systemctl status csgo-matchmaker` shows `failed`.

**Common causes**:

```bash
# 1. Check that MySQL is ready
sudo systemctl status mysql

# 2. Check config.env
cat config.env | grep DB_

# 3. Test the connection manually
python3 -c "import mysql.connector; mysql.connector.connect(host='localhost', user='csgo_mm', password='YOUR_PASSWORD', database='csgo_matchmaking')"

# 4. Restart after fixing
sudo systemctl restart csgo-matchmaker
```

### Players Not Redirected to Match Server

**Symptom**: The ready check passes, but players stay on the lobby.

**Causes**:
1. The `csgo_mm_queue.smx` plugin is not loaded → check plugins
2. Docker failed to create the match container → `docker logs csgo-match-XXX`
3. The match GSLT token is invalid → check `mm_gslt_tokens` in DB

```bash
# View matchmaker logs
sudo journalctl -u csgo-matchmaker -n 100

# View match containers
docker ps -a --filter "name=csgo-match-"
docker logs csgo-match-<ID>
```

### Web Panel Inaccessible

```bash
# Check the service
sudo systemctl status csgo-webpanel

# Check the port (default 5000, or whatever WEB_PORT is set to in config.env)
ss -tlnp | grep "$(grep WEB_PORT config.env | cut -d= -f2)"

# Check the firewall (replace 5000 with your WEB_PORT if different)
sudo ufw allow 5000/tcp
sudo ufw reload
```

### Invalid GSLT Token

**Symptom**: The lobby server starts but is invisible in the server browser, or logs show "Invalid GSLT".

**Fix**:
1. Go to [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers)
2. Revoke and regenerate the relevant token with AppID **730**
3. Update `config.env`:
   ```bash
   nano config.env  # Edit GSLT_LOBBY or the match tokens
   sudo systemctl restart csgo-lobby
   ```

### Full Reset

If you need to start completely from scratch:

```bash
# Stop services
sudo systemctl stop csgo-lobby csgo-matchmaker csgo-webpanel

# Drop the database (DESTRUCTIVE)
mysql -u root -e "DROP DATABASE csgo_matchmaking;"

# Re-run the wizard
sudo ./install.sh
```

---

## Next Steps

- [Configuration](CONFIGURATION.md) — all `config.env` parameters
- [Usage](USAGE.md) — player commands, matchmaking flow, web panel, Steam admin
- [Maintenance](MAINTENANCE.md) — backups, updates, monitoring
- [Deploy](DEPLOY.md) — Docker Compose alternative deployment mode
