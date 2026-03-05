/**
 * csgo_mm_admin.sp — CS:GO Matchmaking Admin Commands Plugin
 *
 * Provides privileged commands for server administrators.
 * All commands require ADMFLAG_ROOT unless otherwise noted.
 *
 * Commands (chat prefix !mm_X or console mm_X):
 *   !mm_forcestart          — Force-start match from current queue (testing)
 *   !mm_cancelqueue         — Cancel ALL waiting queue entries
 *   !mm_ban <id> <min> <reason> — Matchmaking-ban a player
 *   !mm_unban <steamid>     — Remove a matchmaking ban
 *   !mm_setelo <id> <elo>   — Override a player's ELO
 *   !mm_resetrank <id>      — Reset player ELO to 1000
 *   !mm_status              — Show system status (queue, matches)
 *
 * Compile: spcomp csgo_mm_admin.sp -i scripting/include
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
    name        = "CS:GO Matchmaking - Admin",
    author      = "CSGO-MM",
    description = "Admin commands for queue management, bans, and ELO overrides",
    version     = MM_VERSION,
    url         = ""
};

// ─────────────────────────────────────────────────────────────────────────────
// Globals
// ─────────────────────────────────────────────────────────────────────────────

Database g_hDB = null;

// ─────────────────────────────────────────────────────────────────────────────
// Plugin start
// ─────────────────────────────────────────────────────────────────────────────

public void OnPluginStart()
{
    Database.Connect(DB_Connected, MM_DB_NAME);

    RegAdminCmd("sm_mm_forcestart",  Cmd_ForceStart,  ADMFLAG_ROOT, "Force-start a match from the queue");
    RegAdminCmd("sm_mm_cancelqueue", Cmd_CancelQueue, ADMFLAG_ROOT, "Cancel all waiting queue entries");
    RegAdminCmd("sm_mm_ban",         Cmd_Ban,         ADMFLAG_ROOT, "Ban a player from matchmaking");
    RegAdminCmd("sm_mm_unban",       Cmd_Unban,       ADMFLAG_ROOT, "Remove a matchmaking ban by SteamID");
    RegAdminCmd("sm_mm_setelo",      Cmd_SetElo,      ADMFLAG_ROOT, "Override a player's ELO");
    RegAdminCmd("sm_mm_resetrank",   Cmd_ResetRank,   ADMFLAG_ROOT, "Reset a player's ELO to 1000");
    RegAdminCmd("sm_mm_status",      Cmd_Status,      ADMFLAG_ROOT, "Show MM system status");

    LogMessage("[MM-Admin] Admin plugin loaded (v%s)", MM_VERSION);
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
        LogError("[MM-Admin] Database connection failed: %s", error);
        return;
    }
    g_hDB = db;
    g_hDB.SetCharset("utf8mb4");
    LogMessage("[MM-Admin] Database connected.");
}

public void DB_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null || error[0] != '\0')
        LogError("[MM-Admin] DB error: %s", error);
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper: Resolve a "#userid" or "name" argument to a client index.
//         Returns -1 and prints usage if not found.
// ─────────────────────────────────────────────────────────────────────────────

int FindTargetClient(int admin, const char[] arg)
{
    // Numeric #userid form
    if (arg[0] == '#')
    {
        int userid = StringToInt(arg[1]);
        int client = GetClientOfUserId(userid);
        if (client > 0 && IsClientInGame(client))
            return client;
        return -1;
    }

    // Name search (partial, case-insensitive)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        char name[64];
        GetClientName(i, name, sizeof(name));
        if (StrContains(name, arg, false) != -1)
            return i;
    }
    return -1;
}

// ─────────────────────────────────────────────────────────────────────────────
// !mm_forcestart — Force-start a match from queue entries
// ─────────────────────────────────────────────────────────────────────────────
//
// For testing, this lowers the minimum player count to 2 and sets all
// waiting queue entries to 'ready_check' so the Python matchmaker can
// immediately form a match.  The matchmaker retains full control after this.
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_ForceStart(int client, int args)
{
    if (!MM_IsValidClient(client) && client != 0)
        return Plugin_Handled;

    if (g_hDB == null)
    {
        ReplyToCommand(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    char adminSteamID[32];
    if (client == 0)
        strcopy(adminSteamID, sizeof(adminSteamID), "CONSOLE");
    else
        MM_GetSteamID(client, adminSteamID, sizeof(adminSteamID));

    // Count eligible waiting entries
    g_hDB.Query(DB_ForceStartCount,
        "SELECT COUNT(*) FROM mm_queue WHERE status='waiting'",
        GetClientUserId(client), DBPrio_High);

    LogAction(client, -1, "[MM-Admin] %s triggered mm_forcestart", adminSteamID);
    return Plugin_Handled;
}

public void DB_ForceStartCount(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid); // may be 0 (console)

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_ForceStartCount error: %s", error);
        if (client > 0) ReplyToCommand(client, "[MM] DB error counting queue.");
        return;
    }

    if (!results.FetchRow())
        return;

    int count = results.FetchInt(0);

    if (count < 2)
    {
        if (client > 0)
            ReplyToCommand(client, "[MM] Need at least 2 players in queue for force-start. Currently: %d", count);
        else
            PrintToServer("[MM] Need at least 2 players in queue. Currently: %d", count);
        return;
    }

    // Promote all waiting entries to ready_check — the Python matchmaker will
    // detect enough "ready_check" rows and proceed to form a match.
    // Using LIMIT 10 to cap at one full match worth of players.
    char query[256];
    Format(query, sizeof(query),
        "UPDATE mm_queue SET status='ready_check' WHERE status='waiting' LIMIT 10");
    g_hDB.Query(DB_ForceStartDone, query, GetClientUserId(client), DBPrio_High);
}

public void DB_ForceStartDone(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_ForceStartDone error: %s", error);
        return;
    }

    int affected = results.AffectedRows;

    if (client > 0 && MM_IsValidClient(client))
    {
        ReplyToCommand(client,
            "[MM] Force-start: promoted %d queue entries to ready_check. "
            "Matchmaker will proceed.",
            affected);
    }
    else
    {
        PrintToServer("[MM] Force-start: promoted %d queue entries to ready_check.", affected);
    }

    // Announce to all admmins in-game
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        if (GetUserFlagBits(i) & ADMFLAG_ROOT)
        {
            PrintToChat(i,
                " \x02[MM-Admin]\x01 Force-start triggered. "
                "\x09%d\x01 queue entries set to ready_check.",
                affected);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !mm_cancelqueue — Cancel all waiting queue entries
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_CancelQueue(int client, int args)
{
    if (!MM_IsValidClient(client) && client != 0)
        return Plugin_Handled;

    if (g_hDB == null)
    {
        ReplyToCommand(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    char adminSteamID[32];
    if (client == 0)
        strcopy(adminSteamID, sizeof(adminSteamID), "CONSOLE");
    else
        MM_GetSteamID(client, adminSteamID, sizeof(adminSteamID));

    g_hDB.Query(DB_CancelQueueDone,
        "UPDATE mm_queue SET status='cancelled' WHERE status='waiting'",
        GetClientUserId(client), DBPrio_High);

    LogAction(client, -1, "[MM-Admin] %s cancelled all waiting queue entries.", adminSteamID);
    return Plugin_Handled;
}

public void DB_CancelQueueDone(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_CancelQueueDone error: %s", error);
        return;
    }

    int affected = results.AffectedRows;

    if (client > 0 && MM_IsValidClient(client))
        ReplyToCommand(client, "[MM] Cancelled %d waiting queue entries.", affected);
    else
        PrintToServer("[MM] Cancelled %d waiting queue entries.", affected);

    // Notify all in-game admins
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        if (GetUserFlagBits(i) & ADMFLAG_ROOT)
        {
            PrintToChat(i,
                " \x02[MM-Admin]\x01 Queue cleared — \x09%d\x01 entries cancelled.",
                affected);
        }
    }

    // Alert players whose entries were just cancelled
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        // We can't cheaply check g_bQueued here (different plugin) so just
        // broadcast to everyone; players not in queue won't be confused by it.
        PrintToChat(i,
            " \x09[MM]\x01 An admin cancelled the queue. Please re-queue when ready.");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !mm_ban <#userid|name> <minutes> <reason>
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Ban(int client, int args)
{
    if (!MM_IsValidClient(client) && client != 0)
        return Plugin_Handled;

    if (args < 3)
    {
        ReplyToCommand(client, "[MM] Usage: sm_mm_ban <#userid|name> <minutes> <reason>");
        return Plugin_Handled;
    }

    if (g_hDB == null)
    {
        ReplyToCommand(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    char targetArg[64];
    GetCmdArg(1, targetArg, sizeof(targetArg));

    char minutesStr[16];
    GetCmdArg(2, minutesStr, sizeof(minutesStr));
    int minutes = StringToInt(minutesStr);
    if (minutes < 1)
    {
        ReplyToCommand(client, "[MM] Ban duration must be at least 1 minute.");
        return Plugin_Handled;
    }

    // Collect reason (may contain spaces — concatenate remaining args)
    char reason[255];
    reason[0] = '\0';
    for (int i = 3; i <= args; i++)
    {
        char part[128];
        GetCmdArg(i, part, sizeof(part));
        if (i > 3) StrCat(reason, sizeof(reason), " ");
        StrCat(reason, sizeof(reason), part);
    }

    int target = FindTargetClient(client, targetArg);
    if (target == -1)
    {
        ReplyToCommand(client, "[MM] Target not found: %s", targetArg);
        return Plugin_Handled;
    }

    if (!IsClientInGame(target))
    {
        ReplyToCommand(client, "[MM] Target is not in game.");
        return Plugin_Handled;
    }

    char targetSteamID[32];
    GetClientAuthId(target, AuthId_Steam2, targetSteamID, sizeof(targetSteamID));

    char adminSteamID[32];
    if (client == 0)
        strcopy(adminSteamID, sizeof(adminSteamID), "CONSOLE");
    else
        MM_GetSteamID(client, adminSteamID, sizeof(adminSteamID));

    char escapedReason[511];
    char escapedTarget[65];
    char escapedAdmin[65];
    g_hDB.Escape(reason,         escapedReason, sizeof(escapedReason));
    g_hDB.Escape(targetSteamID,  escapedTarget, sizeof(escapedTarget));
    g_hDB.Escape(adminSteamID,   escapedAdmin,  sizeof(escapedAdmin));

    // Insert ban record
    char banQuery[768];
    g_hDB.Format(banQuery, sizeof(banQuery),
        "INSERT INTO mm_bans (steam_id, reason, expires_at, banned_by, is_active) "
        "VALUES ('%s', '%s', DATE_ADD(NOW(), INTERVAL %d MINUTE), '%s', 1) "
        "ON DUPLICATE KEY UPDATE "
        "  reason='%s', expires_at=DATE_ADD(NOW(), INTERVAL %d MINUTE), "
        "  banned_by='%s', is_active=1",
        escapedTarget, escapedReason, minutes, escapedAdmin,
        escapedReason, minutes, escapedAdmin);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    pack.WriteCell(minutes);
    pack.WriteString(escapedReason);

    g_hDB.Query(DB_BanInserted, banQuery, pack, DBPrio_High);

    // Also update mm_players.is_banned / ban_until
    char playerBanQuery[512];
    g_hDB.Format(playerBanQuery, sizeof(playerBanQuery),
        "UPDATE mm_players SET is_banned=1, ban_until=DATE_ADD(NOW(), INTERVAL %d MINUTE) "
        "WHERE steam_id='%s'",
        minutes, escapedTarget);
    g_hDB.Query(DB_GenericCallback, playerBanQuery, _, DBPrio_High);

    // Cancel any active queue entry for the banned player
    char cancelQuery[512];
    g_hDB.Format(cancelQuery, sizeof(cancelQuery),
        "UPDATE mm_queue SET status='cancelled' "
        "WHERE steam_id='%s' AND status IN ('waiting','ready_check')",
        escapedTarget);
    g_hDB.Query(DB_GenericCallback, cancelQuery, _, DBPrio_High);

    LogAction(client, target,
        "[MM-Admin] %s banned %s from matchmaking for %d minutes. Reason: %s",
        adminSteamID, targetSteamID, minutes, reason);

    return Plugin_Handled;
}

public void DB_BanInserted(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int adminUserId  = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int minutes      = pack.ReadCell();
    char reason[255];
    pack.ReadString(reason, sizeof(reason));
    delete pack;

    int admin  = GetClientOfUserId(adminUserId);
    int target = GetClientOfUserId(targetUserId);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_BanInserted error: %s", error);
        if (MM_IsValidClient(admin))
            ReplyToCommand(admin, "[MM] Database error applying ban.");
        return;
    }

    if (MM_IsValidClient(admin))
    {
        char targetName[64];
        if (MM_IsValidClient(target))
            GetClientName(target, targetName, sizeof(targetName));
        else
            strcopy(targetName, sizeof(targetName), "(disconnected)");

        ReplyToCommand(admin,
            "[MM] Banned %s from matchmaking for %d minute(s). Reason: %s",
            targetName, minutes, reason);
    }

    // Notify the banned player if still in game
    if (MM_IsValidClient(target))
    {
        PrintToChat(target,
            " \x07[MM]\x01 You have been \x07banned\x01 from matchmaking for "
            "\x09%d\x01 minute(s). Reason: %s",
            minutes, reason);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !mm_unban <steamid>
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Unban(int client, int args)
{
    if (!MM_IsValidClient(client) && client != 0)
        return Plugin_Handled;

    if (args < 1)
    {
        ReplyToCommand(client, "[MM] Usage: sm_mm_unban <STEAM_X:Y:Z>");
        return Plugin_Handled;
    }

    if (g_hDB == null)
    {
        ReplyToCommand(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    char steamID[32];
    GetCmdArg(1, steamID, sizeof(steamID));

    // Basic sanity check on SteamID format
    if (StrContains(steamID, "STEAM_") == -1)
    {
        ReplyToCommand(client, "[MM] Invalid SteamID format. Expected STEAM_X:Y:Z");
        return Plugin_Handled;
    }

    char escaped[65];
    g_hDB.Escape(steamID, escaped, sizeof(escaped));

    char adminSteamID[32];
    if (client == 0)
        strcopy(adminSteamID, sizeof(adminSteamID), "CONSOLE");
    else
        MM_GetSteamID(client, adminSteamID, sizeof(adminSteamID));

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(escaped);

    char query[512];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_bans SET is_active=0 WHERE steam_id='%s' AND is_active=1",
        escaped);
    g_hDB.Query(DB_UnbanDone, query, pack, DBPrio_High);

    // Also clear mm_players ban fields
    char playerQuery[512];
    g_hDB.Format(playerQuery, sizeof(playerQuery),
        "UPDATE mm_players SET is_banned=0, ban_until=NULL WHERE steam_id='%s'",
        escaped);
    g_hDB.Query(DB_GenericCallback, playerQuery, _, DBPrio_High);

    LogAction(client, -1,
        "[MM-Admin] %s unbanned %s from matchmaking.", adminSteamID, steamID);

    return Plugin_Handled;
}

public void DB_UnbanDone(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int adminUserId = pack.ReadCell();
    char steamID[32];
    pack.ReadString(steamID, sizeof(steamID));
    delete pack;

    int admin = GetClientOfUserId(adminUserId);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_UnbanDone error: %s", error);
        if (MM_IsValidClient(admin) || admin == 0)
            ReplyToCommand(admin, "[MM] Database error removing ban.");
        return;
    }

    int affected = results.AffectedRows;
    if (affected == 0)
    {
        ReplyToCommand(admin, "[MM] No active ban found for %s.", steamID);
        return;
    }

    ReplyToCommand(admin, "[MM] Removed matchmaking ban for %s (%d row(s) updated).",
        steamID, affected);

    // If the player is currently on this server, notify them
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        char clientSteam[32];
        MM_GetSteamID(i, clientSteam, sizeof(clientSteam));
        if (StrEqual(clientSteam, steamID))
        {
            PrintToChat(i,
                " \x04[MM]\x01 Your matchmaking ban has been \x04removed\x01. "
                "You may now type \x04!queue\x01.");
            break;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !mm_setelo <#userid|name> <elo>
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_SetElo(int client, int args)
{
    if (!MM_IsValidClient(client) && client != 0)
        return Plugin_Handled;

    if (args < 2)
    {
        ReplyToCommand(client, "[MM] Usage: sm_mm_setelo <#userid|name> <elo>");
        return Plugin_Handled;
    }

    if (g_hDB == null)
    {
        ReplyToCommand(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    char targetArg[64];
    GetCmdArg(1, targetArg, sizeof(targetArg));

    char eloStr[16];
    GetCmdArg(2, eloStr, sizeof(eloStr));
    int newElo = StringToInt(eloStr);

    if (newElo < 0 || newElo > 9999)
    {
        ReplyToCommand(client, "[MM] ELO must be between 0 and 9999.");
        return Plugin_Handled;
    }

    int target = FindTargetClient(client, targetArg);
    if (target == -1)
    {
        ReplyToCommand(client, "[MM] Target not found: %s", targetArg);
        return Plugin_Handled;
    }

    char targetSteamID[32];
    GetClientAuthId(target, AuthId_Steam2, targetSteamID, sizeof(targetSteamID));

    char adminSteamID[32];
    if (client == 0)
        strcopy(adminSteamID, sizeof(adminSteamID), "CONSOLE");
    else
        MM_GetSteamID(client, adminSteamID, sizeof(adminSteamID));

    int newTier = MM_EloToTier(newElo);

    char escaped[65];
    g_hDB.Escape(targetSteamID, escaped, sizeof(escaped));

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    pack.WriteCell(newElo);
    pack.WriteCell(newTier);

    char query[512];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_players SET elo=%d, rank_tier=%d WHERE steam_id='%s'",
        newElo, newTier, escaped);
    g_hDB.Query(DB_SetEloDone, query, pack, DBPrio_High);

    // Also log to elo_history
    char histQuery[512];
    g_hDB.Format(histQuery, sizeof(histQuery),
        "INSERT INTO mm_elo_history (steam_id, elo_before, elo_after, change_reason) "
        "SELECT '%s', elo, %d, 'admin' FROM mm_players WHERE steam_id='%s'",
        escaped, newElo, escaped);
    g_hDB.Query(DB_GenericCallback, histQuery, _, DBPrio_Low);

    LogAction(client, target,
        "[MM-Admin] %s set ELO of %s to %d (tier %d).",
        adminSteamID, targetSteamID, newElo, newTier);

    return Plugin_Handled;
}

public void DB_SetEloDone(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int adminUserId  = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int newElo       = pack.ReadCell();
    int newTier      = pack.ReadCell();
    delete pack;

    int admin  = GetClientOfUserId(adminUserId);
    int target = GetClientOfUserId(targetUserId);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_SetEloDone error: %s", error);
        if (MM_IsValidClient(admin) || admin == 0)
            ReplyToCommand(admin, "[MM] Database error setting ELO.");
        return;
    }

    char targetName[64];
    if (MM_IsValidClient(target))
        GetClientName(target, targetName, sizeof(targetName));
    else
        strcopy(targetName, sizeof(targetName), "(offline)");

    char rankName[48];
    MM_GetRankName(newTier, rankName, sizeof(rankName));

    ReplyToCommand(admin,
        "[MM] Set ELO of %s to %d (%s).", targetName, newElo, rankName);

    if (MM_IsValidClient(target))
    {
        PrintToChat(target,
            " \x09[MM-Admin]\x01 An admin set your ELO to \x09%d\x01 (%s).",
            newElo, rankName);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !mm_resetrank <#userid|name>
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_ResetRank(int client, int args)
{
    if (!MM_IsValidClient(client) && client != 0)
        return Plugin_Handled;

    if (args < 1)
    {
        ReplyToCommand(client, "[MM] Usage: sm_mm_resetrank <#userid|name>");
        return Plugin_Handled;
    }

    if (g_hDB == null)
    {
        ReplyToCommand(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    char targetArg[64];
    GetCmdArg(1, targetArg, sizeof(targetArg));

    int target = FindTargetClient(client, targetArg);
    if (target == -1)
    {
        ReplyToCommand(client, "[MM] Target not found: %s", targetArg);
        return Plugin_Handled;
    }

    char targetSteamID[32];
    GetClientAuthId(target, AuthId_Steam2, targetSteamID, sizeof(targetSteamID));

    char adminSteamID[32];
    if (client == 0)
        strcopy(adminSteamID, sizeof(adminSteamID), "CONSOLE");
    else
        MM_GetSteamID(client, adminSteamID, sizeof(adminSteamID));

    char escaped[65];
    g_hDB.Escape(targetSteamID, escaped, sizeof(escaped));

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));

    char query[512];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_players SET elo=1000, rank_tier=5 WHERE steam_id='%s'",
        escaped);
    g_hDB.Query(DB_ResetRankDone, query, pack, DBPrio_High);

    // Log to elo_history
    char histQuery[512];
    g_hDB.Format(histQuery, sizeof(histQuery),
        "INSERT INTO mm_elo_history (steam_id, elo_before, elo_after, change_reason) "
        "SELECT '%s', elo, 1000, 'admin' FROM mm_players WHERE steam_id='%s'",
        escaped, escaped);
    g_hDB.Query(DB_GenericCallback, histQuery, _, DBPrio_Low);

    LogAction(client, target,
        "[MM-Admin] %s reset rank of %s to 1000 ELO (Silver Elite Master).",
        adminSteamID, targetSteamID);

    return Plugin_Handled;
}

public void DB_ResetRankDone(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int adminUserId  = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    delete pack;

    int admin  = GetClientOfUserId(adminUserId);
    int target = GetClientOfUserId(targetUserId);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_ResetRankDone error: %s", error);
        if (MM_IsValidClient(admin) || admin == 0)
            ReplyToCommand(admin, "[MM] Database error resetting rank.");
        return;
    }

    char targetName[64];
    if (MM_IsValidClient(target))
        GetClientName(target, targetName, sizeof(targetName));
    else
        strcopy(targetName, sizeof(targetName), "(offline)");

    ReplyToCommand(admin, "[MM] Reset rank of %s to 1000 ELO (Silver Elite Master).", targetName);

    if (MM_IsValidClient(target))
    {
        PrintToChat(target,
            " \x09[MM-Admin]\x01 An admin reset your rank to "
            "\x04Silver Elite Master\x01 (1000 ELO).");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !mm_status — Show system status
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Status(int client, int args)
{
    if (!MM_IsValidClient(client) && client != 0)
        return Plugin_Handled;

    if (g_hDB == null)
    {
        ReplyToCommand(client, "[MM] Database unavailable.");
        return Plugin_Handled;
    }

    // Query 1: queue depths
    g_hDB.Query(DB_StatusQueueResult,
        "SELECT status, COUNT(*) as cnt FROM mm_queue "
        "GROUP BY status",
        GetClientUserId(client), DBPrio_High);

    // Query 2: active matches
    g_hDB.Query(DB_StatusMatchesResult,
        "SELECT id, map_name, status, server_ip, server_port, started_at "
        "FROM mm_matches WHERE status IN ('creating','warmup','live','overtime') "
        "ORDER BY started_at DESC LIMIT 20",
        GetClientUserId(client), DBPrio_High);

    return Plugin_Handled;
}

public void DB_StatusQueueResult(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_StatusQueueResult error: %s", error);
        return;
    }

    ReplyToCommand(client, "[MM] ─── Queue Status ───");

    if (results.RowCount == 0)
    {
        ReplyToCommand(client, "[MM] Queue is empty.");
        return;
    }

    while (results.FetchRow())
    {
        char status[32];
        results.FetchString(0, status, sizeof(status));
        int cnt = results.FetchInt(1);
        ReplyToCommand(client, "[MM]  %-16s : %d", status, cnt);
    }
}

public void DB_StatusMatchesResult(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM-Admin] DB_StatusMatchesResult error: %s", error);
        return;
    }

    ReplyToCommand(client, "[MM] ─── Active Matches ───");

    if (results.RowCount == 0)
    {
        ReplyToCommand(client, "[MM] No active matches.");
        return;
    }

    while (results.FetchRow())
    {
        int    matchId  = results.FetchInt(0);
        char   mapName[32];  results.FetchString(1, mapName,  sizeof(mapName));
        char   status[16];   results.FetchString(2, status,   sizeof(status));
        char   ip[64];       results.FetchString(3, ip,       sizeof(ip));
        int    port     = results.FetchInt(4);
        char   started[32];  results.FetchString(5, started,  sizeof(started));

        ReplyToCommand(client,
            "[MM]  Match #%d | %s | %s | %s:%d | since %s",
            matchId, mapName, status, ip, port, started);
    }
}
