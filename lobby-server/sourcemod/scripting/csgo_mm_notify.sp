/**
 * csgo_mm_notify.sp — CS:GO Matchmaking Notification Plugin
 *
 * Runs alongside csgo_mm_queue.sp on the lobby server.
 * Responsible for:
 *   - Welcome messages when players connect
 *   - Periodic queue-count announcements to all players
 *   - HUD hints for spectating players
 *   - Periodic top-3 ELO scoreboard broadcasts
 *
 * Compile: spcomp csgo_mm_notify.sp -i scripting/include
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
    name        = "CS:GO Matchmaking - Notifications",
    author      = "CSGO-MM",
    description = "Queue announcements, welcome messages, HUD hints, and top-3 broadcast",
    version     = MM_VERSION,
    url         = ""
};

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

#define ANNOUNCE_QUEUE_INTERVAL   60.0   // seconds between queue-count broadcasts
#define ANNOUNCE_HUD_INTERVAL     30.0   // seconds between HUD hints for spectators
#define ANNOUNCE_TOP_INTERVAL     300.0  // seconds between top-3 broadcasts (5 min)

// Welcome message delay after OnClientPostAdminCheck fires
#define WELCOME_DELAY             3.0

// ─────────────────────────────────────────────────────────────────────────────
// Globals
// ─────────────────────────────────────────────────────────────────────────────

Database g_hDB = null;

// Cached queue depth (updated by each announce query) used in HUD hints
// to avoid firing a DB query every 30s per spectating player
int g_iCachedQueueCount = 0;

// ─────────────────────────────────────────────────────────────────────────────
// Plugin start
// ─────────────────────────────────────────────────────────────────────────────

public void OnPluginStart()
{
    Database.Connect(DB_Connected, MM_DB_NAME);

    // Repeating timers
    CreateTimer(ANNOUNCE_QUEUE_INTERVAL, Timer_AnnounceQueue, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(ANNOUNCE_HUD_INTERVAL,   Timer_HudHint,       _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(ANNOUNCE_TOP_INTERVAL,   Timer_AnnounceTop3,  _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    LogMessage("[MM-Notify] Notification plugin loaded (v%s)", MM_VERSION);
}

public void OnPluginEnd()
{
    delete g_hDB;
}

// ─────────────────────────────────────────────────────────────────────────────
// Database
// ─────────────────────────────────────────────────────────────────────────────

public void DB_Connected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[MM-Notify] Database connection failed: %s", error);
        return;
    }
    g_hDB = db;
    g_hDB.SetCharset("utf8mb4");
    LogMessage("[MM-Notify] Database connected.");
}

// Generic fire-and-forget error logger
public void DB_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null || error[0] != '\0')
        LogError("[MM-Notify] DB error: %s", error);
}

// ─────────────────────────────────────────────────────────────────────────────
// Client lifecycle — welcome message
// ─────────────────────────────────────────────────────────────────────────────

public void OnClientPostAdminCheck(int client)
{
    if (!MM_IsValidClient(client))
        return;

    // Delay slightly so the player's screen is past the loading transition
    CreateTimer(WELCOME_DELAY, Timer_WelcomeClient, GetClientUserId(client));
}

public Action Timer_WelcomeClient(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client))
        return Plugin_Stop;

    char name[64];
    GetClientName(client, name, sizeof(name));

    // ── Welcome header ────────────────────────────────────────────────────────
    PrintToChat(client,
        " \x02[MM]\x01 Welcome, \x04%s\x01!", name);
    PrintToChat(client,
        " \x02[MM]\x01 This is a \x09competitive matchmaking\x01 lobby server.");
    PrintToChat(client,
        " \x02[MM]\x01 Type \x04!queue\x01 to join the matchmaking queue.");
    PrintToChat(client,
        " \x02[MM]\x01 Commands: \x04!queue\x01 | \x04!leave\x01 | \x04!rank\x01 | \x04!stats\x01 | \x04!top\x01");

    // If the DB is up, also tell the player how many people are currently queued
    if (g_hDB != null && g_iCachedQueueCount > 0)
    {
        PrintToChat(client,
            " \x02[MM]\x01 \x09%d\x01 player(s) are currently in queue!",
            g_iCachedQueueCount);
    }

    return Plugin_Stop;
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: Queue-count announcement to all (every 60s)
// ─────────────────────────────────────────────────────────────────────────────

public Action Timer_AnnounceQueue(Handle timer)
{
    if (g_hDB == null)
        return Plugin_Continue;

    g_hDB.Query(DB_AnnounceQueueResult,
        "SELECT COUNT(*) FROM mm_queue WHERE status='waiting'",
        0, DBPrio_Low);

    return Plugin_Continue;
}

public void DB_AnnounceQueueResult(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Notify] DB_AnnounceQueueResult error: %s", error);
        return;
    }

    if (!results.FetchRow())
        return;

    int count = results.FetchInt(0);
    g_iCachedQueueCount = count;

    if (count > 0)
    {
        // Colour-coded broadcast: [MM] in green, count in orange, instruction in light green
        PrintToChatAll(
            " \x02[MM]\x01 \x09%d\x01 player(s) in queue. Type \x04!queue\x01 to join competitive matchmaking!",
            count);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: HUD hint for spectating players (every 30s)
//
// Shows a subtle on-screen reminder to spectating players so they notice
// the queue without chat being spammed.
// ─────────────────────────────────────────────────────────────────────────────

public Action Timer_HudHint(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!MM_IsValidClient(client))
            continue;

        // Only target players sitting in spectator
        if (GetClientTeam(client) != CS_TEAM_SPECTATOR)
            continue;

        if (g_iCachedQueueCount > 0)
        {
            PrintHintText(client,
                "[MM] %d player(s) in competitive queue.\nType !queue to join!",
                g_iCachedQueueCount);
        }
        else
        {
            PrintHintText(client,
                "[MM] Competitive matchmaking available.\nType !queue to join!");
        }
    }

    return Plugin_Continue;
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: Top-3 ELO scoreboard broadcast (every 5 minutes)
// ─────────────────────────────────────────────────────────────────────────────

public Action Timer_AnnounceTop3(Handle timer)
{
    if (g_hDB == null)
        return Plugin_Continue;

    g_hDB.Query(DB_Top3Result,
        "SELECT name, elo, rank_tier FROM mm_players WHERE matches_played >= 1 ORDER BY elo DESC LIMIT 3",
        0, DBPrio_Low);

    return Plugin_Continue;
}

public void DB_Top3Result(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Notify] DB_Top3Result error: %s", error);
        return;
    }

    if (results.RowCount == 0)
        return;  // No ranked players yet — don't broadcast an empty list

    PrintToChatAll(" \x02[MM]\x01 \x04─── Top Players by ELO ───");

    // Medal strings for positions 1-3
    static const char medals[3][] = { "#1", "#2", "#3" };

    int pos = 0;
    while (results.FetchRow() && pos < 3)
    {
        char playerName[64];
        results.FetchString(0, playerName, sizeof(playerName));
        int elo  = results.FetchInt(1);
        int tier = results.FetchInt(2);

        char rankName[48];
        MM_GetRankName(tier, rankName, sizeof(rankName));

        // Colour-code: gold/orange for #1, light green for #2-3
        if (pos == 0)
        {
            PrintToChatAll(
                " \x02[MM]\x01 \x09%s\x01 \x09%s\x01 — \x04%s\x01 (\x09%d\x01 ELO)",
                medals[pos], playerName, rankName, elo);
        }
        else
        {
            PrintToChatAll(
                " \x02[MM]\x01 \x04%s\x01 \x04%s\x01 — %s (\x04%d\x01 ELO)",
                medals[pos], playerName, rankName, elo);
        }
        pos++;
    }
}
