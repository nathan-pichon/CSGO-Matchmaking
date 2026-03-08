# Usage Guide — CS:GO Matchmaking

This document explains how to use the matchmaking system as a player, and the tools available to server administrators.

---

## Table of Contents

1. [Joining the Lobby](#1-joining-the-lobby)
2. [Player Commands — Lobby Server](#2-player-commands--lobby-server)
3. [In-Match Commands — Match Server](#3-in-match-commands--match-server)
4. [Matchmaking Flow](#4-matchmaking-flow)
5. [Ready Check Phase](#5-ready-check-phase)
6. [ELO Ranking System](#6-elo-ranking-system)
7. [Web Panel](#7-web-panel)
8. [Admin Panel](#8-admin-panel)
9. [In-Game Admin Commands](#9-in-game-admin-commands)
10. [Lobby Management](#10-lobby-management)

---

## 1. Joining the Lobby

The lobby is the entry point for all matches. Connect via the CS:GO console (`~` key):

```
connect YOUR_SERVER_IP:27015
```

Once connected, all matchmaking commands are entered in the **in-game chat** (default key `Y`).

> A **5-second cooldown** applies between most command uses to prevent spam.

---

## 2. Player Commands — Lobby Server

### Queue

| Command | Description |
|---------|-------------|
| `!queue` / `!q` | Join the matchmaking queue with no map preference |
| `!queue <map>` | Join with a map preference (e.g. `!queue de_mirage`) |
| `!leave` / `!unqueue` | Leave the queue |
| `!status` | Show your position in queue, elapsed wait time, and estimated match time |

**Map identifiers:**

| Identifier    | Display name |
|---------------|--------------|
| `de_dust2`    | Dust II      |
| `de_mirage`   | Mirage       |
| `de_inferno`  | Inferno      |
| `de_ancient`  | Ancient      |
| `de_nuke`     | Nuke         |
| `de_overpass` | Overpass     |
| `de_vertigo`  | Vertigo      |

### Stats and Rankings

| Command | Description |
|---------|-------------|
| `!rank` | Your current ELO rating, rank tier, W/L ratio, and K/D |
| `!top` | Top 10 players sorted by ELO |
| `!stats` | Detailed career stats: kills, deaths, assists, headshots, streaks, win rate |
| `!lastmatch` | Summary of your most recent match (map, score, K/D/A, ELO change) |
| `!recent` | Players from your last 5 matches with their ranks |

**Example `!rank` output:**
```
[MM] YourName | Rank: Master Guardian I | ELO: 1042 | W/L: 18/12 | K/D: 1.24
```

**Example `!lastmatch` output:**
```
[MM] Last match on de_mirage — 16-9 (Win) | 22K 14D 5A | +24 ELO (1024 → 1048)
```

### Party & Social

| Command | Description |
|---------|-------------|
| `!party` | Show your current party and members' ELO |
| `!party invite <name>` | Create a party (if you have none) and invite a player |
| `!party accept` | Accept a pending party invitation |
| `!party decline` | Decline a pending party invitation |
| `!party leave` | Leave your current party (leadership transfers to the next member) |
| `!party kick <name>` | Kick a member from your party (leader only) |
| `!avoid <name>` | Avoid a player for 7 days — they won't be matched with you (max 10 active) |
| `!avoidlist` | List your active avoids |

**Party rules:**
- Maximum 5 members per party
- Maximum 400 ELO gap between any two party members
- Only the party **leader** can start the queue — all members join together
- If any member is banned from matchmaking, the queue is blocked until the ban expires
- If the leader declines the ready check, all party members are removed from the queue (no penalty)

---

## 3. In-Match Commands — Match Server

These commands are only available on the **match server** (after being redirected from the lobby).

| Command | Description |
|---------|-------------|
| `!ff` / `!surrender` | Start a surrender vote for your team |
| `!pause` | Request a tactical timeout at the next freeze time |
| `!unpause` | Signal your team is ready to resume (both teams must confirm) |
| `!report <name>` | Report a player for misconduct during the match |

### Surrender vote (`!ff`)

- Requires **4/5** of your team to vote yes (or **3/4** if a teammate has already abandoned)
- Surrender is a **unconditional loss** regardless of the current score — the surrendering team loses ELO as if they lost
- Once your team surrenders, the opposing team wins and ELO is calculated accordingly
- **Cooldown**: 2 minutes between surrender vote attempts
- **Vote window**: 30 seconds

### Tactical pause (`!pause`)

- Each team has **1 pause** per match (configurable via admin panel)
- Pause takes effect at the **next freeze time** (end of current round)
- **Maximum pause duration**: 60 seconds, then the match resumes automatically
- Both teams must type `!unpause` to resume early
- Announcement: `[MM] Tactical timeout called by Team X (Y pauses remaining)`

### Player report (`!report`)

- Available during any live or overtime round
- Opens a menu to select a reason: **Cheating** / **Griefing** / **AFK** / **Toxic behavior**
- One report per reporter/reported pair per match (duplicates are ignored)
- Reports are reviewed by admins in the web panel at `/admin/reports`
- Confirmation: `[MM] Report submitted against PlayerX`

---

## 4. Matchmaking Flow

```
Player → connect IP:27015
         ↓
    CS:GO Lobby Server
         ↓
    !queue [map_preference]
         ↓
    Queue (mm_queue table, status = waiting)
         ↓
    Matchmaker finds 10 ELO-compatible players
         (avoid-list conflicts are checked and resolved before ready check)
         ↓
    Ready Check (30 seconds)
         ↓
    All players accept
         ↓
    Docker container launched on an available port
         ↓
    All 10 players connected to match server via ServerRedirect
         ↓
    Warmup phase (max 180s to allow all players to connect)
         ↓
    Map vote (20 seconds — players vote from the active map pool)
         ↓
    Knife round (1 round, knives only — winner picks CT or T)
         ↓
    Competitive MR12 match (with possible overtime)
         ↓
    Match ends → stats saved, ELO calculated
         ↓
    Post-match scoreboard shown in chat (15 seconds)
         ↓
    All players redirected back to lobby
```

**Team formation (ELO snake draft):**

The 10 players are sorted by ELO descending, then distributed in snake order:
- Pick 1 → Team A, Pick 2 → Team B, Pick 3 → Team B, Pick 4 → Team A, Pick 5 → Team A, …

This ensures balanced skill distribution between both teams.

**Avoid-list check:**

Before sending the ready check, the matchmaker verifies that no two players in the candidate group have each other on their avoid lists. If a conflict is found, the more recently queued of the two is replaced and the process retries.

---

## 5. Ready Check Phase

When 10 compatible players are found, each player's screen shows a confirmation panel:
- **Map** selected for the match
- **30-second countdown**

**Click ACCEPT** to confirm participation.

**If you click DECLINE or the timer expires:**
- You are **removed from the queue** — no ban, no penalty
- Other players who accepted are automatically returned to the queue with their original timestamp (their position is preserved)

**If you are in a party and your teammate declines:**
- All party members are removed from the queue
- You receive: `[MM] Your teammate X declined. You have been removed from the queue.`
- No penalty for any party member

> **Tip**: If you need to step away, type `!leave` before the ready check triggers rather than letting it expire.

---

## 6. ELO Ranking System

### Starting Out

Every new player begins with an ELO of **1000** (Master Guardian I) and enters a **placement period** of 10 matches with higher ELO volatility.

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

| Situation | K-Factor | Effect |
|-----------|----------|--------|
| Placement matches (< 10 matches) | **64** | Large swings for fast positioning |
| Established (10–30 matches) | **32** | Standard swings |
| Veteran (> 30 matches) | **24** | Smaller swings for greater stability |

### Special ELO rules

- **Abandoning** a live match: ELO is calculated as a loss regardless of your team's result, plus a progressive matchmaking ban (30 min → 7 days)
- **Surrendering**: the surrendering team loses ELO as a defeat, independent of the score at the time of surrender
- **Placement matches**: ELO swings faster so new players reach their correct tier quickly

---

## 7. Web Panel

The web panel is at `http://YOUR_SERVER_IP:5000` (or the port configured during installation).

### Public pages

| URL | Description |
|-----|-------------|
| `/` | Landing page — live stats (players in queue, active matches), top players, recent matches, how-to guide |
| `/leaderboard` | Full ELO leaderboard, paginated, filterable by season |
| `/matches` | List of all completed matches |
| `/match/<id>` | Full CS:GO-style scoreboard for one match, with ELO changes |
| `/player/<steam_id>` | Player profile — ELO history chart, career stats, match history |

### Signing in

Click **Login** in the top-right corner. You are redirected to Steam's official OpenID login page. After authenticating, you return to your personal dashboard.

> No account creation — your identity comes from your Steam account. No password is stored on this server.

### Player dashboard

After signing in, `/dashboard` shows:
- Current rank badge and ELO rating
- Win/Loss/Tie record with colour bar
- Win rate and K/D ratio
- ELO trend sparkline (last 20 data points)
- Your 10 most recent matches with map, result, and ELO change

### REST API

JSON endpoints for external integrations (Discord bots, dashboards):

| Endpoint | Description |
|----------|-------------|
| `GET /api/queue/count` | Number of players currently in queue |
| `GET /api/player/<steam_id>` | Player profile in JSON (ELO, rank, stats) |
| `GET /api/leaderboard` | Full leaderboard in JSON (`?season=N` filter available) |
| `GET /api/matches` | Recent matches in JSON |

---

## 8. Admin Panel

### Accessing the admin panel

1. Sign in to the web panel with your Steam account (click **Login**)
2. If your Steam ID is in the `mm_admins` table, an **⚙ Admin** button appears in the navbar
3. Click **⚙ Admin** to enter `/admin/`

> If you see the public panel but no Admin button, your Steam ID is not yet registered. Ask an existing superadmin to add you via `/admin/admins`, or set `SUPER_ADMIN_STEAM_ID` in `config.env` and restart `csgo-webpanel`.

### Role hierarchy

| Role | Permissions |
|------|-------------|
| `moderator` | View dashboard, manage bans, dismiss reports |
| `admin` | All moderator actions + override player ELO |
| `superadmin` | All admin actions + manage admins, manage seasons |

### Admin pages

| URL | Role required | Description |
|-----|---------------|-------------|
| `/admin/` | moderator+ | Live dashboard: active matches, queue count, ban count |
| `/admin/bans` | moderator+ | View, issue, and remove matchmaking bans |
| `/admin/reports` | moderator+ | Review player reports (3+ unique reporters in 30 days) |
| `/admin/setelo` | admin+ | Manually override a player's ELO rating |
| `/admin/admins` | superadmin | Add, remove, and change admin roles |
| `/admin/seasons` | superadmin | Start a new competitive season with soft ELO reset |

### Ban management

- Ban by Steam ID (`STEAM_0:X:Y`) with a reason and duration in minutes (`0` = permanent)
- Unban immediately from the same page
- The system also issues **automatic bans** for match abandonment (progressive: 30 min → 2h → 24h → 7 days → 30 days)

---

## 9. In-Game Admin Commands

Admin commands in the lobby server require the **ADMFLAG_ROOT** SourceMod flag. They are entered in the in-game chat.

> Admin flags are granted automatically to players whose Steam ID appears in `mm_admins`. Manage admins through the web panel at `/admin/admins`.

| Command | Description |
|---------|-------------|
| `!mm_forcestart` | Force-start a match with players currently in queue (minimum 2) |
| `!mm_cancelqueue` | Cancel all waiting queue entries |
| `!mm_ban <#userid\|name> <minutes> <reason>` | Ban a player from matchmaking |
| `!mm_unban <STEAM_X:Y:Z>` | Remove a matchmaking ban |
| `!mm_setelo <#userid\|name> <elo>` | Manually set a player's ELO (0–9999) |
| `!mm_resetrank <#userid\|name>` | Reset a player's ELO to 1000 and restart placement |
| `!mm_status` | Live summary: active matches, queue counts, active servers |

**Examples:**
```
!mm_ban #42 30 Toxic behaviour
!mm_unban STEAM_0:1:12345678
!mm_setelo TopFragger 1800
!mm_resetrank #7
!mm_forcestart
```

> All admin commands are logged in SourceMod logs with the acting administrator's identity.

---

## 10. Lobby Management

### AFK detection

A player who remains in **spectator for 5 consecutive minutes** is automatically removed from the queue. They receive a chat notification and can re-queue by joining a team and typing `!queue`.

### Queue expiry

Queue entries expire after **15 minutes** if no match forms. The player is notified and must re-queue. This prevents orphaned database entries from silent disconnections.

### Automatic broadcast

Every **2 minutes**, the lobby server broadcasts the current queue count to all connected players:

```
[MM] 6 player(s) in queue! Type !queue to join!
```

### Stuck match recovery

If a match container becomes unreachable:

```bash
# Find the stuck container
docker ps --filter "name=csgo-match-"

# Stop it manually
docker stop csgo-match-<ID>

# Release the stuck DB entries (the matchmaker cleans up automatically within ~30s)
# Or clear the queue manually if needed:
# !mm_cancelqueue (in-game, as admin)
```

---

*Last updated: 2026-03-08*
