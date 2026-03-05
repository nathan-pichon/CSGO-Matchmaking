# Contributing to CS:GO Matchmaking System

Thank you for contributing! This guide explains how to set up a development environment, understand the architecture, and add new features or backends.

## Table of Contents

1. [Development Setup](#development-setup)
2. [Architecture Overview](#architecture-overview)
3. [Adding a New Backend](#adding-a-new-backend)
4. [SourcePawn Plugin Development](#sourcepawn-plugin-development)
5. [Code Conventions](#code-conventions)
6. [Testing](#testing)
7. [Pull Request Process](#pull-request-process)

---

## Development Setup

### Prerequisites

- Python 3.10+
- MySQL 8.0 or MariaDB 10.6+
- Docker
- A text editor with Python and SourcePawn support

### Local Development (no CS:GO needed)

```bash
# 1. Clone the repo
git clone https://github.com/YOUR_USERNAME/CSGO-Matchmaking.git
cd CSGO-Matchmaking

# 2. Copy and configure
cp config.example.env config.env
# Edit config.env with your local DB credentials

# 3. Create DB
mysql -u root -p -e "CREATE DATABASE csgo_matchmaking;"
mysql -u root -p csgo_matchmaking < database/schema.sql

# 4. Set up Python virtualenv
cd matchmaker
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# 5. Run tests
pytest tests/ -v

# 6. Run the matchmaker (will poll DB but not find a CS:GO server — that's fine)
python matchmaker.py
```

### Web Panel Development

```bash
cd web-panel
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Load config
export $(grep -v '^#' ../config.env | xargs)

# Run Flask dev server
flask run --debug
```

---

## Architecture Overview

### Data Flow

```
[Lobby Sourcemod Plugin]
    |-- writes to --> mm_queue (status=waiting)
    |-- reads from --> mm_queue (status=ready_check, matched)

[Python Matchmaker Daemon]
    |-- polls --> mm_queue via QueueBackend interface
    |-- creates --> mm_matches via DB
    |-- spins --> Docker containers via ServerBackend interface
    |-- updates --> mm_players ELO via RankingBackend interface
    |-- sends --> notifications via NotificationBackend interface

[Match Server Sourcemod Plugin]
    |-- verifies players via mm_match_players
    |-- writes stats to mm_match_players
    |-- updates mm_matches status=finished
```

### Modular Backends

The matchmaker uses **Abstract Base Classes (ABCs)** in `matchmaker/interfaces/` to define contracts. Concrete implementations live in `matchmaker/backends/`. The correct backend is selected at startup via `config.env` and `matchmaker/factory.py`.

This means: **you can change the underlying technology without touching `matchmaker.py`**.

Current implementations:

| Interface | Implementation | Config value |
|-----------|---------------|-------------|
| `QueueBackend` | `MySQLQueueBackend` | `QUEUE_BACKEND=mysql` |
| `ServerBackend` | `DockerServerBackend` | `SERVER_BACKEND=docker` |
| `RankingBackend` | `EloRankingBackend` | `RANKING_BACKEND=elo` |
| `NotificationBackend` | `DiscordNotifier` | `NOTIFICATION_BACKEND=discord` |

---

## Adding a New Backend

Here's a complete example: adding Redis as a queue backend.

### Step 1: Implement the ABC

```python
# matchmaker/backends/redis_queue.py

from typing import List, Optional
from interfaces.queue_backend import QueueBackend, QueueEntry, MatchGroup
import redis
import json

class RedisQueueBackend(QueueBackend):
    """Queue backend using Redis pub/sub and sorted sets."""

    def __init__(self, config):
        self.config = config
        self.client = redis.Redis(
            host=config.REDIS_HOST,
            port=config.REDIS_PORT,
            decode_responses=True
        )

    def add_to_queue(self, steam_id: str, elo: int, map_preference: Optional[str] = None) -> bool:
        """Add a player to the Redis sorted set, keyed by ELO."""
        entry = json.dumps({
            "steam_id": steam_id,
            "elo": elo,
            "map_preference": map_preference,
            "queued_at": time.time()
        })
        # Score = ELO (for range queries)
        return self.client.zadd("mm:queue:waiting", {entry: elo})

    def get_waiting(self) -> List[QueueEntry]:
        """Get all waiting players from the sorted set."""
        raw = self.client.zrangebyscore("mm:queue:waiting", "-inf", "+inf", withscores=True)
        return [QueueEntry(**json.loads(entry)) for entry, _ in raw]

    # ... implement all other abstract methods
```

### Step 2: Register in the factory

```python
# matchmaker/factory.py  — add to create_queue_backend()
elif config.QUEUE_BACKEND == "redis":
    from backends.redis_queue import RedisQueueBackend
    return RedisQueueBackend(config)
```

### Step 3: Add config variables

```env
# config.example.env
QUEUE_BACKEND=redis
REDIS_HOST=localhost
REDIS_PORT=6379
```

Add them to `matchmaker/config.py`:
```python
self.REDIS_HOST = os.getenv('REDIS_HOST', 'localhost')
self.REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
```

### Step 4: Add the dependency

```
# matchmaker/requirements.txt
redis>=5.0.0
```

### Step 5: Write tests

```python
# matchmaker/tests/test_redis_queue.py
from unittest.mock import MagicMock, patch
from backends.redis_queue import RedisQueueBackend

def test_add_to_queue():
    with patch('redis.Redis') as mock_redis:
        backend = RedisQueueBackend(mock_config)
        result = backend.add_to_queue("STEAM_0:0:12345", 1200)
        assert result == True
        mock_redis.return_value.zadd.assert_called_once()
```

### Step 6: Document it

Update the table in this file and add a note in `config.example.env`.

---

## SourcePawn Plugin Development

### Setting Up SourceMod Compiler

```bash
# Download SourceMod (Linux)
wget https://sm.alliedmods.net/smdrop/1.11/sourcemod-1.11.0-gitXXX-linux.tar.gz
tar xzf sourcemod-1.11.0-*.tar.gz

# Compile a plugin
./addons/sourcemod/scripting/spcomp lobby-server/sourcemod/scripting/csgo_mm_queue.sp \
    -i lobby-server/sourcemod/scripting/include \
    -o lobby-server/sourcemod/plugins/csgo_mm_queue.smx
```

### Plugin Architecture Principles

- **Always use `SQL_TQuery`** (threaded queries) for database access — never blocking queries during gameplay
- **Use `#include <csgo_mm>`** for shared constants and forward declarations
- **Check client validity** before any `client > 0 && IsClientInGame(client)` operations
- **Handle DB connection failure** gracefully — disable features, inform players, don't crash

### Testing Plugins

1. Run a local CS:GO dedicated server with SourceMod installed
2. Copy `.smx` files to `addons/sourcemod/plugins/`
3. Test via `sm plugins reload csgo_mm_queue` in server console
4. Check `addons/sourcemod/logs/` for errors

---

## Code Conventions

### Python

- **Type hints** on all function signatures
- **Docstrings** on all public methods (Google style)
- **Logging** via `logging` module — never `print()` in production code
- **Error handling** — catch specific exceptions, log with context, don't swallow silently
- **Line length** — 100 characters max

```python
def calculate_elo_change(
    player_elo: int,
    team_avg_elo: float,
    opponent_avg_elo: float,
    won: bool,
    k_factor: int,
) -> int:
    """Calculate ELO change for a single player after a match.

    Args:
        player_elo: Player's current ELO rating.
        team_avg_elo: Average ELO of the player's team.
        opponent_avg_elo: Average ELO of the opposing team.
        won: Whether the player's team won.
        k_factor: ELO K-factor (volatility multiplier).

    Returns:
        Integer ELO change (positive = gain, negative = loss).
    """
```

### SourcePawn

- Use `MM_PREFIX` constant for all chat messages: `PrintToChat(client, "%s Message here", MM_PREFIX);`
- Comments on all public functions
- Enum states for plugin state machines
- Handle all SQL query results even if ignoring them

### SQL

- Use `IF NOT EXISTS` on all CREATE TABLE statements
- Add a comment above each table explaining its purpose
- Use transactions for multi-step updates (ELO update + history insert)

---

## Testing

### Python Unit Tests

```bash
cd matchmaker
source venv/bin/activate
pytest tests/ -v --cov=. --cov-report=term-missing
```

Tests use `unittest.mock` to mock Docker, MySQL, and RCON calls. No external services needed.

### Integration Testing (requires MySQL)

```bash
# Set TEST_DB_URL in your env
export TEST_DB_URL="mysql://csgo_mm:password@localhost/csgo_matchmaking_test"
pytest tests/ -v -m integration
```

### Manual End-to-End Test

See the Verification section in the main README or use the admin command `!mm_forcestart` to trigger a match with fewer than 10 players for testing.

---

## Pull Request Process

1. **Fork** the repository
2. **Branch** from `main` with a descriptive name: `feature/redis-queue-backend`, `fix/elo-decay-calculation`
3. **Write tests** for new functionality
4. **Update docs**: `config.example.env` for new config vars, this file for new backends
5. **Open a PR** with:
   - What changed and why
   - How to test it
   - Any breaking changes

### Commit Message Format

```
type(scope): short description

Longer explanation if needed.
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`

Examples:
- `feat(queue): add Redis queue backend`
- `fix(elo): cap ELO floor at rank minimum instead of 0`
- `docs(contributing): add Redis backend example`

---

## Getting Help

- Open a GitHub Issue for bugs or feature requests
- See `scripts/health_check.sh` for diagnosing system problems
- Check `addons/sourcemod/logs/` on the game server for plugin errors
- The matchmaker logs to stdout (captured by systemd journal: `journalctl -u csgo-matchmaker -f`)
