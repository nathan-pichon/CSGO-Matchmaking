# CS:GO Competitive Matchmaking System

A community-driven competitive matchmaking system for CS:GO Legacy, providing automated 5v5 competitive matches with ELO-based ranking, persistent statistics, and seamless player experience.

## Overview

Since Valve shut down official CS:GO matchmaking servers, this project recreates the competitive matchmaking experience using community tools. Players join a lobby server, queue via chat commands, get matched by skill level, and are automatically redirected to dedicated match servers.

### Key Features

- **Chat-based queue**: `!queue`, `!leave`, `!status`, `!rank`, `!top`
- **ELO-based matchmaking**: Dynamic spread, placement matches, skill-balanced teams
- **Ready check system**: 30-second accept/decline with cooldown penalties
- **Automated match servers**: Docker containers spun up on demand with competitive configs
- **Automatic redirection**: Players seamlessly moved between lobby and match servers
- **Persistent statistics**: Kills, deaths, assists, headshots, win rate, ELO history
- **Web panel**: Browser-based leaderboard, player profiles, and match history
- **Seasonal rankings**: Periodic ELO resets with historical data preservation
- **Discord notifications**: Match found, results, rank changes via webhooks

## Architecture

```
Player --(!queue)--> [Lobby Server + Sourcemod Plugins]
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
                     [Web Panel (Flask)]
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

- Linux server (Ubuntu/Debian, CentOS/RHEL, Fedora, or Arch)
- 4+ GB RAM, 2+ CPU cores, 50+ GB disk
- Steam account with GSLT tokens ([generate here](https://steamcommunity.com/dev/managegameservers) with AppID 730)

### Installation

```bash
git clone https://github.com/YOUR_USERNAME/CSGO-Matchmaking.git
cd CSGO-Matchmaking
chmod +x install.sh
sudo ./install.sh
```

The interactive wizard handles everything: package installation, CS:GO server download, database setup, plugin installation, Docker image building, and systemd service creation.

### Manual Start/Stop

```bash
# Start all services
sudo systemctl start csgo-lobby csgo-matchmaker csgo-webpanel

# Stop all services
sudo systemctl stop csgo-lobby csgo-matchmaker csgo-webpanel

# Check status
sudo systemctl status csgo-matchmaker
```

### Connect

1. Launch CS:GO Legacy
2. Open console and type: `connect YOUR_SERVER_IP:27015`
3. Type `!queue` in chat to join the matchmaking queue
4. Wait for 10 players, accept the ready check, and play!

## Project Structure

```
CSGO-Matchmaking/
├── install.sh                  # Installation wizard
├── config.example.env          # Configuration template
├── database/schema.sql         # Database schema
├── matchmaker/                 # Python matchmaker daemon
│   ├── interfaces/             # Abstract interfaces (ABC)
│   ├── backends/               # Concrete implementations
│   └── tests/                  # Unit tests
├── lobby-server/               # Lobby Sourcemod plugins
│   ├── sourcemod/scripting/    # SourcePawn source files
│   └── cfg/                    # Server configuration
├── match-server/               # Docker match server
│   ├── Dockerfile
│   ├── sourcemod/scripting/    # Match lifecycle plugin
│   └── cfg/                    # Competitive configuration
├── web-panel/                  # Flask web application
│   ├── routes/                 # Page routes
│   └── templates/              # Jinja2 templates
└── scripts/                    # Utility scripts
```

## In-Game Commands

| Command | Description |
|---------|-------------|
| `!queue` or `!q` | Join the matchmaking queue |
| `!queue de_mirage` | Join with map preference |
| `!leave` | Leave the queue |
| `!status` | Show queue status and count |
| `!rank` | Show your rank and ELO |
| `!top` | Show top 10 players |
| `!stats` | Show your detailed statistics |

### Admin Commands

| Command | Description |
|---------|-------------|
| `!mm_forcestart` | Force start a match with current queue |
| `!mm_cancelqueue` | Clear all queue entries |
| `!mm_ban <player> <minutes> <reason>` | Ban from matchmaking |
| `!mm_unban <steamid>` | Remove ban |
| `!mm_setelo <player> <elo>` | Override ELO |
| `!mm_status` | Show system status |

## Configuration

Copy `config.example.env` to `config.env` and adjust values. Key settings:

- `MAX_ELO_SPREAD`: Starting ELO difference tolerance (default: 200)
- `ELO_SPREAD_INCREASE_INTERVAL/AMOUNT`: Queue time widens the spread
- `PLAYERS_PER_TEAM`: Players per side (default: 5)
- `READY_CHECK_TIMEOUT`: Seconds to accept (default: 30)
- `WARMUP_TIMEOUT`: Seconds to connect before match cancellation (default: 180)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code conventions, and how to add new backends.

## Tech Stack

- **Game Server**: CS:GO Dedicated Server (SteamCMD, app 740)
- **Plugins**: SourceMod + MetaMod:Source + Levels Ranks + ServerRedirect
- **Orchestration**: Python 3.10+ with python-valve, Docker SDK
- **Database**: MySQL 8.0 / MariaDB
- **Web**: Flask + Jinja2 + SQLAlchemy
- **Containerization**: Docker (cm2network/csgo base image)

## License

MIT License - See [LICENSE](LICENSE)
