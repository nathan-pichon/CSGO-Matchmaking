# Docker Compose Deployment

This guide covers running the CS:GO Matchmaking backend services (MySQL, matchmaker daemon, web panel) in Docker Compose — an alternative to the standard systemd-based installation.

> For the recommended bare-metal installation that handles everything automatically, see [INSTALLATION.md](INSTALLATION.md) or run `sudo ./install.sh`.

---

## When to use Docker Compose

| Use case | Recommended approach |
|----------|---------------------|
| Production server (bare-metal/VPS) | `sudo ./install.sh` → systemd services |
| Local development / CI testing | **Docker Compose** |
| Server with existing Docker infrastructure | **Docker Compose** |
| Cloud environment with container orchestration | Docker Compose or adapt to your orchestrator |

---

## Architecture

```
docker-compose.yml manages:
  ✅ MySQL 8.0              (csgo-mm-mysql)
  ✅ Python matchmaker      (csgo-mm-matchmaker)
  ✅ Flask web panel        (csgo-mm-webpanel)

Outside Docker Compose:
  ⚠️  CS:GO lobby server   → must run with --network=host (systemd or standalone container)
  ✅  Match servers         → Docker containers launched dynamically by the matchmaker
```

> **Important**: The CS:GO lobby server cannot run inside a Docker Compose bridge network due to Source Engine UDP networking constraints. It must use host networking.

---

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/CSGO-Matchmaking.git
cd CSGO-Matchmaking

# Copy and edit the config
cp config.example.env config.env
```

Edit `config.env` with at minimum:
- `DB_PASS` — MySQL password
- `RCON_PASSWORD` — RCON password
- `SERVER_IP` — your server's public IP
- `LOBBY_GSLT` — GSLT token for the lobby server
- `SUPER_ADMIN_STEAM_ID` — your Steam ID (`STEAM_0:X:Y`)
- `SECRET_KEY` — Flask secret (generate with `python3 -c "import secrets; print(secrets.token_hex(32))"`)

### 2. Start backend services

```bash
docker compose up -d
```

MySQL is initialised automatically on first start — `database/schema.sql` is mounted as an init script.

### 3. Check services

```bash
docker compose ps
docker compose logs -f matchmaker
docker compose logs -f webpanel
```

### 4. Start the lobby server

**Option A — systemd (after running the installer)**:

```bash
sudo systemctl start csgo-lobby
```

**Option B — standalone Docker container** (if CS:GO files are already downloaded):

```bash
docker run -d \
  --name csgo-lobby \
  --network=host \
  -e SRCDS_TOKEN="${LOBBY_GSLT}" \
  -e SRCDS_PORT=27015 \
  -e SRCDS_MAXPLAYERS=32 \
  -e SRCDS_STARTMAP=de_dust2 \
  -e SRCDS_GAMETYPE=0 \
  -e SRCDS_GAMEMODE=0 \
  -v "$(pwd)/lobby-server/cfg/server.cfg:/home/steam/csgo-dedicated/csgo/cfg/server.cfg:ro" \
  -v "$(pwd)/lobby-server/sourcemod:/home/steam/csgo-dedicated/csgo/addons/sourcemod:ro" \
  cm2network/csgo:sourcemod
```

---

## Managing Services

```bash
# Live logs from all services
docker compose logs -f

# Restart a single service
docker compose restart matchmaker

# Stop everything (data preserved)
docker compose down

# Stop + delete MySQL data volume (DESTRUCTIVE)
docker compose down -v

# Rebuild images after code changes
docker compose build matchmaker webpanel
docker compose up -d matchmaker webpanel
```

---

## Compile Plugins (Docker Compose users)

The standard installer compiles SourceMod plugins automatically. If you are using Docker Compose without running the installer, compile plugins manually:

```bash
# Download SourceMod compiler
SM_URL=$(curl -s "https://www.sourcemod.net/downloads.php?branch=stable" \
  | grep -oP 'https://sm\.alliedmods\.net/smdrop/[^"]+linux\.tar\.gz' | head -1)
curl -L "$SM_URL" -o sm.tar.gz && tar xzf sm.tar.gz

SPCOMP="./addons/sourcemod/scripting/spcomp"
chmod +x "$SPCOMP"

# Compile lobby server plugins
for SP in lobby-server/sourcemod/scripting/*.sp; do
  NAME=$(basename "${SP%.sp}")
  "$SPCOMP" "$SP" \
    -i lobby-server/sourcemod/scripting/include \
    -i ./addons/sourcemod/scripting/include \
    -o "lobby-server/sourcemod/plugins/${NAME}.smx"
done

# Compile match server plugin
for SP in match-server/sourcemod/scripting/*.sp; do
  NAME=$(basename "${SP%.sp}")
  "$SPCOMP" "$SP" \
    -i match-server/sourcemod/scripting/include \
    -i ./addons/sourcemod/scripting/include \
    -o "match-server/sourcemod/plugins/${NAME}.smx"
done
```

Then rebuild the match-server Docker image:

```bash
docker build -t csgo-match-server:latest -f match-server/Dockerfile match-server/
```

---

## Updating

```bash
git pull

# Rebuild and restart backend services
docker compose build matchmaker webpanel
docker compose up -d matchmaker webpanel

# Apply any schema changes (idempotent)
docker compose exec mysql mysql -u csgo_mm -p csgo_matchmaking < database/schema.sql
```

---

## Monitoring

```bash
# Health check (checks MySQL, Docker, ports, services)
./scripts/health_check.sh

# JSON output for Prometheus/Grafana
./scripts/health_check.sh --json

# Database backup
./scripts/backup.sh

# Active match containers
docker ps --filter "name=csgo-match-"

# Logs for a specific match server
docker logs csgo-match-<ID>
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Matchmaker exits at startup | DB not ready yet | Docker Compose healthcheck retries; wait 10–15s then check `docker compose logs matchmaker` |
| Players not redirected to match servers | `csgo_mm_queue.smx` missing | Compile and copy plugins (see section above) |
| Match container crashes immediately | Invalid GSLT in `mm_gslt_tokens` | Regenerate token at [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers) (AppID 730) |
| Web panel at `/admin` shows no Admin button | `SUPER_ADMIN_STEAM_ID` not set or Steam ID mismatch | Check `config.env`, restart `csgo-mm-webpanel` |
| Lobby server invisible in server browser | Invalid `LOBBY_GSLT` or wrong AppID | Must use AppID **730** |

---

*Last updated: 2026-03-08*
