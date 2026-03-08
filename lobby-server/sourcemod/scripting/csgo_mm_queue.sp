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

#define PARTY_MAX_MEMBERS        5     // must match csgo_mm_party.sp

#define READY_CHECK_TIMEOUT      30    // seconds before ready check expires
#define CMD_RATE_LIMIT           5.0   // seconds between repeated command uses
#define AFK_SPEC_TIMEOUT         300   // 5 minutes in spectator → auto-dequeue
#define QUEUE_EXPIRE_MINUTES     15    // minutes before a waiting entry is expired
#define POLL_INTERVAL            2.0   // seconds between match-assignment polls
#define EXPIRE_INTERVAL          30.0  // seconds between stale-queue sweeps
#define AFK_INTERVAL             60.0  // seconds between AFK checks
#define ANNOUNCE_INTERVAL        120.0 // seconds between broadcast queue announcements
#define ELO_NOTIFY_DELAY         3.0   // seconds after connect before showing ELO recap
#define HUD_INTERVAL             2.0   // seconds between queue-status HUD refreshes

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
float g_fLastCmd        [MAXPLAYERS + 1]; // GetEngineTime() of last command use (rate limit)
float g_fSpecSince      [MAXPLAYERS + 1]; // GetEngineTime() when player moved to spectator
float g_fQueueStartTime [MAXPLAYERS + 1]; // GetEngineTime() when player joined queue (for HUD)

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
    RegConsoleCmd("sm_queue",     Cmd_Queue,     "Join the matchmaking queue");
    RegConsoleCmd("sm_q",         Cmd_Queue,     "Join the matchmaking queue (alias)");
    RegConsoleCmd("sm_leave",     Cmd_Leave,     "Leave the matchmaking queue");
    RegConsoleCmd("sm_unqueue",   Cmd_Leave,     "Leave the matchmaking queue (alias)");
    RegConsoleCmd("sm_status",    Cmd_Status,    "Show your current queue status");
    RegConsoleCmd("sm_rank",      Cmd_Rank,      "Display your competitive rank and ELO");
    RegConsoleCmd("sm_top",       Cmd_Top,       "Show top 10 players by ELO");
    RegConsoleCmd("sm_stats",     Cmd_Stats,     "Show your detailed match statistics");
    RegConsoleCmd("sm_lastmatch", Cmd_LastMatch, "Show a summary of your last match");
    RegConsoleCmd("sm_recent",    Cmd_Recent,    "Show players from your last 5 matches");
    RegConsoleCmd("sm_avoid",     Cmd_Avoid,     "Avoid a player for 7 days: !avoid <name>");
    RegConsoleCmd("sm_avoidlist", Cmd_AvoidList, "Show your current avoid list");

    // ── Game events ──────────────────────────────────────────────────────────
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("player_team",       Event_PlayerTeam,       EventHookMode_Post);

    // ── Repeating timers ─────────────────────────────────────────────────────
    CreateTimer(POLL_INTERVAL,     Timer_PollMatchAssignment, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(EXPIRE_INTERVAL,   Timer_ExpireStaleQueue,    _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(AFK_INTERVAL,      Timer_AntiAFK,             _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(ANNOUNCE_INTERVAL, Timer_AnnounceQueue,       _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(HUD_INTERVAL,      Timer_UpdateHUD,           _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

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

public void OnClientPostAdminCheck(int client)
{
    if (!MM_IsValidClient(client))
        return;
    if (g_hDB == null)
        return;

    // Delay slightly so the player's chat panel is ready to receive messages.
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    CreateTimer(ELO_NOTIFY_DELAY, Timer_CheckEloNotification, pack, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckEloNotification(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client))
        return Plugin_Stop;

    if (g_hDB == null)
        return Plugin_Stop;

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    // Fetch the most recent match with an unnotified ELO change for this player.
    char query[768];
    g_hDB.Format(query, sizeof(query),
        "SELECT mp.elo_before, mp.elo_after, mp.elo_change, mp.team, "
        "       m.team1_score, m.team2_score, m.winner, mp.id, p.rank_tier "
        "FROM mm_match_players mp "
        "JOIN mm_matches m  ON m.id  = mp.match_id "
        "JOIN mm_players p  ON p.steam_id = mp.steam_id "
        "WHERE mp.steam_id = '%s' "
        "  AND mp.elo_notified = 0 "
        "  AND mp.elo_change IS NOT NULL "
        "  AND m.status = 'finished' "
        "ORDER BY m.ended_at DESC LIMIT 1",
        steamID);
    g_hDB.Query(DB_RecentEloResult, query, GetClientUserId(client), DBPrio_Normal);

    return Plugin_Stop;
}

public void DB_RecentEloResult(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_RecentEloResult error: %s", error);
        return;
    }

    if (!results.FetchRow())
        return; // No unnotified match — nothing to show.

    int  eloBefore = results.FetchInt(0);
    int  eloAfter  = results.FetchInt(1);
    int  eloChange = results.FetchInt(2);
    char team[8];
    results.FetchString(3, team, sizeof(team));
    int  t1Score   = results.FetchInt(4);
    int  t2Score   = results.FetchInt(5);
    char winner[8];
    results.FetchString(6, winner, sizeof(winner));
    int  mpId      = results.FetchInt(7);
    int  rankTier  = results.FetchInt(8);

    // Determine player's result.
    bool won  = (StrEqual(team, "team1") && StrEqual(winner, "team1"))
             || (StrEqual(team, "team2") && StrEqual(winner, "team2"));
    bool tied = StrEqual(winner, "tie");

    char resultStr[8];
    if      (tied) strcopy(resultStr, sizeof(resultStr), "Tie");
    else if (won)  strcopy(resultStr, sizeof(resultStr), "Win");
    else           strcopy(resultStr, sizeof(resultStr), "Loss");

    // Format ELO change string with explicit sign.
    char changeStr[16];
    if (eloChange >= 0) Format(changeStr, sizeof(changeStr), "+%d", eloChange);
    else                Format(changeStr, sizeof(changeStr), "%d",  eloChange);

    // Score from this player's perspective.
    int myScore    = StrEqual(team, "team1") ? t1Score : t2Score;
    int theirScore = StrEqual(team, "team1") ? t2Score : t1Score;

    char rankName[48];
    MM_GetRankName(rankTier, rankName, sizeof(rankName));

    MM_PrintToChat(client,
        "[MM] Match over \x01— Score: \x09%d\x01-\x09%d\x01 (\x04%s\x01)",
        myScore, theirScore, resultStr);
    MM_PrintToChat(client,
        "[MM] Rating: \x09%d\x01 → \x09%d\x01 (\x04%s\x01) | %s",
        eloBefore, eloAfter, changeStr, rankName);

    // Mark as notified so we don't show it again.
    char notifQuery[256];
    g_hDB.Format(notifQuery, sizeof(notifQuery),
        "UPDATE mm_match_players SET elo_notified = 1 WHERE id = %d", mpId);
    g_hDB.Query(DB_GenericCallback, notifQuery, _, DBPrio_Normal);
}

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

    // Step 1.5: Check party membership before queuing
    char steamID[32];
    char escapedSteamID[65];
    MM_GetSteamID(client, steamID, sizeof(steamID));
    db.Escape(steamID, escapedSteamID, sizeof(escapedSteamID));

    DataPack pack2 = new DataPack();
    pack2.WriteCell(userid);
    pack2.WriteString(mapPref);

    char partyQuery[512];
    g_hDB.Format(partyQuery, sizeof(partyQuery),
        "SELECT pm.party_id, (p.leader_id = '%s') AS is_leader "
        "FROM mm_party_members pm "
        "JOIN mm_parties p ON p.id = pm.party_id "
        "WHERE pm.steam_id = '%s' LIMIT 1",
        escapedSteamID, escapedSteamID);
    g_hDB.Query(DB_CheckPartyForQueue, partyQuery, pack2, DBPrio_High);
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
    g_fQueueStartTime[client] = GetEngineTime();

    // Fetch queue count for the confirmation message
    g_hDB.Query(DB_QueueCount, "SELECT COUNT(*) FROM mm_queue WHERE status='waiting'",
        GetClientUserId(client), DBPrio_Normal);

    // Fetch estimated wait time for this player's ELO bracket
    char waitQuery[512];
    g_hDB.Format(waitQuery, sizeof(waitQuery),
        "SELECT AVG(TIMESTAMPDIFF(SECOND, q.queued_at, m.started_at)) "
        "FROM mm_queue q JOIN mm_matches m ON m.id = q.match_id "
        "WHERE q.status IN ('matched','ready_check') "
        "  AND ABS(q.elo - %d) <= 300 "
        "  AND q.queued_at > DATE_SUB(NOW(), INTERVAL 2 HOUR)",
        g_iElo[client]);
    g_hDB.Query(DB_WaitTimeEstimate, waitQuery, GetClientUserId(client), DBPrio_Normal);
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
// Party-aware queue: check membership → solo or party leader flow
// ─────────────────────────────────────────────────────────────────────────────

// Step between ban-check and upsert: are we in a party?
public void DB_CheckPartyForQueue(Database db, DBResultSet results, const char[] error, DataPack pack)
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
        LogError("[MM] DB_CheckPartyForQueue error: %s", error);
        MM_ErrorToChat(client, "Database error. Please try again.");
        return;
    }

    if (!results.FetchRow())
    {
        // Not in a party — solo flow
        DoQueueSolo(db, client, userid, mapPref);
        return;
    }

    int  partyId  = results.FetchInt(0);
    bool isLeader = (results.FetchInt(1) == 1);

    if (!isLeader)
    {
        MM_WarnToChat(client,
            "Only your party leader can start the queue. "
            "Type \x04!party list\x01 to see who the leader is.");
        return;
    }

    // Leader: fetch all party members + ban status
    DataPack pack2 = new DataPack();
    pack2.WriteCell(userid);
    pack2.WriteString(mapPref);
    pack2.WriteCell(partyId);

    char memberQuery[512];
    g_hDB.Format(memberQuery, sizeof(memberQuery),
        "SELECT pm.steam_id, pl.elo, pl.rank_tier, pl.name, "
        "       (pl.is_banned = 1 AND pl.ban_until > NOW()) AS is_banned "
        "FROM mm_party_members pm "
        "JOIN mm_players pl ON pl.steam_id = pm.steam_id "
        "WHERE pm.party_id = %d",
        partyId);
    g_hDB.Query(DB_QueuePartyMembers, memberQuery, pack2, DBPrio_High);
}

// Helper: reuse the existing solo queue chain
void DoQueueSolo(Database db, int client, int userid, const char[] mapPref)
{
    char steamID[32], name[64], escapedSteamID[65], escapedName[129], steam64Str[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));
    GetClientName(client, name, sizeof(name));
    db.Escape(steamID, escapedSteamID, sizeof(escapedSteamID));
    db.Escape(name,    escapedName,    sizeof(escapedName));
    GetClientAuthId(client, AuthId_SteamID64, steam64Str, sizeof(steam64Str));

    DataPack pack = new DataPack();
    pack.WriteCell(userid);
    pack.WriteString(mapPref);

    char query[768];
    g_hDB.Format(query, sizeof(query),
        "INSERT INTO mm_players (steam_id, steam_id64, name, elo, rank_tier) "
        "VALUES ('%s', %s, '%s', 1000, 5) "
        "ON DUPLICATE KEY UPDATE name='%s', last_queue=NOW()",
        escapedSteamID, steam64Str, escapedName, escapedName);
    g_hDB.Query(DB_UpsertPlayer, query, pack, DBPrio_High);
}

// Party leader queuing: insert queue entries for all party members at once
public void DB_QueuePartyMembers(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid  = pack.ReadCell();
    char mapPref[32];
    pack.ReadString(mapPref, sizeof(mapPref));
    int partyId = pack.ReadCell();
    delete pack;

    int leader = GetClientOfUserId(userid);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_QueuePartyMembers error: %s", error);
        if (MM_IsValidClient(leader))
            MM_ErrorToChat(leader, "Database error fetching party members.");
        return;
    }

    char memberSteamIDs[PARTY_MAX_MEMBERS][32];
    int  memberElos    [PARTY_MAX_MEMBERS];
    int  memberRanks   [PARTY_MAX_MEMBERS];
    char memberNames   [PARTY_MAX_MEMBERS][64];
    bool memberBanned  [PARTY_MAX_MEMBERS];
    int  memberCount = 0;

    while (results.FetchRow() && memberCount < PARTY_MAX_MEMBERS)
    {
        results.FetchString(0, memberSteamIDs[memberCount], 32);
        memberElos  [memberCount] = results.FetchInt(1);
        memberRanks [memberCount] = results.FetchInt(2);
        results.FetchString(3, memberNames[memberCount], 64);
        memberBanned[memberCount] = (results.FetchInt(4) > 0);
        memberCount++;
    }

    if (memberCount == 0)
    {
        if (MM_IsValidClient(leader))
            MM_WarnToChat(leader, "Party appears to have no members.");
        return;
    }

    // Abort if any member is banned
    for (int i = 0; i < memberCount; i++)
    {
        if (memberBanned[i])
        {
            if (MM_IsValidClient(leader))
                MM_WarnToChat(leader,
                    "Cannot queue: \x09%s\x01 is banned from matchmaking. Queue aborted.",
                    memberNames[i]);
            return;
        }
    }

    // Insert queue entries for all members and update in-game ELO cache
    char escapedMap[65];
    if (mapPref[0] != '\0')
        db.Escape(mapPref, escapedMap, sizeof(escapedMap));

    for (int i = 0; i < memberCount; i++)
    {
        // Update in-game ELO/rank cache for any member currently on this server
        for (int c = 1; c <= MaxClients; c++)
        {
            if (!MM_IsValidClient(c)) continue;
            char cSteamID[32];
            MM_GetSteamID(c, cSteamID, sizeof(cSteamID));
            if (StrEqual(cSteamID, memberSteamIDs[i]))
            {
                g_iElo [c] = memberElos[i];
                g_iRank[c] = memberRanks[i];
                break;
            }
        }

        // INSERT queue entry
        char insertQuery[512];
        if (mapPref[0] != '\0')
        {
            g_hDB.Format(insertQuery, sizeof(insertQuery),
                "INSERT IGNORE INTO mm_queue (steam_id, elo, rank_tier, status, map_preference) "
                "VALUES ('%s', %d, %d, 'waiting', '%s')",
                memberSteamIDs[i], memberElos[i], memberRanks[i], escapedMap);
        }
        else
        {
            g_hDB.Format(insertQuery, sizeof(insertQuery),
                "INSERT IGNORE INTO mm_queue (steam_id, elo, rank_tier, status) "
                "VALUES ('%s', %d, %d, 'waiting')",
                memberSteamIDs[i], memberElos[i], memberRanks[i]);
        }
        g_hDB.Query(DB_GenericCallback, insertQuery, _, DBPrio_High);
    }

    // Mark all in-game party members as queued
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!MM_IsValidClient(c)) continue;
        char cSteamID[32];
        MM_GetSteamID(c, cSteamID, sizeof(cSteamID));

        for (int i = 0; i < memberCount; i++)
        {
            if (!StrEqual(cSteamID, memberSteamIDs[i])) continue;
            g_bQueued[c] = true;
            g_fQueueStartTime[c] = GetEngineTime();
            break;
        }
    }

    // Notify the leader
    if (MM_IsValidClient(leader))
    {
        char rankName[48];
        MM_GetRankName(g_iRank[leader], rankName, sizeof(rankName));
        MM_PrintToChat(leader,
            "\x04Party queue started!\x01 \x09%d\x01 member(s) queued. "
            "Rank: \x04%s\x01 | ELO: \x09%d\x01 | Type \x04!leave\x01 to cancel.",
            memberCount, rankName, g_iElo[leader]);
    }

    // Notify other in-game party members
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!MM_IsValidClient(c) || c == leader) continue;
        char cSteamID[32];
        MM_GetSteamID(c, cSteamID, sizeof(cSteamID));

        for (int i = 0; i < memberCount; i++)
        {
            if (!StrEqual(cSteamID, memberSteamIDs[i])) continue;

            char leaderName[64];
            if (MM_IsValidClient(leader))
                GetClientName(leader, leaderName, sizeof(leaderName));
            else
                strcopy(leaderName, sizeof(leaderName), "Party Leader");

            MM_PrintToChat(c,
                "\x04%s\x01 started the party queue! Searching for a match… "
                "Type \x04!leave\x01 to cancel.",
                leaderName);
            break;
        }
    }

    // Show wait time estimate to the leader
    if (MM_IsValidClient(leader) && g_iElo[leader] > 0)
    {
        char waitQuery[512];
        g_hDB.Format(waitQuery, sizeof(waitQuery),
            "SELECT AVG(TIMESTAMPDIFF(SECOND, q.queued_at, m.started_at)) "
            "FROM mm_queue q JOIN mm_matches m ON m.id = q.match_id "
            "WHERE q.status IN ('matched','ready_check') "
            "  AND ABS(q.elo - %d) <= 300 "
            "  AND q.queued_at > DATE_SUB(NOW(), INTERVAL 2 HOUR)",
            g_iElo[leader]);
        g_hDB.Query(DB_WaitTimeEstimate, waitQuery, GetClientUserId(leader), DBPrio_Normal);
    }

    #pragma unused partyId
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

    // Cancel this player's queue entry
    char query[512];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_queue SET status='cancelled' WHERE steam_id='%s' AND status IN ('waiting','ready_check')",
        steamID);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);

    // Also cancel all party members' queue entries (no-op if not in a party)
    char partyCancel[768];
    g_hDB.Format(partyCancel, sizeof(partyCancel),
        "UPDATE mm_queue SET status='cancelled' "
        "WHERE status IN ('waiting','ready_check') "
        "AND steam_id IN ("
        "  SELECT steam_id FROM mm_party_members "
        "  WHERE party_id = ("
        "    SELECT party_id FROM mm_party_members WHERE steam_id='%s' LIMIT 1"
        "  )"
        ")",
        steamID);
    g_hDB.Query(DB_GenericCallback, partyCancel, _, DBPrio_High);

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

    // Estimated wait time for this ELO bracket
    char waitQuery[512];
    g_hDB.Format(waitQuery, sizeof(waitQuery),
        "SELECT AVG(TIMESTAMPDIFF(SECOND, q.queued_at, m.started_at)) "
        "FROM mm_queue q JOIN mm_matches m ON m.id = q.match_id "
        "WHERE q.status IN ('matched','ready_check') "
        "  AND ABS(q.elo - %d) <= 300 "
        "  AND q.queued_at > DATE_SUB(NOW(), INTERVAL 2 HOUR)",
        g_iElo[client]);
    g_hDB.Query(DB_WaitTimeEstimate, waitQuery, GetClientUserId(client), DBPrio_Normal);

    // Queue position relative to other players in the same ELO bracket
    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));
    char posQuery[768];
    g_hDB.Format(posQuery, sizeof(posQuery),
        "SELECT "
        "  (SELECT COUNT(*) FROM mm_queue "
        "   WHERE status='waiting' AND elo BETWEEN %d-300 AND %d+300 "
        "   AND queued_at < IFNULL("
        "     (SELECT queued_at FROM mm_queue WHERE steam_id='%s' AND status='waiting' LIMIT 1),"
        "     NOW()"
        "   )"
        "  ) AS pos_count, "
        "  COUNT(*) AS bracket_count "
        "FROM mm_queue "
        "WHERE status='waiting' AND elo BETWEEN %d-300 AND %d+300",
        g_iElo[client], g_iElo[client], steamID,
        g_iElo[client], g_iElo[client]);
    g_hDB.Query(DB_StatusQueuePosition, posQuery, GetClientUserId(client), DBPrio_Normal);

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

// Callback: estimated wait time (shared by !queue join and !status)
public void DB_WaitTimeEstimate(Database db, DBResultSet results, const char[] error, any userid)
{
    if (results == null || error[0] != '\0') return;
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (!results.FetchRow() || results.IsFieldNull(0))
    {
        MM_PrintToChat(client, "Estimated wait time: \x07Unable to estimate.");
        return;
    }

    int avgSeconds = results.FetchInt(0);
    int mins = avgSeconds / 60;
    int secs = avgSeconds % 60;

    if (mins > 0)
        MM_PrintToChat(client, "Estimated wait time: \x04~%dm %ds\x01.", mins, secs);
    else
        MM_PrintToChat(client, "Estimated wait time: \x04~%ds\x01.", secs);
}

// Callback: queue position within ELO bracket (only shown by !status)
public void DB_StatusQueuePosition(Database db, DBResultSet results, const char[] error, any userid)
{
    if (results == null || error[0] != '\0') return;
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (!results.FetchRow()) return;

    int posCount     = results.FetchInt(0); // players ahead of you in bracket
    int bracketCount = results.FetchInt(1); // total players in bracket

    MM_PrintToChat(client,
        "You are \x04~#%d\x01 in your ELO bracket (\x09%d\x01 player(s) searching nearby).",
        posCount + 1, bracketCount);
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
        "SELECT elo, rank_tier, matches_won, matches_lost, total_kills, total_deaths FROM mm_players WHERE steam_id='%s' LIMIT 1",
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

    int elo         = results.FetchInt(0);
    int tier        = results.FetchInt(1);
    int matchesWon  = results.FetchInt(2);
    int matchesLost = results.FetchInt(3);
    int kills       = results.FetchInt(4);
    int deaths      = results.FetchInt(5);

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

    int declinedMatchId = g_iReadyMatchId[client];
    g_bReadyCheck[client] = false;

    if (g_hDB == null)
    {
        ResetClientState(client);
        return;
    }

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    // Cancel this player's queue entry
    char query[512];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_queue SET status='cancelled' WHERE steam_id='%s' AND status='ready_check'",
        steamID);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);

    // Cancel all party members' ready-check entries (no-op if not in a party)
    char partyCancel[768];
    g_hDB.Format(partyCancel, sizeof(partyCancel),
        "UPDATE mm_queue SET status='cancelled' "
        "WHERE status='ready_check' "
        "AND steam_id IN ("
        "  SELECT steam_id FROM mm_party_members "
        "  WHERE party_id = ("
        "    SELECT party_id FROM mm_party_members WHERE steam_id='%s' LIMIT 1"
        "  )"
        ")",
        steamID);
    g_hDB.Query(DB_GenericCallback, partyCancel, _, DBPrio_High);

    // Notify all in-game players in the same ready-check group
    char myName[64];
    GetClientName(client, myName, sizeof(myName));

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i) || i == client) continue;
        if (g_iReadyMatchId[i] != declinedMatchId || !g_bReadyCheck[i]) continue;

        MM_WarnToChat(i,
            "\x09%s\x01 declined the ready check. Your group's queue was cancelled.",
            myName);
    }

    ResetClientState(client);
    MM_WarnToChat(client, "You declined the ready check. Type \x04!queue\x01 to search again.");
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

    // Clean up expired avoid-list entries
    g_hDB.Query(DB_GenericCallback,
        "DELETE FROM mm_avoid_list WHERE expires_at < NOW()",
        _, DBPrio_Low);

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

// ─────────────────────────────────────────────────────────────────────────────
// !lastmatch — Show a summary of the player's most recent match
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_LastMatch(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    float now = GetEngineTime();
    if ((now - g_fLastCmd[client]) < CMD_RATE_LIMIT)
    {
        MM_WarnToChat(client, "Please wait before using this command again.");
        return Plugin_Handled;
    }
    g_fLastCmd[client] = now;

    if (g_hDB == null)
    {
        MM_ErrorToChat(client, "Matchmaking service unavailable.");
        return Plugin_Handled;
    }

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    char query[768];
    g_hDB.Format(query, sizeof(query),
        "SELECT m.map_name, m.team1_score, m.team2_score, m.winner, "
        "       mp.team, mp.kills, mp.deaths, mp.assists, mp.elo_change "
        "FROM mm_match_players mp "
        "JOIN mm_matches m ON m.id = mp.match_id "
        "WHERE mp.steam_id = '%s' AND m.status = 'finished' "
        "ORDER BY m.ended_at DESC LIMIT 1",
        steamID);
    g_hDB.Query(DB_LastMatchResult, query, GetClientUserId(client), DBPrio_Normal);

    return Plugin_Handled;
}

public void DB_LastMatchResult(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_LastMatchResult error: %s", error);
        MM_ErrorToChat(client, "Database error fetching last match.");
        return;
    }

    if (!results.FetchRow())
    {
        MM_PrintToChat(client, "[MM] No recent matches found. Play one first!");
        return;
    }

    char mapName[32];
    results.FetchString(0, mapName, sizeof(mapName));
    int  t1Score  = results.FetchInt(1);
    int  t2Score  = results.FetchInt(2);
    char winner[8];
    results.FetchString(3, winner, sizeof(winner));
    char team[8];
    results.FetchString(4, team, sizeof(team));
    int  kills    = results.FetchInt(5);
    int  deaths   = results.FetchInt(6);
    int  assists  = results.FetchInt(7);

    bool won  = (StrEqual(team, "team1") && StrEqual(winner, "team1"))
             || (StrEqual(team, "team2") && StrEqual(winner, "team2"));
    bool tied = StrEqual(winner, "tie");

    char resultStr[8];
    if      (tied) strcopy(resultStr, sizeof(resultStr), "Tie");
    else if (won)  strcopy(resultStr, sizeof(resultStr), "Win");
    else           strcopy(resultStr, sizeof(resultStr), "Loss");

    int myScore    = StrEqual(team, "team1") ? t1Score : t2Score;
    int theirScore = StrEqual(team, "team1") ? t2Score : t1Score;

    // ELO change may be NULL if the Python daemon hasn't processed it yet.
    char eloStr[16];
    if (results.IsFieldNull(8))
        strcopy(eloStr, sizeof(eloStr), "N/A");
    else
    {
        int eloChange = results.FetchInt(8);
        if (eloChange >= 0) Format(eloStr, sizeof(eloStr), "+%d", eloChange);
        else                Format(eloStr, sizeof(eloStr), "%d",  eloChange);
    }

    MM_PrintToChat(client,
        "[MM] Last match on \x04%s\x01 — \x09%d\x01-\x09%d\x01 (\x04%s\x01) | "
        "\x04%dK\x01/\x07%dD\x01/\x04%dA\x01 | ELO: \x09%s",
        mapName, myScore, theirScore, resultStr, kills, deaths, assists, eloStr);
}

// ─────────────────────────────────────────────────────────────────────────────
// !recent — show players from the last 5 matches (Phase 6.2)
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Recent(int client, int args)
{
    if (!MM_IsValidClient(client)) return Plugin_Handled;
    if (g_hDB == null)
    {
        MM_PrintToChat(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    if (GetEngineTime() - g_fLastCmd[client] < CMD_RATE_LIMIT)
    {
        MM_PrintToChat(client, "[MM] Please wait before using this command again.");
        return Plugin_Handled;
    }
    g_fLastCmd[client] = GetEngineTime();

    char steamID[32], escapedSID[64];
    GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));
    g_hDB.Escape(steamID, escapedSID, sizeof(escapedSID));

    char query[1024];
    Format(query, sizeof(query),
        "SELECT p.name, p.rank_tier, mp2.kills, mp2.deaths, mp2.team, "
        "m.winner, m.ended_at "
        "FROM mm_match_players mp1 "
        "JOIN mm_matches m ON m.id = mp1.match_id "
        "JOIN mm_match_players mp2 ON mp2.match_id = mp1.match_id AND mp2.steam_id != '%s' "
        "JOIN mm_players p ON p.steam_id = mp2.steam_id "
        "WHERE mp1.steam_id = '%s' AND m.status = 'finished' "
        "ORDER BY m.ended_at DESC LIMIT 5",
        escapedSID, escapedSID);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    g_hDB.Query(DB_RecentResult, query, pack, DBPrio_Normal);

    return Plugin_Handled;
}

public void DB_RecentResult(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0) return;

    if (results == null)
    {
        LogError("[MM] DB_RecentResult error: %s", error);
        MM_PrintToChat(client, "[MM] Could not retrieve recent match data.");
        return;
    }

    if (!results.FetchRow())
    {
        MM_PrintToChat(client, "[MM] No recent matches found.");
        return;
    }

    MM_PrintToChat(client, "[MM] Recent teammates & opponents:");

    int count = 0;
    do
    {
        char playerName[64];
        results.FetchString(0, playerName, sizeof(playerName));
        int rankTier = results.FetchInt(1);
        int kills    = results.FetchInt(2);
        int deaths   = results.FetchInt(3);
        char team[8];
        results.FetchString(4, team, sizeof(team));
        char winner[8];
        results.FetchString(5, winner, sizeof(winner));

        bool won = StrEqual(team, winner);
        char role[12];
        strcopy(role, sizeof(role), won ? "\x04Win" : "\x07Loss");

        char tierName[32];
        MM_GetRankName(rankTier, tierName, sizeof(tierName));

        MM_PrintToChat(client,
            "  \x04%s\x01 [%s] — \x04%dK\x01/\x07%dD\x01 (%s\x01)",
            playerName, tierName, kills, deaths, role);

        count++;
    } while (results.FetchRow() && count < 5);
}

// ─────────────────────────────────────────────────────────────────────────────
// !avoid / !avoidlist — avoid player system (Phase 6.1)
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Avoid(int client, int args)
{
    if (!MM_IsValidClient(client)) return Plugin_Handled;
    if (g_hDB == null)
    {
        MM_PrintToChat(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        MM_PrintToChat(client, "[MM] Usage: !avoid <player name>");
        return Plugin_Handled;
    }

    if (GetEngineTime() - g_fLastCmd[client] < CMD_RATE_LIMIT)
    {
        MM_PrintToChat(client, "[MM] Please wait before using this command again.");
        return Plugin_Handled;
    }
    g_fLastCmd[client] = GetEngineTime();

    char partialName[MAX_NAME_LENGTH];
    GetCmdArgString(partialName, sizeof(partialName));

    // Find target among in-game clients
    int target = -1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client || !MM_IsValidClient(i)) continue;
        char playerName[MAX_NAME_LENGTH];
        GetClientName(i, playerName, sizeof(playerName));
        if (StrContains(playerName, partialName, false) != -1)
        {
            target = i;
            break;
        }
    }

    if (target == -1)
    {
        MM_PrintToChat(client, "[MM] Player '%s' not found on this server.", partialName);
        return Plugin_Handled;
    }

    char mySID[32], targetSID[32], escMy[64], escTarget[64];
    GetClientAuthId(client, AuthId_Steam2, mySID, sizeof(mySID));
    GetClientAuthId(target, AuthId_Steam2, targetSID, sizeof(targetSID));
    g_hDB.Escape(mySID,      escMy,     sizeof(escMy));
    g_hDB.Escape(targetSID,  escTarget, sizeof(escTarget));

    // First check how many active avoids the player already has (<= 10)
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(escMy);
    pack.WriteString(escTarget);
    pack.WriteString(targetSID);

    char countQuery[256];
    Format(countQuery, sizeof(countQuery),
        "SELECT COUNT(*) AS cnt FROM mm_avoid_list "
        "WHERE steam_id = '%s' AND expires_at > NOW()",
        escMy);
    g_hDB.Query(DB_AvoidCountCheck, countQuery, pack, DBPrio_Normal);

    return Plugin_Handled;
}

public void DB_AvoidCountCheck(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userId      = pack.ReadCell();
    char escMy[64], escTarget[64], targetSID[32];
    pack.ReadString(escMy, sizeof(escMy));
    pack.ReadString(escTarget, sizeof(escTarget));
    pack.ReadString(targetSID, sizeof(targetSID));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0) return;

    if (results == null || !results.FetchRow())
    {
        MM_PrintToChat(client, "[MM] Could not check avoid list.");
        return;
    }

    int count = results.FetchInt(0);
    if (count >= 10)
    {
        MM_PrintToChat(client, "[MM] You already have 10 active avoids. Remove one first (/avoidlist).");
        return;
    }

    char query[512];
    Format(query, sizeof(query),
        "INSERT INTO mm_avoid_list (steam_id, avoided_id, expires_at) "
        "VALUES ('%s', '%s', DATE_ADD(NOW(), INTERVAL 7 DAY)) "
        "ON DUPLICATE KEY UPDATE expires_at = DATE_ADD(NOW(), INTERVAL 7 DAY)",
        escMy, escTarget);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_Normal);

    MM_PrintToChat(client, "[MM] You are now avoiding \x04%s\x01 for 7 days.", targetSID);
}

public Action Cmd_AvoidList(int client, int args)
{
    if (!MM_IsValidClient(client)) return Plugin_Handled;
    if (g_hDB == null)
    {
        MM_PrintToChat(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    if (GetEngineTime() - g_fLastCmd[client] < CMD_RATE_LIMIT)
    {
        MM_PrintToChat(client, "[MM] Please wait before using this command again.");
        return Plugin_Handled;
    }
    g_fLastCmd[client] = GetEngineTime();

    char steamID[32], escapedSID[64];
    GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));
    g_hDB.Escape(steamID, escapedSID, sizeof(escapedSID));

    char query[512];
    Format(query, sizeof(query),
        "SELECT COALESCE(p.name, al.avoided_id), al.expires_at "
        "FROM mm_avoid_list al "
        "LEFT JOIN mm_players p ON p.steam_id = al.avoided_id "
        "WHERE al.steam_id = '%s' AND al.expires_at > NOW() "
        "ORDER BY al.expires_at ASC LIMIT 10",
        escapedSID);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    g_hDB.Query(DB_AvoidListResult, query, pack, DBPrio_Normal);

    return Plugin_Handled;
}

public void DB_AvoidListResult(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0) return;

    if (results == null)
    {
        LogError("[MM] DB_AvoidListResult error: %s", error);
        return;
    }

    if (!results.FetchRow())
    {
        MM_PrintToChat(client, "[MM] Your avoid list is empty.");
        return;
    }

    MM_PrintToChat(client, "[MM] Your avoid list:");
    do
    {
        char name[64];
        results.FetchString(0, name, sizeof(name));
        // expires_at is a datetime string
        char expiry[32];
        results.FetchString(1, expiry, sizeof(expiry));
        // Trim to date only
        expiry[10] = '\0';
        MM_PrintToChat(client, "  \x04%s\x01 (expires %s)", name, expiry);
    } while (results.FetchRow());
}

// ─────────────────────────────────────────────────────────────────────────────
// Persistent HUD — queue status overlay (Phase 7)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Repeating timer (every HUD_INTERVAL seconds) that shows a HintText status
 * line to queued players. Players in a ready check see a different message.
 * All other players receive no hint text from this timer.
 */
public Action Timer_UpdateHUD(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        if (g_bReadyCheck[client])
        {
            PrintHintText(client, "[MM] Ready check active — accept or decline!");
            continue;
        }

        if (g_bQueued[client])
        {
            int elapsed = RoundToFloor(GetEngineTime() - g_fQueueStartTime[client]);
            if (elapsed < 0) elapsed = 0;
            int mins = elapsed / 60;
            int secs = elapsed % 60;
            PrintHintText(client, "[MM] Searching for a match...  %d:%02d elapsed", mins, secs);
        }
    }
    return Plugin_Continue;
}
