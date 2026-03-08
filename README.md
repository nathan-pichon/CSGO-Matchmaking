# CS:GO Competitive Matchmaking System

A community-driven competitive matchmaking system for CS:GO Legacy, providing automated 5v5 competitive matches with ELO-based ranking, persistent statistics, and seamless player experience.

## Overview

Since Valve shut down official CS:GO matchmaking servers, this project recreates the competitive matchmaking experience using community tools. Players join a lobby server, queue via chat commands, get matched by skill level, and are automatically redirected to dedicated match servers.

### Key Features

- **Chat-based queue**: `!queue`, `!leave`, `!status`, `!rank`, `!top`, `!lastmatch`
- **ELO-based matchmaking**: Dynamic spread, placement matches, skill-balanced teams
- **Ready check system**: 30-second accept/decline window
- **Automated match servers**: Docker containers spun up on demand with competitive configs
- **Automatic redirection**: Players seamlessly moved between lobby and match servers
- **Knife round + side choice**: Winner's captain picks CT or T to start
- **In-match features**: Tactical pauses, surrender vote (`!ff`), player reporting (`!report`)
- **Persistent statistics**: Kills, deaths, assists, headshots, win rate, ELO history
- **Abandon penalties**: Progressive cooldowns (30 min → 7 days) for players who quit mid-match
- **Web panel**: Leaderboard, player profiles, match history — login with Steam
- **Admin panel**: Steam-authenticated admin interface (no shared passwords)
- **Seasonal rankings**: Periodic ELO resets with historical data preservation
- **Discord notifications**: Match found, results, rank changes via webhooks
- **Cloud-aware installer**: Auto-detects AWS, GCP, Azure, Hetzner, DigitalOcean, OVH and shows provider-specific firewall setup instructions

## Architecture

```
Player --(!queue)--> [Lobby Server + SourceMod Plugins]
                            |
                     [MySQL Database]
                            |
                     [Matchmaker Daemon (Python)]
                       |          |
            [Queue Backend]   [Server Backend]
            (MySQL poll)      (Docker)
                       |          |
                     [Match Server (Docker)] --> match end --> back to lobby
                            |
                     [Web Panel (Flask)] <-- Steam OpenID login
```

### Modular Design

The Python matchmaker uses abstract interfaces (ABC) for all swappable components:

| Component | Default | Can be replaced with |
|-----------|---------|---------------------|
| Queue backend | MySQL polling | Redis pub/sub, RabbitMQ |
| Server orchestration | Docker API | Kubernetes, Podman |
| Ranking system | ELO | Glicko-2, TrueSkill |
| Notifications | Discord webhooks | Slack, Telegram, email |

Change backends by setting `QUEUE_BACKEND`, `SERVER_BACKEND`, etc. in `config.env`.

## Quick Start

### Prerequisites

- Linux server (Ubuntu/Debian, CentOS/RHEL, Fedora, or Arch) — bare-metal or cloud VM
- 4 GB RAM, 2 CPU cores, 50 GB disk (minimum)
- Steam account with GSLT tokens ([generate here](https://steamcommunity.com/dev/managegameservers) with AppID 730)
- Your SteamID (find yours at [steamid.io](https://steamid.io)) — needed to seed the first admin account

### Installation

```bash
git clone https://github.com/YOUR_USERNAME/CSGO-Matchmaking.git
cd CSGO-Matchmaking
chmod +x install.sh
sudo ./install.sh
```

The interactive wizard walks you through every required decision, then handles the rest autonomously:

1. **System packages** — installs SteamCMD, MySQL/MariaDB, Python, Docker, and all dependencies
2. **MySQL setup** — uses an existing instance or installs a fresh one, creates the database and user
3. **Network** — lobby port (27015), web panel port (8080), match server port range (27020–27029)
4. **Matchmaking rules** — ELO spread, players per team, queue timeout
5. **CS:GO server** — downloads the dedicated server via SteamCMD (can take 20–30 min on first run)
6. **Map pool** — choose which competitive maps to include
7. **GSLTs** — your Game Server Login Tokens for lobby and match servers
8. **Web panel** — admin password, Discord webhook (optional), your SteamID for the admin account
9. **Cloud firewall notice** — if a cloud provider is detected, shows provider-specific port-opening instructions before you confirm

When the wizard finishes, the installer:
- Installs SourceMod, MetaMod, and all plugins
- Compiles match-server plugins using the installed `spcomp` binary
- Builds the Docker image for match servers
- Opens the required ports (UFW / firewalld / iptables)
- Creates and **starts** all three systemd services immediately

> **Interrupted install?** Re-run `sudo ./install.sh --update`. It loads your existing `config.env`, skips completed steps, and picks up where it left off safely.

### After Installation

```
Admin panel:  http://YOUR_SERVER_IP:5000/admin   (sign in with Steam)
Leaderboard:  http://YOUR_SERVER_IP:5000
```

On your first visit to the admin panel, sign in with the Steam account whose SteamID you provided during the wizard. That account is automatically seeded as the super-admin.

### Connect & Play

1. Launch CS:GO Legacy
2. Open the console: `connect YOUR_SERVER_IP:27015`
3. Type `!queue` in chat to join matchmaking
4. When 10 players are ready, accept the ready check — you'll be redirected automatically

### Service Management

```bash
# Status
sudo systemctl status csgo-lobby csgo-matchmaker csgo-webpanel

# Restart all
sudo systemctl restart csgo-matchmaker csgo-webpanel

# Logs
journalctl -u csgo-matchmaker -f
journalctl -u csgo-webpanel -f
```

## Project Structure

```
CSGO-Matchmaking/
├── install.sh                  # One-command installation wizard
├── SETUP.md                    # Detailed setup guide (cloud providers, troubleshooting)
├── config.example.env          # Configuration template
├── database/schema.sql         # Database schema and default data
├── matchmaker/                 # Python matchmaker daemon
│   ├── interfaces/             # Abstract interfaces (ABC)
│   ├── backends/               # Concrete implementations
│   │   ├── mysql_queue.py      # Queue management
│   │   ├── docker_server.py    # Match server orchestration
│   │   ├── elo_ranking.py      # ELO calculation
│   │   └── discord_notifier.py # Discord webhooks
│   └── tests/                  # Unit tests
├── lobby-server/               # Lobby SourceMod plugins
│   ├── sourcemod/scripting/    # SourcePawn source (.sp)
│   └── cfg/                    # Server configuration
├── match-server/               # Docker match server
│   ├── Dockerfile
│   ├── sourcemod/
│   │   ├── scripting/          # Match lifecycle plugin (.sp)
│   │   ├── plugins/            # Compiled binaries (.smx) — built by installer
│   │   └── configs/
│   └── cfg/                    # Competitive configuration
├── web-panel/                  # Flask web application
│   ├── routes/                 # Page routes (incl. Steam OpenID auth)
│   └── templates/              # Jinja2 templates
├── vendor/                     # Pinned third-party plugin binaries
│   └── sourcemod/plugins/      # levels_ranks.smx, serverredirect.smx
└── installer/                  # Installer modules
    ├── globals.sh
    ├── lib/                    # Logging, UI, input, system helpers
    └── steps/                  # 01_packages … 09_services
```

## In-Game Commands

### Player Commands (Lobby Server)

| Command | Description |
|---------|-------------|
| `!queue` / `!q` | Join the matchmaking queue |
| `!queue de_mirage` | Join with a map preference |
| `!leave` | Leave the queue |
| `!status` | Show queue position and estimated wait time |
| `!rank` | Show your ELO and rank tier |
| `!top` | Show the top 10 players |
| `!stats` | Show your detailed career statistics |
| `!lastmatch` | Show your most recent match result and ELO change |

### Player Commands (Match Server)

| Command | Description |
|---------|-------------|
| `!ff` / `!surrender` | Call a surrender vote (requires 4/5 votes — unconditional loss) |
| `!pause` | Request a tactical pause at next freeze time (1 per team per match) |
| `!unpause` | Signal your team is ready to resume (both teams must confirm) |
| `!report <player>` | Report a player (cheating / griefing / AFK / toxic behavior) |

### Admin Commands (Lobby Server)

> Admins are managed via the web admin panel — no shared passwords.

| Command | Description |
|---------|-------------|
| `!mm_forcestart` | Force start a match with the current queue |
| `!mm_cancelqueue` | Clear all queue entries |
| `!mm_ban <player> <minutes> <reason>` | Ban a player from matchmaking |
| `!mm_unban <steamid>` | Remove a matchmaking ban |
| `!mm_setelo <player> <elo>` | Override a player's ELO |
| `!mm_status` | Show system status |

## Configuration

The installer generates `config.env` from your wizard answers. Key settings you can tune afterwards:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_ELO_SPREAD` | `200` | Starting ELO tolerance for matchmaking |
| `ELO_SPREAD_INCREASE_INTERVAL` | `60` | Seconds between ELO spread expansions |
| `ELO_SPREAD_INCREASE_AMOUNT` | `50` | ELO points added per interval |
| `PLAYERS_PER_TEAM` | `5` | Players per side |
| `READY_CHECK_TIMEOUT` | `30` | Seconds to accept a ready check |
| `WARMUP_TIMEOUT` | `180` | Seconds to connect before warmup cancels the match |
| `SUPER_ADMIN_STEAM_ID` | *(set by wizard)* | SteamID of the initial super-admin account |

After editing `config.env`, restart affected services:

```bash
sudo systemctl restart csgo-matchmaker csgo-webpanel
```

## Documentation

| Document | Description |
|----------|-------------|
| [Setup Guide](docs/SETUP.md) | All-in-one setup: cloud providers, admin panel walkthrough, in-game commands |
| [Installation](docs/INSTALLATION.md) | Step-by-step installation, GSLT tokens, post-install verification, troubleshooting |
| [Configuration](docs/CONFIGURATION.md) | Complete `config.env` reference, ELO tiers, backend options |
| [Usage](docs/USAGE.md) | Player and admin commands, matchmaking flow, web panel, Steam auth |
| [Maintenance](docs/MAINTENANCE.md) | Backups, updates, monitoring, season resets, DB management |
| [Deploy](docs/DEPLOY.md) | Bare-metal systemd vs Docker Compose deployment modes |
| [Contributing](docs/CONTRIBUTING.md) | Developer setup, adding backends, SourcePawn development, code conventions |

## Tech Stack

- **Game Server**: CS:GO Dedicated Server (SteamCMD, app 740)
- **Plugins**: SourceMod + MetaMod:Source + Levels Ranks + ServerRedirect
- **Orchestration**: Python 3.10+ with python-valve, Docker SDK
- **Database**: MySQL 8.0 / MariaDB
- **Web**: Flask + Jinja2 + SQLAlchemy + Steam OpenID
- **Containerization**: Docker (cm2network/csgo base image)

## License

MIT License — see [LICENSE](LICENSE)
