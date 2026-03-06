/**
 * csgo_mm_queue.sp — CS:GO Matchmaking Queue Plugin
 *
 * Main queue management plugin for the lobby server.
 * Handles: joining/leaving queue, ready checks, match assignment polling,
 * rank/stats display, anti-AFK enforcement, and periodic announcements.
 *
 * Compile: spcomp csgo_mm_queue.sp -i scripting/include
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <csgo_mm>

// ─────────────────────────────────────────────────────────────────────────────
// Plugin metadata
// ─────────────────────────────────────────────────────────────────────────────

public Plugin myinfo = {
    name        = "CS:GO Matchmaking - Queue",
    author      = "CSGO-MM",
    description = "Lobby queue management, ready checks, and match redirection",
    version     = MM_VERSION,
    url         = ""
};

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

#define READY_CHECK_TIMEOUT      30    // seconds before ready check expires
#define CMD_RATE_LIMIT           5.0   // seconds between repeated command uses
#define AFK_SPEC_TIMEOUT         300   // 5 minutes in spectator → auto-dequeue
#define QUEUE_EXPIRE_MINUTES     15    // minutes before a waiting entry is expired
#define DECLINE_BAN_MINUTES      5     // minutes ban for declining ready check
#define POLL_INTERVAL            2.0   // seconds between match-assignment polls
#define EXPIRE_INTERVAL          30.0  // seconds between stale-queue sweeps
#define AFK_INTERVAL             60.0  // seconds between AFK checks
#define ANNOUNCE_INTERVAL        120.0 // seconds between broadcast queue announcements

// ─────────────────────────────────────────────────────────────────────────────
// Per-client state
// ─────────────────────────────────────────────────────────────────────────────

bool  g_bQueued      [MAXPLAYERS + 1]; // true while player has a 'waiting' or 'ready_check' DB row
bool  g_bReadyCheck  [MAXPLAYERS + 1]; // true while ready-check panel is active for this player
int   g_iReadyMatchId[MAXPLAYERS + 1]; // match_id associated with the current ready check
int   g_iReadyTimer  [MAXPLAYERS + 1]; // countdown seconds remaining on ready check
int   g_iElo         [MAXPLAYERS + 1]; // cached ELO from mm_players
int   g_iRank        [MAXPLAYERS + 1]; // cached rank_tier from mm_players
char  g_sMatchIP     [MAXPLAYERS + 1][64]; // match server IP (set when status='matched')
int   g_iMatchPort   [MAXPLAYERS + 1]; // match server port
char  g_sMatchPW     [MAXPLAYERS + 1][32]; // match server password
float g_fLastCmd     [MAXPLAYERS + 1]; // GetEngineTime() of last command use (rate limit)
float g_fSpecSince   [MAXPLAYERS + 1]; // GetEngineTime() when player moved to spectator

// ─────────────────────────────────────────────────────────────────────────────
// Globals
// ─────────────────────────────────────────────────────────────────────────────

Database g_hDB = null;

// ─────────────────────────────────────────────────────────────────────────────
// Plugin start / end
// ─────────────────────────────────────────────────────────────────────────────

public void OnPluginStart()
{
    // Attempt async database connection
    Database.Connect(DB_Connected, MM_DB_NAME);

    // ── Player commands ───────────────────────────────────────────────────────
    RegConsoleCmd("sm_queue",   Cmd_Queue,   "Join the matchmaking queue");
    RegConsoleCmd("sm_q",       Cmd_Queue,   "Join the matchmaking queue (alias)");
    RegConsoleCmd("sm_leave",   Cmd_Leave,   "Leave the matchmaking queue");
    RegConsoleCmd("sm_unqueue", Cmd_Leave,   "Leave the matchmaking queue (alias)");
    RegConsoleCmd("sm_status",  Cmd_Status,  "Show your current queue status");
    RegConsoleCmd("sm_rank",    Cmd_Rank,    "Display your competitive rank and ELO");
    RegConsoleCmd("sm_top",     Cmd_Top,     "Show top 10 players by ELO");
    RegConsoleCmd("sm_stats",   Cmd_Stats,   "Show your detailed match statistics");

    // ── Game events ──────────────────────────────────────────────────────────
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("player_team",       Event_PlayerTeam,       EventHookMode_Post);

    // ── Repeating timers ─────────────────────────────────────────────────────
    CreateTimer(POLL_INTERVAL,     Timer_PollMatchAssignment, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(EXPIRE_INTERVAL,   Timer_ExpireStaleQueue,    _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(AFK_INTERVAL,      Timer_AntiAFK,             _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(ANNOUNCE_INTERVAL, Timer_AnnounceQueue,       _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    LogMessage("[MM] Queue plugin loaded (v%s)", MM_VERSION);
}

public void OnPluginEnd()
{
    delete g_hDB;
}

// ─────────────────────────────────────────────────────────────────────────────
// Database connection callback
// ─────────────────────────────────────────────────────────────────────────────

public void DB_Connected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[MM] Database connection failed: %s", error);
        return;
    }

    g_hDB = db;
    g_hDB.SetCharset("utf8mb4");
    LogMessage("[MM] Database connected successfully.");
}

// ─────────────────────────────────────────────────────────────────────────────
// Client lifecycle
// ─────────────────────────────────────────────────────────────────────────────

public void OnClientDisconnect(int client)
{
    ResetClientState(client);
}

// Reset all per-client arrays to defaults
void ResetClientState(int client)
{
    g_bQueued      [client] = false;
    g_bReadyCheck  [client] = false;
    g_iReadyMatchId[client] = 0;
    g_iReadyTimer  [client] = 0;
    g_iElo         [client] = 0;
    g_iRank        [client] = 0;
    g_sMatchIP     [client][0] = '\0';
    g_iMatchPort   [client] = 0;
    g_sMatchPW     [client][0] = '\0';
    g_fLastCmd     [client] = 0.0;
    g_fSpecSince   [client] = 0.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Events
// ─────────────────────────────────────────────────────────────────────────────

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    #pragma unused name, dontBroadcast
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!MM_IsValidClient(client))
        return Plugin_Continue;

    if (!g_bQueued[client])
        return Plugin_Continue;

    if (g_hDB == null)
        return Plugin_Continue;

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    // Cancel any active queue entry on disconnect
    char query[512];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_queue SET status='cancelled' WHERE steam_id='%s' AND status IN ('waiting','ready_check')",
        steamID);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);

    ResetClientState(client);
    return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    #pragma unused name, dontBroadcast
    // Track when a player moves to spectator for AFK detection
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!MM_IsValidClient(client))
        return Plugin_Continue;

    int newTeam = event.GetInt("team");
    if (newTeam == CS_TEAM_SPECTATOR)
        g_fSpecSince[client] = GetEngineTime();
    else
        g_fSpecSince[client] = 0.0; // reset on team join

    return Plugin_Continue;
}

// Generic callback for fire-and-forget queries (logs errors only)
public void DB_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null || error[0] != '\0')
        LogError("[MM] DB query error: %s", error);
}

// ─────────────────────────────────────────────────────────────────────────────
// !queue / !q — Join the matchmaking queue
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Queue(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    // ── Rate limit ────────────────────────────────────────────────────────────
    float now = GetEngineTime();
    if ((now - g_fLastCmd[client]) < CMD_RATE_LIMIT)
    {
        MM_WarnToChat(client, "Please wait before using this command again.");
        return Plugin_Handled;
    }
    g_fLastCmd[client] = now;

    // ── Already queued? ───────────────────────────────────────────────────────
    if (g_bQueued[client])
    {
        MM_WarnToChat(client, "You are already in the queue. Type \x04!leave\x01 to cancel.");
        return Plugin_Handled;
    }

    if (g_hDB == null)
    {
        MM_ErrorToChat(client, "Matchmaking service is currently unavailable. Try again shortly.");
        return Plugin_Handled;
    }

    // ── Optional map preference ───────────────────────────────────────────────
    char mapPref[32];
    mapPref[0] = '\0';
    if (args >= 1)
    {
        GetCmdArg(1, mapPref, sizeof(mapPref));
        // Sanitise: only allow lowercase alphanumeric and underscore
        for (int i = 0; i < strlen(mapPref); i++)
        {
            char c = mapPref[i];
            if (!IsCharAlpha(c) && !IsCharNumeric(c) && c != '_')
            {
                mapPref[0] = '\0';
                break;
            }
        }
    }

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    // Pack client index and map preference into a DataPack for the callback chain
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(mapPref);

    // Step 1: Check ban status
    char query[512];
    g_hDB.Format(query, sizeof(query),
        "SELECT is_banned, ban_until FROM mm_players WHERE steam_id='%s' AND is_banned=1 AND ban_until > NOW() LIMIT 1",
        steamID);
    g_hDB.Query(DB_CheckBan, query, pack, DBPrio_High);

    return Plugin_Handled;
}

// Step 1 result: ban check
public void DB_CheckBan(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid   = pack.ReadCell();
    char mapPref[32];
    pack.ReadString(mapPref, sizeof(mapPref));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client))
        return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_CheckBan error: %s", error);
        MM_ErrorToChat(client, "Database error checking ban status.");
        return;
    }

    if (results.RowCount > 0)
    {
        // Player is banned
        results.FetchRow();
        char banUntil[32];
        results.FetchString(1, banUntil, sizeof(banUntil));
        MM_ErrorToChat(client,
            "\x07You are banned from matchmaking until \x09%s\x01.", banUntil);
        return;
    }

    // Step 2: Upsert player record into mm_players
    char steamID[32];
    char name[64];
    char escapedName[129]; // 2× name + null
    MM_GetSteamID(client, steamID, sizeof(steamID));
    GetClientName(client, name, sizeof(name));

    // Escape the name for safe SQL insertion
    char escapedSteamID[65];
    db.Escape(steamID, escapedSteamID, sizeof(escapedSteamID));
    db.Escape(name,    escapedName,    sizeof(escapedName));

    // Retrieve Steam64 ID for the record
    char steam64Str[32];
    GetClientAuthId(client, AuthId_SteamID64, steam64Str, sizeof(steam64Str));

    DataPack pack2 = new DataPack();
    pack2.WriteCell(userid);
    pack2.WriteString(mapPref);

    char query[768];
    db.Format(query, sizeof(query),
        "INSERT INTO mm_players (steam_id, steam_id64, name, elo, rank_tier) VALUES ('%s', %s, '%s', 1000, 5) ON DUPLICATE KEY UPDATE name='%s', last_queue=NOW()",
        escapedSteamID, steam64Str, escapedName, escapedName);
    g_hDB.Query(DB_UpsertPlayer, query, pack2, DBPrio_High);
}

// Step 2 result: player upserted — now INSERT into mm_queue
public void DB_UpsertPlayer(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    char mapPref[32];
    pack.ReadString(mapPref, sizeof(mapPref));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client))
        return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_UpsertPlayer error: %s", error);
        MM_ErrorToChat(client, "Database error registering player.");
        return;
    }

    // Fetch the player's current ELO and rank from the freshly-upserted row
    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    DataPack pack2 = new DataPack();
    pack2.WriteCell(userid);
    pack2.WriteString(mapPref);

    char query[256];
    g_hDB.Format(query, sizeof(query),
        "SELECT elo, rank_tier FROM mm_players WHERE steam_id='%s' LIMIT 1",
        steamID);
    g_hDB.Query(DB_FetchElo, query, pack2, DBPrio_High);
}

// Step 3 result: got ELO — insert queue entry
public void DB_FetchElo(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    char mapPref[32];
    pack.ReadString(mapPref, sizeof(mapPref));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client))
        return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_FetchElo error: %s", error);
        MM_ErrorToChat(client, "Database error fetching ELO.");
        return;
    }

    int elo       = 1000;
    int rankTier  = 5;
    if (results.FetchRow())
    {
        elo      = results.FetchInt(0);
        rankTier = results.FetchInt(1);
    }

    g_iElo [client] = elo;
    g_iRank[client] = rankTier;

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    // INSERT queue entry; use INSERT IGNORE so a race-condition double-click
    // doesn't create a duplicate (the UNIQUE KEY on steam_id+status protects us).
    DataPack pack2 = new DataPack();
    pack2.WriteCell(userid);

    char query[512];
    if (mapPref[0] != '\0')
    {
        char escapedMap[65];
        db.Escape(mapPref, escapedMap, sizeof(escapedMap));
        g_hDB.Format(query, sizeof(query),
            "INSERT IGNORE INTO mm_queue (steam_id, elo, rank_tier, status, map_preference) VALUES ('%s', %d, %d, 'waiting', '%s')",
            steamID, elo, rankTier, escapedMap);
    }
    else
    {
        g_hDB.Format(query, sizeof(query),
            "INSERT IGNORE INTO mm_queue (steam_id, elo, rank_tier, status) VALUES ('%s', %d, %d, 'waiting')",
            steamID, elo, rankTier);
    }
    g_hDB.Query(DB_QueueInserted, query, pack2, DBPrio_High);
}

// Step 4 result: queue row inserted — tell the player
public void DB_QueueInserted(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client))
        return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_QueueInserted error: %s", error);
        MM_ErrorToChat(client, "Failed to join queue. Are you already queued?");
        return;
    }

    // affectedRows == 0 means INSERT IGNORE silently skipped (already queued)
    if (results.AffectedRows == 0)
    {
        MM_WarnToChat(client, "You are already in the queue. Type \x04!leave\x01 to cancel.");
        return;
    }

    g_bQueued[client] = true;

    // Fetch queue count for the confirmation message
    g_hDB.Query(DB_QueueCount, "SELECT COUNT(*) FROM mm_queue WHERE status='waiting'",
        GetClientUserId(client), DBPrio_Normal);
}

public void DB_QueueCount(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);

    int count = 0;
    if (results != null && error[0] == '\0' && results.FetchRow())
        count = results.FetchInt(0);

    if (MM_IsValidClient(client))
    {
        char rankName[48];
        MM_GetRankName(g_iRank[client], rankName, sizeof(rankName));

        MM_PrintToChat(client,
            "\x04You joined the queue! \x01(\x09%d\x01 player(s) waiting) | Rank: \x04%s\x01 | ELO: \x09%d\x01 | Type \x04!leave\x01 to cancel.",
            count, rankName, g_iElo[client]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !leave / !unqueue — Leave the matchmaking queue
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Leave(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    if (!g_bQueued[client] && !g_bReadyCheck[client])
    {
        MM_WarnToChat(client, "You are not in the queue.");
        return Plugin_Handled;
    }

    if (g_hDB == null)
    {
        MM_ErrorToChat(client, "Matchmaking service unavailable.");
        return Plugin_Handled;
    }

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    char query[512];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_queue SET status='cancelled' WHERE steam_id='%s' AND status IN ('waiting','ready_check')",
        steamID);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);

    ResetClientState(client);
    MM_PrintToChat(client, "You have left the queue.");
    return Plugin_Handled;
}

// ─────────────────────────────────────────────────────────────────────────────
// !status — Show queue status
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Status(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    if (!g_bQueued[client])
    {
        MM_PrintToChat(client, "You are \x07not\x01 in the queue. Type \x04!queue\x01 to join.");
        return Plugin_Handled;
    }

    if (g_bReadyCheck[client])
    {
        MM_PrintToChat(client,
            "\x09READY CHECK\x01 — accept or decline! \x09%d\x01s remaining.",
            g_iReadyTimer[client]);
        return Plugin_Handled;
    }

    MM_PrintToChat(client,
        "You are in the queue (\x04waiting\x01). ELO: \x09%d\x01 | Type \x04!leave\x01 to cancel.",
        g_iElo[client]);

    if (g_hDB == null)
        return Plugin_Handled;

    // Show live queue depth asynchronously
    g_hDB.Query(DB_StatusQueueCount,
        "SELECT COUNT(*) FROM mm_queue WHERE status='waiting'",
        GetClientUserId(client), DBPrio_Normal);

    return Plugin_Handled;
}

public void DB_StatusQueueCount(Database db, DBResultSet results, const char[] error, any userid)
{
    if (results == null || error[0] != '\0') return;
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results.FetchRow())
    {
        int count = results.FetchInt(0);
        MM_PrintToChat(client, "Players currently waiting: \x09%d\x01.", count);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !rank — Display competitive rank
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Rank(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    if (g_hDB == null)
    {
        MM_ErrorToChat(client, "Matchmaking service unavailable.");
        return Plugin_Handled;
    }

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    char query[512];
    g_hDB.Format(query, sizeof(query),
        "SELECT elo, rank_tier, matches_played, matches_won, matches_lost, total_kills, total_deaths FROM mm_players WHERE steam_id='%s' LIMIT 1",
        steamID);
    g_hDB.Query(DB_RankCallback, query, GetClientUserId(client), DBPrio_Normal);

    return Plugin_Handled;
}

public void DB_RankCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_RankCallback error: %s", error);
        MM_ErrorToChat(client, "Database error fetching rank.");
        return;
    }

    if (!results.FetchRow())
    {
        MM_PrintToChat(client, "No stats yet. Play a match first!");
        return;
    }

    int elo             = results.FetchInt(0);
    int tier            = results.FetchInt(1);
    int matchesPlayed   = results.FetchInt(2);
    int matchesWon      = results.FetchInt(3);
    int matchesLost     = results.FetchInt(4);
    int kills           = results.FetchInt(5);
    int deaths          = results.FetchInt(6);

    char rankName[48];
    MM_GetRankName(tier, rankName, sizeof(rankName));

    float kd = (deaths > 0) ? (float(kills) / float(deaths)) : float(kills);

    // Update cache
    g_iElo [client] = elo;
    g_iRank[client] = tier;

    MM_PrintToChat(client,
        "Rank: \x04%s\x01 | ELO: \x09%d\x01 | W/L: \x04%d\x01/\x07%d\x01 | K/D: \x04%.2f\x01",
        rankName, elo, matchesWon, matchesLost, kd);
}

// ─────────────────────────────────────────────────────────────────────────────
// !top — Top 10 leaderboard
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Top(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    if (g_hDB == null)
    {
        MM_ErrorToChat(client, "Matchmaking service unavailable.");
        return Plugin_Handled;
    }

    g_hDB.Query(DB_TopCallback,
        "SELECT name, elo, rank_tier, matches_played FROM mm_players WHERE matches_played >= 1 ORDER BY elo DESC LIMIT 10",
        GetClientUserId(client), DBPrio_Normal);

    return Plugin_Handled;
}

public void DB_TopCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_TopCallback error: %s", error);
        MM_ErrorToChat(client, "Database error fetching leaderboard.");
        return;
    }

    if (results.RowCount == 0)
    {
        MM_PrintToChat(client, "No ranked players yet. Be the first!");
        return;
    }

    PrintToChat(client, "\x04 ─── Top 10 Players by ELO ───");
    int pos = 1;
    while (results.FetchRow())
    {
        char playerName[64];
        results.FetchString(0, playerName, sizeof(playerName));
        int elo            = results.FetchInt(1);
        int tier           = results.FetchInt(2);
        int matchesPlayed  = results.FetchInt(3);

        char rankName[48];
        MM_GetRankName(tier, rankName, sizeof(rankName));

        // Gold medal for top 3
        char medal[4];
        if      (pos == 1) strcopy(medal, sizeof(medal), "#1");
        else if (pos == 2) strcopy(medal, sizeof(medal), "#2");
        else if (pos == 3) strcopy(medal, sizeof(medal), "#3");
        else Format(medal, sizeof(medal), "#%d", pos);

        PrintToChat(client,
            " \x09%s\x01 \x04%s\x01 — \x09%s\x01 (ELO: \x04%d\x01, %d games)",
            medal, playerName, rankName, elo, matchesPlayed);
        pos++;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !stats — Detailed personal statistics
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Stats(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    if (g_hDB == null)
    {
        MM_ErrorToChat(client, "Matchmaking service unavailable.");
        return Plugin_Handled;
    }

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    char query[512];
    g_hDB.Format(query, sizeof(query),
        "SELECT elo, rank_tier, matches_played, matches_won, matches_lost, matches_tied, total_kills, total_deaths, total_assists, total_headshots, win_streak, best_streak FROM mm_players WHERE steam_id='%s' LIMIT 1",
        steamID);
    g_hDB.Query(DB_StatsCallback, query, GetClientUserId(client), DBPrio_Normal);

    return Plugin_Handled;
}

public void DB_StatsCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_StatsCallback error: %s", error);
        MM_ErrorToChat(client, "Database error fetching stats.");
        return;
    }

    if (!results.FetchRow())
    {
        MM_PrintToChat(client, "No stats found. Play a match first!");
        return;
    }

    int elo           = results.FetchInt(0);
    int tier          = results.FetchInt(1);
    int played        = results.FetchInt(2);
    int won           = results.FetchInt(3);
    int lost          = results.FetchInt(4);
    int tied          = results.FetchInt(5);
    int kills         = results.FetchInt(6);
    int deaths        = results.FetchInt(7);
    int assists       = results.FetchInt(8);
    int headshots     = results.FetchInt(9);
    int streak        = results.FetchInt(10);
    int bestStreak    = results.FetchInt(11);

    char rankName[48];
    MM_GetRankName(tier, rankName, sizeof(rankName));

    float kd      = (deaths > 0)  ? (float(kills)      / float(deaths)) : float(kills);
    float hsPct   = (kills  > 0)  ? (float(headshots)  / float(kills) * 100.0) : 0.0;
    float winRate = (played > 0)  ? (float(won)         / float(played) * 100.0) : 0.0;

    char playerName[64];
    GetClientName(client, playerName, sizeof(playerName));

    PrintToChat(client, "\x04 ─── Stats: %s ───", playerName);
    PrintToChat(client, " Rank: \x04%s\x01 | ELO: \x09%d", rankName, elo);
    PrintToChat(client, " Matches: \x09%d\x01 | W/L/T: \x04%d\x01/\x07%d\x01/\x01%d", played, won, lost, tied);
    PrintToChat(client, " Win Rate: \x04%.1f%%\x01 | K/D: \x04%.2f\x01 | HS%%: \x09%.1f%%", winRate, kd, hsPct);
    PrintToChat(client, " Kills: \x04%d\x01 | Deaths: \x07%d\x01 | Assists: \x04%d", kills, deaths, assists);
    PrintToChat(client, " Headshots: \x09%d\x01 | Win Streak: \x04%d\x01 | Best Streak: \x04%d", headshots, streak, bestStreak);
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: Poll for match assignment (every 2s)
// ─────────────────────────────────────────────────────────────────────────────

public Action Timer_PollMatchAssignment(Handle timer)
{
    if (g_hDB == null)
        return Plugin_Continue;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!MM_IsValidClient(client))
            continue;
        if (!g_bQueued[client])
            continue;

        char steamID[32];
        MM_GetSteamID(client, steamID, sizeof(steamID));

        char query[512];
        g_hDB.Format(query, sizeof(query),
            "SELECT status, match_id FROM mm_queue WHERE steam_id='%s' AND status IN ('waiting','ready_check','matched') ORDER BY id DESC LIMIT 1",
            steamID);
        g_hDB.Query(DB_PollResult, query, GetClientUserId(client), DBPrio_High);
    }

    return Plugin_Continue;
}

// Callback: received queue status for one player
public void DB_PollResult(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_PollResult error: %s", error);
        return;
    }

    if (!results.FetchRow())
    {
        // Row disappeared — entry was cancelled/expired externally
        if (g_bQueued[client])
        {
            ResetClientState(client);
            MM_WarnToChat(client, "Your queue entry was cancelled or expired.");
        }
        return;
    }

    char status[32];
    results.FetchString(0, status, sizeof(status));
    int matchId = results.FetchInt(1);

    if (StrEqual(status, QUEUE_STATUS_READY_CHECK) && !g_bReadyCheck[client])
    {
        // The matchmaker promoted this player to ready_check — show the panel
        // We need the map name from mm_matches; fetch it separately
        DataPack pack = new DataPack();
        pack.WriteCell(userid);
        pack.WriteCell(matchId);

        char query[256];
        g_hDB.Format(query, sizeof(query),
            "SELECT map_name FROM mm_matches WHERE id=%d LIMIT 1",
            matchId);
        g_hDB.Query(DB_FetchMapForReadyCheck, query, pack, DBPrio_High);
    }
    else if (StrEqual(status, QUEUE_STATUS_MATCHED) && g_bQueued[client])
    {
        // Match confirmed — fetch server details and redirect
        char steamID[32];
        MM_GetSteamID(client, steamID, sizeof(steamID));

        DataPack pack = new DataPack();
        pack.WriteCell(userid);
        pack.WriteCell(matchId);

        char query[512];
        g_hDB.Format(query, sizeof(query),
            "SELECT m.server_ip, m.server_port, m.server_password FROM mm_matches m WHERE m.id=%d AND m.status IN ('creating','warmup','live') LIMIT 1",
            matchId);
        g_hDB.Query(DB_FetchMatchServer, query, pack, DBPrio_High);
    }
}

// Got map name for the ready check panel
public void DB_FetchMapForReadyCheck(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid  = pack.ReadCell();
    int matchId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    char mapName[32];
    strcopy(mapName, sizeof(mapName), "Unknown");

    if (results != null && error[0] == '\0' && results.FetchRow())
        results.FetchString(0, mapName, sizeof(mapName));

    ShowReadyCheck(client, matchId, mapName);
}

// Got match server details — redirect player
public void DB_FetchMatchServer(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid  = pack.ReadCell();
    int matchId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_FetchMatchServer error: %s", error);
        return;
    }

    if (!results.FetchRow())
    {
        LogError("[MM] No match server row for match_id=%d", matchId);
        return;
    }

    char ip[64];
    int  port;
    char password[32];
    results.FetchString(0, ip,       sizeof(ip));
    port = results.FetchInt(1);
    results.FetchString(2, password, sizeof(password));

    // Cache for display; then issue connect command
    strcopy(g_sMatchIP[client], sizeof(g_sMatchIP[]), ip);
    g_iMatchPort[client] = port;
    strcopy(g_sMatchPW[client], sizeof(g_sMatchPW[]), password);

    MM_PrintToChat(client,
        "\x04MATCH FOUND!\x01 Connecting to \x09%s:%d\x01 …", ip, port);

    // Give the message a moment to display, then redirect
    DataPack redirectPack = new DataPack();
    redirectPack.WriteCell(userid);
    CreateTimer(1.5, Timer_RedirectPlayer, redirectPack, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RedirectPlayer(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return Plugin_Stop;

    ClientCommand(client, "connect %s:%d; password %s",
        g_sMatchIP[client], g_iMatchPort[client], g_sMatchPW[client]);

    ResetClientState(client);
    return Plugin_Stop;
}

// ─────────────────────────────────────────────────────────────────────────────
// ShowReadyCheck — Display accept/decline panel to a player
// ─────────────────────────────────────────────────────────────────────────────

void ShowReadyCheck(int client, int matchId, const char[] mapName)
{
    g_bReadyCheck  [client] = true;
    g_iReadyMatchId[client] = matchId;
    g_iReadyTimer  [client] = READY_CHECK_TIMEOUT;

    // Build and show the panel
    Panel panel = new Panel();

    char title[64];
    Format(title, sizeof(title), "MATCH FOUND!");
    panel.SetTitle(title);

    char mapLine[64];
    Format(mapLine, sizeof(mapLine), "Map: %s", mapName);
    panel.DrawText(mapLine);

    char timerLine[64];
    Format(timerLine, sizeof(timerLine), "You have %ds to respond.", READY_CHECK_TIMEOUT);
    panel.DrawText(timerLine);

    panel.DrawText(" ");
    panel.DrawItem("ACCEPT");
    panel.DrawItem("Decline");

    panel.Send(client, ReadyCheck_Handler, READY_CHECK_TIMEOUT);
    delete panel;

    // Start a 1-second countdown timer so we can update the HUD text
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(matchId);
    CreateTimer(1.0, Timer_ReadyCountdown, pack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// Panel button handler
public int ReadyCheck_Handler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        if (param2 == 1)
            ReadyCheck_Accept(client);
        else
            ReadyCheck_Decline(client);
    }
    else if (action == MenuAction_Cancel)
    {
        // Panel timed out or was closed without selection → treat as decline
        if (g_bReadyCheck[client])
            ReadyCheck_Decline(client);
    }

    return 0;
}

// Countdown timer fires every 1 second; updates HUD hint with time remaining
public Action Timer_ReadyCountdown(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid  = pack.ReadCell();
    int matchId = pack.ReadCell();

    int client = GetClientOfUserId(userid);

    // Stop if player left or ready check resolved
    if (!MM_IsValidClient(client) || !g_bReadyCheck[client] || g_iReadyMatchId[client] != matchId)
    {
        delete pack;
        return Plugin_Stop;
    }

    g_iReadyTimer[client]--;

    // Show countdown in HUD hint (visible even behind the panel)
    SetHudTextParams(-1.0, 0.15, 1.1, 255, 200, 50, 255);
    ShowHudText(client, 1, "MATCH FOUND! Accept or Decline\n%ds remaining", g_iReadyTimer[client]);

    if (g_iReadyTimer[client] <= 0)
    {
        // Timed out — auto-decline
        ReadyCheck_Decline(client);
        delete pack;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

void ReadyCheck_Accept(int client)
{
    if (!g_bReadyCheck[client]) return;
    g_bReadyCheck[client] = false; // prevent duplicate actions

    if (g_hDB == null) return;

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    char query[256];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_queue SET ready=1 WHERE steam_id='%s' AND status='ready_check'",
        steamID);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);

    MM_PrintToChat(client, "\x04You accepted the match!\x01 Waiting for others…");
}

void ReadyCheck_Decline(int client)
{
    if (!g_bReadyCheck[client] && !g_bQueued[client]) return;

    g_bReadyCheck[client] = false;

    if (g_hDB == null)
    {
        ResetClientState(client);
        return;
    }

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    // Cancel queue entry
    char query[512];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_queue SET status='cancelled' WHERE steam_id='%s' AND status='ready_check'",
        steamID);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);

    // Apply a short matchmaking ban for declining
    char banQuery[512];
    g_hDB.Format(banQuery, sizeof(banQuery),
        "INSERT INTO mm_bans (steam_id, reason, expires_at, banned_by) VALUES ('%s', 'Declined ready check', DATE_ADD(NOW(), INTERVAL %d MINUTE), 'system') ON DUPLICATE KEY UPDATE reason=VALUES(reason), expires_at=VALUES(expires_at), is_active=1",
        steamID, DECLINE_BAN_MINUTES);
    g_hDB.Query(DB_GenericCallback, banQuery, _, DBPrio_High);

    // Also update mm_players.is_banned so the ban-check query picks it up immediately
    char playerBanQuery[512];
    g_hDB.Format(playerBanQuery, sizeof(playerBanQuery),
        "UPDATE mm_players SET is_banned=1, ban_until=DATE_ADD(NOW(), INTERVAL %d MINUTE) WHERE steam_id='%s'",
        DECLINE_BAN_MINUTES, steamID);
    g_hDB.Query(DB_GenericCallback, playerBanQuery, _, DBPrio_High);

    ResetClientState(client);

    MM_WarnToChat(client,
        "\x07You declined the ready check.\x01 You are banned from matchmaking for \x09%d\x01 minute(s).",
        DECLINE_BAN_MINUTES);
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: Expire stale queue entries (every 30s)
// ─────────────────────────────────────────────────────────────────────────────

public Action Timer_ExpireStaleQueue(Handle timer)
{
    if (g_hDB == null)
        return Plugin_Continue;

    // Expire entries that have been waiting longer than QUEUE_EXPIRE_MINUTES
    char query[256];
    Format(query, sizeof(query),
        "UPDATE mm_queue SET status='expired' WHERE status='waiting' AND queued_at < DATE_SUB(NOW(), INTERVAL %d MINUTE)",
        QUEUE_EXPIRE_MINUTES);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_Low);

    // Sync in-game state for any player whose entry was just expired externally.
    // The next PollMatchAssignment pass will detect the missing row and reset them.
    return Plugin_Continue;
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: Anti-AFK (every 60s)
// ─────────────────────────────────────────────────────────────────────────────

public Action Timer_AntiAFK(Handle timer)
{
    float now = GetEngineTime();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!MM_IsValidClient(client))
            continue;
        if (!g_bQueued[client])
            continue;

        // Only act on players sitting in spectator
        if (GetClientTeam(client) != CS_TEAM_SPECTATOR)
        {
            g_fSpecSince[client] = 0.0;
            continue;
        }

        // First time we see them spectating: record the timestamp
        if (g_fSpecSince[client] < 1.0)
        {
            g_fSpecSince[client] = now;
            continue;
        }

        float elapsed = now - g_fSpecSince[client];
        if (elapsed >= float(AFK_SPEC_TIMEOUT))
        {
            // Auto-dequeue
            if (g_hDB != null)
            {
                char steamID[32];
                MM_GetSteamID(client, steamID, sizeof(steamID));

                char query[512];
                g_hDB.Format(query, sizeof(query),
                    "UPDATE mm_queue SET status='cancelled' WHERE steam_id='%s' AND status IN ('waiting','ready_check')",
                    steamID);
                g_hDB.Query(DB_GenericCallback, query, _, DBPrio_Normal);
            }

            ResetClientState(client);
            MM_WarnToChat(client,
                "\x09You were removed from the queue for being AFK in spectator.");
        }
    }

    return Plugin_Continue;
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: Announce queue count to all (every 120s)
// ─────────────────────────────────────────────────────────────────────────────

public Action Timer_AnnounceQueue(Handle timer)
{
    if (g_hDB == null)
        return Plugin_Continue;

    g_hDB.Query(DB_AnnounceQueueCount,
        "SELECT COUNT(*) FROM mm_queue WHERE status='waiting'",
        0, DBPrio_Low);

    return Plugin_Continue;
}

public void DB_AnnounceQueueCount(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null || error[0] != '\0') return;
    if (!results.FetchRow()) return;

    int count = results.FetchInt(0);
    if (count > 0)
    {
        MM_PrintToChatAll(
            "\x09%d\x01 player(s) in queue! Type \x04!queue\x01 to join competitive matchmaking.",
            count);
    }
}
