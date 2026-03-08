/**
 * csgo_mm_party.sp — CS:GO Matchmaking Party System
 *
 * Party management for the lobby server. Players can form parties of up to
 * 5 members and queue together. The party leader initiates the queue; all
 * members are inserted simultaneously.
 *
 * Commands:
 *   !party invite <name>   — invite a player to your party
 *   !party accept          — accept a pending invite
 *   !party decline         — decline a pending invite
 *   !party leave           — leave your current party
 *   !party kick <name>     — kick a member (leader only)
 *   !party list            — show party members and their ranks
 *
 * Compile: spcomp csgo_mm_party.sp -i scripting/include
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <csgo_mm>

// ─────────────────────────────────────────────────────────────────────────────
// Plugin metadata
// ─────────────────────────────────────────────────────────────────────────────

public Plugin myinfo = {
    name        = "CS:GO Matchmaking - Party",
    author      = "CSGO-MM",
    description = "Party formation and management for the lobby queue",
    version     = MM_VERSION,
    url         = ""
};

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

#define PARTY_MAX_MEMBERS       5
#define PARTY_MAX_ELO_DIFF      400
#define INVITE_EXPIRE_SEC       60
#define INVITE_CLEANUP_INTERVAL 30.0

// ─────────────────────────────────────────────────────────────────────────────
// Per-client state
// ─────────────────────────────────────────────────────────────────────────────

int  g_iPartyId           [MAXPLAYERS + 1]; // 0 = not in a party
bool g_bIsPartyLeader     [MAXPLAYERS + 1];
int  g_iPendingInviteParty[MAXPLAYERS + 1]; // party_id of pending invite, 0 = none
int  g_iElo               [MAXPLAYERS + 1]; // cached ELO for invite diff-checks

// ─────────────────────────────────────────────────────────────────────────────
// Globals
// ─────────────────────────────────────────────────────────────────────────────

Database g_hDB = null;

// ─────────────────────────────────────────────────────────────────────────────
// Plugin start / end
// ─────────────────────────────────────────────────────────────────────────────

public void OnPluginStart()
{
    Database.Connect(DB_Connected, MM_DB_NAME);

    RegConsoleCmd("sm_party", Cmd_Party, "Party management: invite/accept/decline/leave/kick/list");
    RegConsoleCmd("sm_p",     Cmd_Party, "Party management (alias)");

    CreateTimer(INVITE_CLEANUP_INTERVAL, Timer_CleanupInvites, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    LogMessage("[MM] Party plugin loaded (v%s)", MM_VERSION);
}

public void OnPluginEnd()
{
    delete g_hDB;
}

// ─────────────────────────────────────────────────────────────────────────────
// Database connection
// ─────────────────────────────────────────────────────────────────────────────

public void DB_Connected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[MM] Party: DB connection failed: %s", error);
        return;
    }

    g_hDB = db;
    g_hDB.SetCharset("utf8mb4");
    LogMessage("[MM] Party: Database connected.");
}

// ─────────────────────────────────────────────────────────────────────────────
// Client lifecycle
// ─────────────────────────────────────────────────────────────────────────────

public void OnClientPostAdminCheck(int client)
{
    if (!MM_IsValidClient(client) || g_hDB == null)
        return;

    ResetPartyState(client);

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    // Load party membership, leader status, and ELO in one query
    char query[768];
    g_hDB.Format(query, sizeof(query),
        "SELECT pm.party_id, (p.leader_id = '%s') AS is_leader, pl.elo "
        "FROM mm_party_members pm "
        "JOIN mm_parties p  ON p.id         = pm.party_id "
        "JOIN mm_players pl ON pl.steam_id  = pm.steam_id "
        "WHERE pm.steam_id = '%s' LIMIT 1",
        steamID, steamID);
    g_hDB.Query(DB_LoadPartyState, query, GetClientUserId(client), DBPrio_Normal);

    // Check for a pending invite
    char invQuery[512];
    g_hDB.Format(invQuery, sizeof(invQuery),
        "SELECT party_id FROM mm_party_invites "
        "WHERE invitee_id = '%s' AND expires_at > NOW() "
        "ORDER BY invited_at DESC LIMIT 1",
        steamID);
    g_hDB.Query(DB_LoadPendingInvite, invQuery, GetClientUserId(client), DBPrio_Normal);
}

public void DB_LoadPartyState(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;
    if (results == null || error[0] != '\0') return;
    if (!results.FetchRow()) return;

    g_iPartyId      [client] = results.FetchInt(0);
    g_bIsPartyLeader[client] = (results.FetchInt(1) == 1);
    g_iElo          [client] = results.FetchInt(2);
}

public void DB_LoadPendingInvite(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;
    if (results == null || error[0] != '\0') return;
    if (!results.FetchRow()) return;

    g_iPendingInviteParty[client] = results.FetchInt(0);
    MM_PrintToChat(client,
        "You have a pending party invite! Type \x04!party accept\x01 or \x09!party decline\x01.");
}

public void OnClientDisconnect(int client)
{
    if (g_iPartyId[client] != 0)
        HandlePartyLeave(client, true);

    ResetPartyState(client);
}

void ResetPartyState(int client)
{
    g_iPartyId           [client] = 0;
    g_bIsPartyLeader     [client] = false;
    g_iPendingInviteParty[client] = 0;
    g_iElo               [client] = 1000;
}

// ─────────────────────────────────────────────────────────────────────────────
// Fire-and-forget DB callback
// ─────────────────────────────────────────────────────────────────────────────

public void DB_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null || error[0] != '\0')
        LogError("[MM] Party DB error: %s", error);
}

// ─────────────────────────────────────────────────────────────────────────────
// !party dispatcher
// ─────────────────────────────────────────────────────────────────────────────

public Action Cmd_Party(int client, int args)
{
    if (!MM_IsValidClient(client))
        return Plugin_Handled;

    if (g_hDB == null)
    {
        MM_ErrorToChat(client, "Matchmaking service unavailable.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        if (g_iPartyId[client] != 0)
            Party_ShowList(client);
        else
            Party_ShowUsage(client);
        return Plugin_Handled;
    }

    char subcmd[32];
    GetCmdArg(1, subcmd, sizeof(subcmd));

    if (StrEqual(subcmd, "invite", false))
    {
        if (args < 2)
        {
            MM_WarnToChat(client, "Usage: \x04!party invite <player name>");
            return Plugin_Handled;
        }
        // Rebuild target name from args 2+
        char fullArgs[128];
        GetCmdArgString(fullArgs, sizeof(fullArgs));
        // Strip "invite " prefix
        int space = FindCharInString(fullArgs, ' ');
        char targetName[64];
        if (space >= 0)
            strcopy(targetName, sizeof(targetName), fullArgs[space + 1]);
        else
            strcopy(targetName, sizeof(targetName), fullArgs);

        Party_Invite(client, targetName);
    }
    else if (StrEqual(subcmd, "accept", false))
    {
        Party_Accept(client);
    }
    else if (StrEqual(subcmd, "decline", false))
    {
        Party_Decline(client);
    }
    else if (StrEqual(subcmd, "leave", false))
    {
        Party_Leave(client);
    }
    else if (StrEqual(subcmd, "kick", false))
    {
        if (args < 2)
        {
            MM_WarnToChat(client, "Usage: \x04!party kick <player name>");
            return Plugin_Handled;
        }
        char fullArgs[128];
        GetCmdArgString(fullArgs, sizeof(fullArgs));
        int space = FindCharInString(fullArgs, ' ');
        char targetName[64];
        if (space >= 0)
            strcopy(targetName, sizeof(targetName), fullArgs[space + 1]);
        else
            strcopy(targetName, sizeof(targetName), fullArgs);

        Party_Kick(client, targetName);
    }
    else if (StrEqual(subcmd, "list", false))
    {
        Party_ShowList(client);
    }
    else
    {
        Party_ShowUsage(client);
    }

    return Plugin_Handled;
}

void Party_ShowUsage(int client)
{
    MM_PrintToChat(client, "Party commands:");
    PrintToChat(client, " \x04!party invite <name>\x01 — invite a player");
    PrintToChat(client, " \x04!party accept\x01         — accept an invite");
    PrintToChat(client, " \x04!party decline\x01        — decline an invite");
    PrintToChat(client, " \x04!party leave\x01          — leave your party");
    PrintToChat(client, " \x04!party kick <name>\x01    — kick a member (leader only)");
    PrintToChat(client, " \x04!party list\x01           — show party members");
    PrintToChat(client, " Party leader queues for everyone with \x04!queue\x01.");
}

// ─────────────────────────────────────────────────────────────────────────────
// !party invite <name>
// ─────────────────────────────────────────────────────────────────────────────

void Party_Invite(int client, const char[] targetName)
{
    int target = FindClientByPartialName(client, targetName);
    if (target == -1)
    {
        MM_WarnToChat(client, "Player '\x09%s\x01' not found on this server.", targetName);
        return;
    }
    if (target == client)
    {
        MM_WarnToChat(client, "You cannot invite yourself.");
        return;
    }
    if (g_iPartyId[target] != 0)
    {
        char tName[64];
        GetClientName(target, tName, sizeof(tName));
        MM_WarnToChat(client, "\x09%s\x01 is already in a party.", tName);
        return;
    }
    if (g_iPendingInviteParty[target] != 0)
    {
        MM_WarnToChat(client, "That player already has a pending party invite.");
        return;
    }

    // ELO diff check (use cached values; defaults to 1000 if not loaded yet)
    int eloDiff = (g_iElo[client] > g_iElo[target])
        ? (g_iElo[client] - g_iElo[target])
        : (g_iElo[target] - g_iElo[client]);

    if (eloDiff > PARTY_MAX_ELO_DIFF)
    {
        char tName[64];
        GetClientName(target, tName, sizeof(tName));
        MM_WarnToChat(client,
            "Cannot invite \x09%s\x01: ELO gap is %d (max %d).",
            tName, eloDiff, PARTY_MAX_ELO_DIFF);
        return;
    }

    char steamID[32];
    char targetSteamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));
    MM_GetSteamID(target, targetSteamID, sizeof(targetSteamID));

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    pack.WriteString(steamID);
    pack.WriteString(targetSteamID);

    char query[512];
    if (g_iPartyId[client] != 0)
    {
        // Party exists — check size
        g_hDB.Format(query, sizeof(query),
            "SELECT id, leader_id, "
            "(SELECT COUNT(*) FROM mm_party_members WHERE party_id=%d) AS member_count "
            "FROM mm_parties WHERE id=%d LIMIT 1",
            g_iPartyId[client], g_iPartyId[client]);
    }
    else
    {
        // No party yet — return 0 rows to signal "create new"
        g_hDB.Format(query, sizeof(query),
            "SELECT NULL AS id, NULL AS leader_id, 0 AS member_count "
            "FROM DUAL WHERE 1=0");
    }
    g_hDB.Query(DB_InviteCheckParty, query, pack, DBPrio_High);
}

public void DB_InviteCheckParty(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int inviterUserId = pack.ReadCell();
    int targetUserId  = pack.ReadCell();
    char steamID[32];
    char targetSteamID[32];
    pack.ReadString(steamID,       sizeof(steamID));
    pack.ReadString(targetSteamID, sizeof(targetSteamID));
    delete pack;

    int inviter = GetClientOfUserId(inviterUserId);
    int target  = GetClientOfUserId(targetUserId);

    if (!MM_IsValidClient(inviter)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_InviteCheckParty error: %s", error);
        MM_ErrorToChat(inviter, "Database error. Please try again.");
        return;
    }

    if (!MM_IsValidClient(target))
    {
        MM_WarnToChat(inviter, "That player is no longer on the server.");
        return;
    }

    if (results.FetchRow())
    {
        // Party exists
        int memberCount = results.FetchInt(2);
        if (memberCount >= PARTY_MAX_MEMBERS)
        {
            MM_WarnToChat(inviter, "Your party is full (%d/%d members).",
                memberCount, PARTY_MAX_MEMBERS);
            return;
        }
        // Party has space — send invite directly
        DoSendInvite(inviterUserId, targetUserId, steamID, targetSteamID, g_iPartyId[inviter]);
    }
    else
    {
        // No party — create one with the inviter as leader
        DataPack pack2 = new DataPack();
        pack2.WriteCell(inviterUserId);
        pack2.WriteCell(targetUserId);
        pack2.WriteString(steamID);
        pack2.WriteString(targetSteamID);

        char createQuery[256];
        g_hDB.Format(createQuery, sizeof(createQuery),
            "INSERT INTO mm_parties (leader_id) VALUES ('%s')",
            steamID);
        g_hDB.Query(DB_PartyCreated, createQuery, pack2, DBPrio_High);
    }
}

public void DB_PartyCreated(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int inviterUserId = pack.ReadCell();
    int targetUserId  = pack.ReadCell();
    char steamID[32];
    char targetSteamID[32];
    pack.ReadString(steamID,       sizeof(steamID));
    pack.ReadString(targetSteamID, sizeof(targetSteamID));
    delete pack;

    int inviter = GetClientOfUserId(inviterUserId);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_PartyCreated error: %s", error);
        if (MM_IsValidClient(inviter))
            MM_ErrorToChat(inviter, "Failed to create party. Try again.");
        return;
    }

    int partyId = results.InsertId;
    if (partyId == 0)
    {
        if (MM_IsValidClient(inviter))
            MM_ErrorToChat(inviter, "Failed to create party. Try again.");
        return;
    }

    // Add inviter as first member
    char memberQuery[256];
    g_hDB.Format(memberQuery, sizeof(memberQuery),
        "INSERT IGNORE INTO mm_party_members (party_id, steam_id) VALUES (%d, '%s')",
        partyId, steamID);
    g_hDB.Query(DB_GenericCallback, memberQuery, _, DBPrio_High);

    // Update in-game state
    if (MM_IsValidClient(inviter))
    {
        g_iPartyId      [inviter] = partyId;
        g_bIsPartyLeader[inviter] = true;
    }

    DoSendInvite(inviterUserId, targetUserId, steamID, targetSteamID, partyId);
}

void DoSendInvite(int inviterUserId, int targetUserId,
                  const char[] steamID, const char[] targetSteamID, int partyId)
{
    int inviter = GetClientOfUserId(inviterUserId);
    int target  = GetClientOfUserId(targetUserId);

    // Insert or refresh invite
    char query[512];
    g_hDB.Format(query, sizeof(query),
        "INSERT INTO mm_party_invites (party_id, invitee_id, expires_at) "
        "VALUES (%d, '%s', DATE_ADD(NOW(), INTERVAL %d SECOND)) "
        "ON DUPLICATE KEY UPDATE "
        "  invited_at = NOW(), "
        "  expires_at = DATE_ADD(NOW(), INTERVAL %d SECOND)",
        partyId, targetSteamID, INVITE_EXPIRE_SEC, INVITE_EXPIRE_SEC);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);

    // Update in-game invite state
    if (MM_IsValidClient(target))
    {
        g_iPendingInviteParty[target] = partyId;

        char inviterName[64];
        if (MM_IsValidClient(inviter))
            GetClientName(inviter, inviterName, sizeof(inviterName));
        else
            strcopy(inviterName, sizeof(inviterName), "A player");

        MM_PrintToChat(target,
            "\x04%s\x01 invited you to their party! "
            "Type \x04!party accept\x01 or \x09!party decline\x01. (Expires in \x09%ds\x01)",
            inviterName, INVITE_EXPIRE_SEC);
    }

    if (MM_IsValidClient(inviter))
    {
        char targetName[64];
        if (MM_IsValidClient(target))
            GetClientName(target, targetName, sizeof(targetName));
        else
            Format(targetName, sizeof(targetName), "%s", targetSteamID);

        MM_PrintToChat(inviter, "Invite sent to \x04%s\x01. Waiting for response…", targetName);
    }

    #pragma unused steamID
}

// ─────────────────────────────────────────────────────────────────────────────
// !party accept
// ─────────────────────────────────────────────────────────────────────────────

void Party_Accept(int client)
{
    if (g_iPendingInviteParty[client] == 0)
    {
        MM_WarnToChat(client, "You have no pending party invite.");
        return;
    }
    if (g_iPartyId[client] != 0)
    {
        MM_WarnToChat(client,
            "You are already in a party. Type \x04!party leave\x01 first.");
        return;
    }

    int partyId = g_iPendingInviteParty[client];
    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamID);

    // Verify invite still valid and party not full
    char query[512];
    g_hDB.Format(query, sizeof(query),
        "SELECT "
        "  (SELECT COUNT(*) FROM mm_party_invites "
        "   WHERE party_id=%d AND invitee_id='%s' AND expires_at > NOW()) AS invite_valid, "
        "  (SELECT COUNT(*) FROM mm_party_members WHERE party_id=%d) AS member_count",
        partyId, steamID, partyId);
    g_hDB.Query(DB_AcceptVerify, query, pack, DBPrio_High);
}

public void DB_AcceptVerify(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    char steamID[32];
    pack.ReadString(steamID, sizeof(steamID));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_AcceptVerify error: %s", error);
        MM_ErrorToChat(client, "Database error. Try again.");
        g_iPendingInviteParty[client] = 0;
        return;
    }

    if (!results.FetchRow())
    {
        MM_WarnToChat(client, "Invite no longer valid.");
        g_iPendingInviteParty[client] = 0;
        return;
    }

    int inviteValid = results.FetchInt(0);
    int memberCount = results.FetchInt(1);

    if (inviteValid == 0)
    {
        MM_WarnToChat(client,
            "Your invite has expired. Ask the party leader to reinvite you.");
        g_iPendingInviteParty[client] = 0;
        return;
    }
    if (memberCount >= PARTY_MAX_MEMBERS)
    {
        MM_WarnToChat(client, "The party is now full. Cannot join.");
        g_iPendingInviteParty[client] = 0;
        return;
    }

    int partyId = g_iPendingInviteParty[client];

    // Join party
    DataPack pack2 = new DataPack();
    pack2.WriteCell(userid);
    pack2.WriteString(steamID);
    pack2.WriteCell(partyId);

    char insertQuery[256];
    g_hDB.Format(insertQuery, sizeof(insertQuery),
        "INSERT IGNORE INTO mm_party_members (party_id, steam_id) VALUES (%d, '%s')",
        partyId, steamID);
    g_hDB.Query(DB_AcceptJoined, insertQuery, pack2, DBPrio_High);

    // Delete the invite (fire-and-forget)
    char delQuery[256];
    g_hDB.Format(delQuery, sizeof(delQuery),
        "DELETE FROM mm_party_invites WHERE party_id=%d AND invitee_id='%s'",
        partyId, steamID);
    g_hDB.Query(DB_GenericCallback, delQuery, _, DBPrio_High);
}

public void DB_AcceptJoined(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid  = pack.ReadCell();
    char steamID[32];
    pack.ReadString(steamID, sizeof(steamID));
    int partyId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_AcceptJoined error: %s", error);
        if (MM_IsValidClient(client))
        {
            MM_ErrorToChat(client, "Database error joining party. Try again.");
            g_iPendingInviteParty[client] = 0;
        }
        return;
    }

    if (!MM_IsValidClient(client)) return;

    g_iPartyId           [client] = partyId;
    g_bIsPartyLeader     [client] = false;
    g_iPendingInviteParty[client] = 0;

    char playerName[64];
    GetClientName(client, playerName, sizeof(playerName));

    MM_PrintToChat(client,
        "You joined the party! Type \x04!party list\x01 to see members.");

    // Notify existing party members
    char notifMsg[256];
    Format(notifMsg, sizeof(notifMsg),
        "\x04%s\x01 joined the party! (%d/%d) | Leader queues with \x04!queue\x01.",
        playerName, 0, PARTY_MAX_MEMBERS); // Count fetched separately below

    // Fetch updated member count to send accurate notification
    DataPack pack2 = new DataPack();
    pack2.WriteCell(GetClientUserId(client));
    pack2.WriteCell(partyId);
    pack2.WriteString(playerName);

    char countQuery[256];
    g_hDB.Format(countQuery, sizeof(countQuery),
        "SELECT COUNT(*) FROM mm_party_members WHERE party_id=%d", partyId);
    g_hDB.Query(DB_AcceptNotifyCount, countQuery, pack2, DBPrio_Normal);

    #pragma unused steamID
}

public void DB_AcceptNotifyCount(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid      = pack.ReadCell();
    int partyId     = pack.ReadCell();
    char joinerName[64];
    pack.ReadString(joinerName, sizeof(joinerName));
    delete pack;

    int joiner = GetClientOfUserId(userid);
    int count  = 0;
    if (results != null && error[0] == '\0' && results.FetchRow())
        count = results.FetchInt(0);

    char msg[256];
    Format(msg, sizeof(msg),
        "\x04%s\x01 joined the party! (%d/%d) | Leader queues with \x04!queue\x01.",
        joinerName, count, PARTY_MAX_MEMBERS);
    NotifyPartyMembers(partyId, joiner, msg);
}

// ─────────────────────────────────────────────────────────────────────────────
// !party decline
// ─────────────────────────────────────────────────────────────────────────────

void Party_Decline(int client)
{
    if (g_iPendingInviteParty[client] == 0)
    {
        MM_WarnToChat(client, "You have no pending party invite.");
        return;
    }

    int partyId = g_iPendingInviteParty[client];
    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    char query[256];
    g_hDB.Format(query, sizeof(query),
        "DELETE FROM mm_party_invites WHERE party_id=%d AND invitee_id='%s'",
        partyId, steamID);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_Normal);

    g_iPendingInviteParty[client] = 0;
    MM_PrintToChat(client, "You declined the party invite.");

    // Notify the party leader in-game
    char myName[64];
    GetClientName(client, myName, sizeof(myName));
    char msg[256];
    Format(msg, sizeof(msg), "\x09%s\x01 declined your party invite.", myName);
    NotifyPartyLeader(partyId, client, msg);
}

// ─────────────────────────────────────────────────────────────────────────────
// !party leave (and internal HandlePartyLeave)
// ─────────────────────────────────────────────────────────────────────────────

void Party_Leave(int client)
{
    if (g_iPartyId[client] == 0)
    {
        MM_WarnToChat(client, "You are not in a party.");
        return;
    }
    HandlePartyLeave(client, false);
}

void HandlePartyLeave(int client, bool disconnect)
{
    int partyId  = g_iPartyId[client];
    bool wasLeader = g_bIsPartyLeader[client];

    char steamID[32];
    MM_GetSteamID(client, steamID, sizeof(steamID));

    // Cancel all party members' queue entries (harmless if not queued)
    char cancelQuery[512];
    g_hDB.Format(cancelQuery, sizeof(cancelQuery),
        "UPDATE mm_queue SET status='cancelled' "
        "WHERE status IN ('waiting','ready_check') "
        "AND steam_id IN ("
        "  SELECT steam_id FROM mm_party_members WHERE party_id=%d"
        ")",
        partyId);
    g_hDB.Query(DB_GenericCallback, cancelQuery, _, DBPrio_High);

    // Remove this player from party members
    char delQuery[256];
    g_hDB.Format(delQuery, sizeof(delQuery),
        "DELETE FROM mm_party_members WHERE party_id=%d AND steam_id='%s'",
        partyId, steamID);
    g_hDB.Query(DB_GenericCallback, delQuery, _, DBPrio_High);

    char myName[64];
    GetClientName(client, myName, sizeof(myName));

    if (!disconnect)
        MM_PrintToChat(client, "You left the party. Queue cancelled.");

    // Notify remaining members
    char msg[256];
    Format(msg, sizeof(msg),
        "\x09%s\x01 left the party. Queue cancelled — use \x04!queue\x01 to search again.",
        myName);
    NotifyPartyMembers(partyId, client, msg);

    // Reset in-game state for all remaining members (queue was cancelled)
    ResetPartyMemberQueueStates(partyId, client);

    // Reset this player's state
    ResetPartyState(client);

    if (wasLeader)
    {
        // Transfer leadership to the next oldest member
        DataPack pack = new DataPack();
        pack.WriteCell(partyId);

        char leaderQuery[256];
        g_hDB.Format(leaderQuery, sizeof(leaderQuery),
            "SELECT steam_id FROM mm_party_members WHERE party_id=%d "
            "ORDER BY joined_at ASC LIMIT 1",
            partyId);
        g_hDB.Query(DB_TransferLeadership, leaderQuery, pack, DBPrio_High);
    }
    else
    {
        // Check if party is now empty
        DataPack pack = new DataPack();
        pack.WriteCell(partyId);

        char countQuery[256];
        g_hDB.Format(countQuery, sizeof(countQuery),
            "SELECT COUNT(*) FROM mm_party_members WHERE party_id=%d",
            partyId);
        g_hDB.Query(DB_CheckPartyEmpty, countQuery, pack, DBPrio_Normal);
    }
}

public void DB_TransferLeadership(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int partyId = pack.ReadCell();
    delete pack;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_TransferLeadership error: %s", error);
        // Dissolve party as fallback
        char query[256];
        g_hDB.Format(query, sizeof(query), "DELETE FROM mm_parties WHERE id=%d", partyId);
        g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);
        return;
    }

    if (!results.FetchRow())
    {
        // No members remain — dissolve party
        char query[256];
        g_hDB.Format(query, sizeof(query), "DELETE FROM mm_parties WHERE id=%d", partyId);
        g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);
        return;
    }

    char newLeaderSteamID[32];
    results.FetchString(0, newLeaderSteamID, sizeof(newLeaderSteamID));

    // Update DB leader
    char query[256];
    g_hDB.Format(query, sizeof(query),
        "UPDATE mm_parties SET leader_id='%s' WHERE id=%d",
        newLeaderSteamID, partyId);
    g_hDB.Query(DB_GenericCallback, query, _, DBPrio_High);

    // Update in-game state for the new leader
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        if (g_iPartyId[i] != partyId) continue;

        char sid[32];
        MM_GetSteamID(i, sid, sizeof(sid));
        if (!StrEqual(sid, newLeaderSteamID)) continue;

        g_bIsPartyLeader[i] = true;
        MM_PrintToChat(i, "You are now the party leader! Queue with \x04!queue\x01.");

        char leaderName[64];
        GetClientName(i, leaderName, sizeof(leaderName));
        char notifMsg[256];
        Format(notifMsg, sizeof(notifMsg), "\x04%s\x01 is now the party leader.", leaderName);
        NotifyPartyMembers(partyId, i, notifMsg);
        break;
    }
}

public void DB_CheckPartyEmpty(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int partyId = pack.ReadCell();
    delete pack;

    if (results == null || error[0] != '\0') return;
    if (!results.FetchRow()) return;

    if (results.FetchInt(0) == 0)
    {
        char query[256];
        g_hDB.Format(query, sizeof(query), "DELETE FROM mm_parties WHERE id=%d", partyId);
        g_hDB.Query(DB_GenericCallback, query, _, DBPrio_Normal);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// !party kick <name>
// ─────────────────────────────────────────────────────────────────────────────

void Party_Kick(int client, const char[] targetName)
{
    if (g_iPartyId[client] == 0)
    {
        MM_WarnToChat(client, "You are not in a party.");
        return;
    }
    if (!g_bIsPartyLeader[client])
    {
        MM_WarnToChat(client, "Only the party leader can kick members.");
        return;
    }

    int target = FindClientByPartialName(client, targetName);
    if (target == -1)
    {
        MM_WarnToChat(client, "Player '\x09%s\x01' not found on this server.", targetName);
        return;
    }
    if (target == client)
    {
        MM_WarnToChat(client,
            "You cannot kick yourself. Use \x04!party leave\x01 instead.");
        return;
    }
    if (g_iPartyId[target] != g_iPartyId[client])
    {
        MM_WarnToChat(client, "That player is not in your party.");
        return;
    }

    int partyId = g_iPartyId[client];
    char targetSteamID[32];
    MM_GetSteamID(target, targetSteamID, sizeof(targetSteamID));
    char tName[64];
    GetClientName(target, tName, sizeof(tName));

    // Cancel kicked player's queue entry
    char cancelQuery[256];
    g_hDB.Format(cancelQuery, sizeof(cancelQuery),
        "UPDATE mm_queue SET status='cancelled' WHERE steam_id='%s' "
        "AND status IN ('waiting','ready_check')",
        targetSteamID);
    g_hDB.Query(DB_GenericCallback, cancelQuery, _, DBPrio_High);

    // Remove from party members
    char delQuery[256];
    g_hDB.Format(delQuery, sizeof(delQuery),
        "DELETE FROM mm_party_members WHERE party_id=%d AND steam_id='%s'",
        partyId, targetSteamID);
    g_hDB.Query(DB_GenericCallback, delQuery, _, DBPrio_High);

    // Update in-game state
    g_iPartyId      [target] = 0;
    g_bIsPartyLeader[target] = false;

    MM_WarnToChat(target, "You were kicked from the party.");
    MM_PrintToChat(client, "Kicked \x09%s\x01 from the party.", tName);

    char notifMsg[256];
    Format(notifMsg, sizeof(notifMsg), "\x09%s\x01 was kicked from the party.", tName);
    NotifyPartyMembers(partyId, target, notifMsg);
}

// ─────────────────────────────────────────────────────────────────────────────
// !party list
// ─────────────────────────────────────────────────────────────────────────────

void Party_ShowList(int client)
{
    if (g_iPartyId[client] == 0)
    {
        MM_WarnToChat(client,
            "You are not in a party. Type \x04!party invite <name>\x01 to create one.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));

    char query[512];
    g_hDB.Format(query, sizeof(query),
        "SELECT pl.name, pl.elo, pl.rank_tier, "
        "       (p.leader_id = pm.steam_id) AS is_leader "
        "FROM mm_party_members pm "
        "JOIN mm_players pl ON pl.steam_id = pm.steam_id "
        "JOIN mm_parties p  ON p.id        = pm.party_id "
        "WHERE pm.party_id = %d "
        "ORDER BY pm.joined_at ASC",
        g_iPartyId[client]);
    g_hDB.Query(DB_PartyList, query, pack, DBPrio_Normal);
}

public void DB_PartyList(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;

    if (results == null || error[0] != '\0')
    {
        LogError("[MM] DB_PartyList error: %s", error);
        MM_ErrorToChat(client, "Database error fetching party list.");
        return;
    }

    if (results.RowCount == 0)
    {
        MM_PrintToChat(client, "Your party appears to be empty.");
        return;
    }

    PrintToChat(client, "\x04 ─── Your Party ───");
    int count = 0;
    while (results.FetchRow())
    {
        char pName[64];
        results.FetchString(0, pName, sizeof(pName));
        int  pElo      = results.FetchInt(1);
        int  pTier     = results.FetchInt(2);
        bool isLeader  = (results.FetchInt(3) == 1);

        char rankName[48];
        MM_GetRankName(pTier, rankName, sizeof(rankName));

        if (isLeader)
            PrintToChat(client, " \x04[Leader]\x01 %s — \x09%s\x01 (ELO: \x04%d\x01)", pName, rankName, pElo);
        else
            PrintToChat(client, " %s — \x09%s\x01 (ELO: \x04%d\x01)", pName, rankName, pElo);

        count++;
    }
    PrintToChat(client,
        " \x07%d/%d members\x01 | Party leader queues with \x04!queue\x01",
        count, PARTY_MAX_MEMBERS);
}

// ─────────────────────────────────────────────────────────────────────────────
// Timer: Cleanup expired invites (every 30s)
// ─────────────────────────────────────────────────────────────────────────────

public Action Timer_CleanupInvites(Handle timer)
{
    if (g_hDB == null)
        return Plugin_Continue;

    g_hDB.Query(DB_GenericCallback,
        "DELETE FROM mm_party_invites WHERE expires_at < NOW()",
        _, DBPrio_Low);

    // Verify in-game pending invite state for each player
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        if (g_iPendingInviteParty[i] == 0) continue;

        DataPack pack = new DataPack();
        pack.WriteCell(GetClientUserId(i));

        char steamID[32];
        MM_GetSteamID(i, steamID, sizeof(steamID));

        char query[512];
        g_hDB.Format(query, sizeof(query),
            "SELECT id FROM mm_party_invites "
            "WHERE party_id=%d AND invitee_id='%s' AND expires_at > NOW() LIMIT 1",
            g_iPendingInviteParty[i], steamID);
        g_hDB.Query(DB_InviteExpired, query, pack, DBPrio_Low);
    }

    return Plugin_Continue;
}

public void DB_InviteExpired(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!MM_IsValidClient(client)) return;
    if (results == null || error[0] != '\0') return;

    if (!results.FetchRow())
        g_iPendingInviteParty[client] = 0; // Invite gone
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility: partial name match (case-insensitive); returns -1 if 0 or >1 match
// ─────────────────────────────────────────────────────────────────────────────

int FindClientByPartialName(int searcher, const char[] partial)
{
    int found      = -1;
    int foundCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        if (i == searcher) continue;

        char name[64];
        GetClientName(i, name, sizeof(name));

        if (StrContains(name, partial, false) >= 0)
        {
            found = i;
            foundCount++;
        }
    }

    if (foundCount == 1)
        return found;

    if (foundCount > 1 && MM_IsValidClient(searcher))
        MM_WarnToChat(searcher,
            "Multiple players match '\x09%s\x01'. Be more specific.", partial);

    return -1;
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility: notify all in-game party members except `exclude`
// ─────────────────────────────────────────────────────────────────────────────

void NotifyPartyMembers(int partyId, int exclude, const char[] msg)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        if (i == exclude) continue;
        if (g_iPartyId[i] != partyId) continue;
        MM_PrintToChat(i, "%s", msg);
    }
}

void NotifyPartyLeader(int partyId, int exclude, const char[] msg)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        if (i == exclude) continue;
        if (g_iPartyId[i] != partyId) continue;
        if (!g_bIsPartyLeader[i]) continue;
        MM_PrintToChat(i, "%s", msg);
        break;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility: warn all in-game party members that their queue was cancelled
// (queue plugin's poll timer will sync DB state within 2s automatically)
// ─────────────────────────────────────────────────────────────────────────────

void ResetPartyMemberQueueStates(int partyId, int exclude)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!MM_IsValidClient(i)) continue;
        if (i == exclude) continue;
        if (g_iPartyId[i] != partyId) continue;
        MM_WarnToChat(i,
            "Queue cancelled. Type \x04!queue\x01 to search again when your party is ready.");
    }
}
