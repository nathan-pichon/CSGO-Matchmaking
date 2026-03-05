# Usage Guide — CS:GO Matchmaking

This document explains how to use the matchmaking system as a player, as well as the tools available to server administrators.

---

## Table of Contents

1. [Joining the Lobby](#joining-the-lobby)
2. [Player Commands](#player-commands)
3. [Matchmaking Flow](#matchmaking-flow)
4. [Ready Check Phase](#ready-check-phase)
5. [ELO Ranking System](#elo-ranking-system)
6. [Admin Commands](#admin-commands)
7. [Web Panel](#web-panel)
8. [Lobby Management](#lobby-management)

---

## Joining the Lobby

The lobby is the entry point for all matches. Connect via the CS:GO console:

```
connect IP:27015
```

Replace `IP` with the public IP address of the server provided by your administrator.

Once connected to the lobby, you can join the queue and access all matchmaking commands from the in-game chat.

---

## Player Commands

All commands are entered in the **in-game chat** (default key `Y`). A **5-second** cooldown applies between each command use to prevent abuse.

### Queue

| Command                  | Description |
|--------------------------|-------------|
| `!queue` or `!q`         | Join the matchmaking queue with no map preference. The matchmaker will automatically select a map from the available pool. |
| `!queue <map>`           | Join the queue expressing a preference for a specific map. The system will attempt to group players with the same preference. |
| `!leave` or `!unqueue`   | Leave the matchmaking queue. Use this command before disconnecting to free up your slot. |
| `!status`                | Display your current queue status: position, elapsed wait time, and map preference. |

**Available Maps:**

| Identifier    | Map      |
|---------------|----------|
| `de_dust2`    | Dust II  |
| `de_mirage`   | Mirage   |
| `de_inferno`  | Inferno  |
| `de_ancient`  | Ancient  |
| `de_nuke`     | Nuke     |
| `de_overpass` | Overpass |
| `de_vertigo`  | Vertigo  |

**Examples:**

```
!queue de_mirage
!queue de_dust2
!q
!leave
```

### Stats and Rankings

| Command  | Description |
|----------|-------------|
| `!rank`  | Display your current rank, ELO score, win/loss ratio (W/L), and kill/death ratio (K/D). |
| `!top`   | Display the top 10 players on the server, sorted by ELO in descending order. |
| `!stats` | Display your detailed statistics: total kills, deaths, assists, headshots, current win streak, best streak, win rate, and headshot percentage. |

**Example `!rank` output:**

```
[MM] YourName | Rank: Master Guardian I | ELO: 1042 | W/L: 18/12 | K/D: 1.24
```

**Example `!stats` output:**

```
[MM] YourName | Kills: 412 | Deaths: 332 | Assists: 87
     Headshots: 198 (48%) | Current Streak: 3W | Best Streak: 7W
     Win Rate: 60% | Matches Played: 30
```

---

## Matchmaking Flow

Here is the complete flow of a match, from entering the queue to the end of the game.

```
Player → connect IP:27015
         ↓
    CS:GO Lobby
         ↓
    !queue [map]
         ↓
    Queue (mm_queue)
         ↓
    Matchmaker finds 10 ELO-compatible players
         ↓
    Ready Check phase (30 seconds)
         ↓
    All players accept
         ↓
    Docker container launched (dedicated match server)
         ↓
    All 10 players automatically connected to match server
         ↓
    Competitive 5v5 match (MR30, overtime enabled)
         ↓
    Match ends → Stats saved and ELO calculated
         ↓
    15-second countdown
         ↓
    Automatic redirect back to lobby
```

**Team formation details:**

Teams are composed via an **ELO-based snake draft**:
- The 10 players are sorted by ELO in descending order.
- Player 1 goes to Team A, player 2 to Team B, player 3 to Team B, player 4 to Team A, player 5 to Team A, and so on.
- This system ensures a balanced distribution of skill levels between both teams.

---

## Ready Check Phase

When the matchmaker has found 10 compatible players, a **confirmation window** appears on each player's screen.

- The window shows: the selected map and a **30-second** countdown.
- Click **ACCEPT** to confirm your participation.
- If you click **DECLINE** or the timer expires without a response:
  - You receive a **5-minute temporary ban** from the queue.
  - Other players who had accepted are automatically returned to the queue.

> If you need to step away briefly, use `!leave` before the ready check triggers to avoid a ban.

---

## ELO Ranking System

### Starting Out

Every new player starts with an ELO of **1000** (Master Guardian I).

### Tiers

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

### K-Factor

ELO gains and losses per match depend on the **K-factor** applied to your profile:

| Situation                                     | K-Factor | Effect |
|-----------------------------------------------|----------|--------|
| Placement matches (< 10 matches played)       | **64**   | Large swings for fast positioning |
| Established player (10 to 30 matches)         | **32**   | Standard swings |
| Veteran player (> 30 matches)                 | **24**   | Reduced swings for greater stability |

### Progression

- **Winning** earns ELO, **losing** costs ELO.
- The number of points gained or lost depends on the ELO gap between the two teams: beating a stronger team earns more.
- Individual performance (kills, headshots) does not directly influence ELO — only the match result matters.

---

## Admin Commands

Admin commands require the **ADMFLAG_ROOT** flag (SourceMod root access). They are entered in the in-game chat with the `!` prefix.

| Command                                          | Description |
|--------------------------------------------------|-------------|
| `!mm_forcestart`                                 | Force-start a match with players currently in the queue. Requires a minimum of **2 players**. Useful for testing. |
| `!mm_cancelqueue`                                | Cancel all waiting queue entries and return players to available status. |
| `!mm_ban <#userid\|name> <minutes> <reason>`     | Ban a player from the matchmaking queue for a set duration in minutes. Use `#userid` (e.g. `#42`) or the player's name. |
| `!mm_unban <STEAM_X:Y:Z>`                        | Lift a ban for a player identified by their SteamID (format `STEAM_0:1:12345678`). |
| `!mm_setelo <#userid\|name> <elo>`               | Manually set a player's ELO. The value must be between **0 and 9999**. |
| `!mm_resetrank <#userid\|name>`                  | Reset a player's ELO to the default value (**1000**) and reset their placement match counter. |
| `!mm_status`                                     | Display a real-time summary: number of active matches, number of players in queue by status, and list of ongoing match servers. |

**Usage examples:**

```
!mm_ban #42 30 Toxic behaviour
!mm_unban STEAM_0:1:12345678
!mm_setelo TopFragger 1800
!mm_resetrank #7
!mm_forcestart
!mm_status
```

> Admin commands are logged in the SourceMod logs with the identity of the acting administrator.

---

## Web Panel

The web panel is accessible at `http://IP:5000` (replace `IP` with the server address).

### Available Pages

| URL                       | Description |
|---------------------------|-------------|
| `/leaderboard`            | Paginated leaderboard of all players, sorted by ELO in descending order. Filterable by season. |
| `/player/<steam_id>`      | Full player profile: ELO history chart, recent match history, detailed statistics. |
| `/matches`                | List of recent matches with date, map, scores, and duration. |
| `/match/<id>`             | Complete match dashboard: K/D/A, headshots, MVP, ELO change for each player. |

### REST API

JSON endpoints are available for integrating data into external tools (Discord bots, websites, dashboards):

| Endpoint                   | Description |
|----------------------------|-------------|
| `GET /api/queue/count`     | Returns the current number of players in the queue. |
| `GET /api/player/<id>`     | Returns a player's JSON profile (ELO, rank, statistics). |
| `GET /api/leaderboard`     | Returns the full leaderboard in JSON format. Optional parameter: `?season=N`. |
| `GET /api/matches`         | Returns the list of recent matches in JSON format. |

**Example `/api/queue/count` response:**

```json
{
  "count": 7,
  "updated_at": "2026-03-05T14:32:11Z"
}
```

**Example `/api/player/<id>` response:**

```json
{
  "steam_id": "STEAM_0:1:12345678",
  "name": "TopFragger",
  "elo": 1842,
  "rank": "Legendary Eagle Master",
  "wins": 74,
  "losses": 31,
  "kd_ratio": 1.47,
  "matches_played": 105
}
```

---

## Lobby Management

This section is intended for server operators.

### AFK Detection

- A player who remains in **spectator for 5 consecutive minutes** is automatically removed from the queue.
- They receive a chat notification telling them they have been removed from the queue.
- They can re-queue by typing `!queue` once they join a team or interact with the server.

### Queue Expiry

- A queue entry automatically expires after **15 minutes** if no match could be formed.
- The player is notified via chat and must type `!queue` to rejoin the queue.
- This mechanism prevents orphaned database entries during silent disconnections.

### Automatic Broadcast Messages

- Every **2 minutes**, the lobby server sends a broadcast message to all connected players showing the current number of players in queue.

Example:

```
[MM] 6 player(s) in queue! Type !queue to join!
```

### Best Practices for Operators

- Regularly monitor matchmaker logs (`matchmaker/logs/`) to detect container launch errors.
- Use `!mm_status` in-game to check the overall system status without accessing the server.
- If a match is stuck (match server unreachable), manually cancel the match via the Docker interface (`docker ps` / `docker stop <container>`) then clear the queue with `!mm_cancelqueue`.
- Schedule lobby restarts during off-peak hours to avoid interrupting ongoing matches.
