/**
 * csgo_mm_notify.sp — CS:GO Matchmaking Notification Plugin
 *
 * Runs alongside csgo_mm_queue.sp on the lobby server.
 * Responsible for:
 *   - Welcome panel + !help / !commands for command discoverability
 *   - Periodic queue-count HUD hints to all players
 *   - HUD hints for spectating players
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
    description = "Welcome panel, !help command, queue HUD hints, spectator hints",
    version     = MM_VERSION,
    url         = ""
};

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

#define ANNOUNCE_QUEUE_INTERVAL   90.0   // seconds between queue-count HUD hint refreshes
#define ANNOUNCE_HUD_INTERVAL     30.0   // seconds between HUD hints for spectators

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

    // Help command — callable at any time to reopen the command guide panel
    RegConsoleCmd("sm_help",     Cmd_Help, "Show all matchmaking commands");
    RegConsoleCmd("sm_commands", Cmd_Help, "Show all matchmaking commands");

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

    // One brief chat greeting — full command list is shown in the panel below.
    // Keeping this to a single line avoids flooding the chat on busy servers.
    PrintToChat(client,
        " \x02[MM]\x01 Welcome, \x04%s\x01! A command guide has been opened for you. Type \x04!help\x01 to reopen it.",
        name);

    // If players are already queued, surface that immediately so new arrivals
    // can decide whether to join — one extra line is worthwhile here.
    if (g_hDB != null && g_iCachedQueueCount > 0)
        PrintToChat(client,
            " \x02[MM]\x01 \x09%d\x01 player(s) in queue right now — type \x04!queue\x01 to join!",
            g_iCachedQueueCount);

    // Open the help panel — all commands, grouped, with panel UX note
    ShowHelpPanel(client);

    return Plugin_Stop;
}

// ─────────────────────────────────────────────────────────────────────────────
// Help panel — all commands, grouped by category
//
// Shown automatically on connect (Timer_WelcomeClient) and on demand via
// !help / !commands.  Uses a Panel so only the requesting player sees it —
// no chat noise for the other 49 players on the server.
// ─────────────────────────────────────────────────────────────────────────────

void ShowHelpPanel(int client)
{
    Panel panel = new Panel();
    panel.SetTitle("CS:GO Matchmaking — Commands");

    panel.DrawText("────────────────────────────────────");
    panel.DrawText("[ QUEUE ]");
    panel.DrawText("!queue [map]       Join competitive queue");
    panel.DrawText("!leave             Leave the queue");
    panel.DrawText("!status            Your position & wait time");

    panel.DrawText("────────────────────────────────────");
    panel.DrawText("[ STATS & RANKINGS ]");
    panel.DrawText("!rank              ELO, rank tier, W/L, K/D");
    panel.DrawText("!stats             Full career stats  [panel]");
    panel.DrawText("!top               Top 10 leaderboard [panel]");
    panel.DrawText("!lastmatch         Summary of your last match");
    panel.DrawText("!recent            Players from last 5 matches");

    panel.DrawText("────────────────────────────────────");
    panel.DrawText("[ SOCIAL ]");
    panel.DrawText("!party invite <name>   Create/invite to party");
    panel.DrawText("!party accept/decline  Respond to an invite");
    panel.DrawText("!party leave/kick      Manage your party");
    panel.DrawText("!avoid <name>          Avoid a player (7 days)");
    panel.DrawText("!avoidlist             View your avoid list");

    panel.DrawText("────────────────────────────────────");
    panel.DrawText("Commands marked [panel] open a menu like");
    panel.DrawText("this one. Press the number shown to close.");
    panel.DrawText("Type !help at any time to reopen this guide.");
    panel.DrawText("────────────────────────────────────");

    panel.DrawItem("Close");
    panel.Send(client, Panel_HelpHandler, 30);
    delete panel;
}

// No-op handler — this panel is display-only; any key press just closes it
public int Panel_HelpHandler(Menu menu, MenuAction action, int client, int item)
{
    return 0;
}

// !help / !commands — reopen the command guide at any time
public Action Cmd_Help(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    ShowHelpPanel(client);
    return Plugin_Handled;
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: Queue-count HUD hint refresh for all connected players (every 90s)
//
// Uses PrintHintText so the message appears as a small on-screen overlay and
// never clutters the chat — critical on busy servers with many players.
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

    // Push a hint-text update to every connected player.
    // PrintHintText appears as a small HUD overlay (bottom-centre of screen)
    // and does not add a line to the chat box — safe on high-population servers.
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!MM_IsValidClient(client))
            continue;

        // Note: queued players also receive this hint, but csgo_mm_queue.sp's
        // Timer_UpdateHUD (every 2s) overwrites it almost immediately with their
        // personal queue position — so there is no lasting conflict.
        if (count > 0)
            PrintHintText(client,
                "[MM] %d player(s) in competitive queue.\nType !queue to join!",
                count);
        else
            PrintHintText(client,
                "[MM] Competitive matchmaking is open.\nType !queue to join!");
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

// Top-3 broadcast removed — periodic chat blasts to 50+ players create noise.
// Players can use !top in-game (panel) or visit the web panel leaderboard.
