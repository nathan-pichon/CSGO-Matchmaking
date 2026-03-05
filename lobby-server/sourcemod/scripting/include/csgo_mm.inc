/**
 * csgo_mm.inc — Shared include for all CS:GO Matchmaking plugins
 *
 * Provides constants, rank data, and utility stocks shared between
 * csgo_mm_queue.sp, csgo_mm_notify.sp, and csgo_mm_admin.sp.
 *
 * Include this file with: #include <csgo_mm>
 * (Place in addons/sourcemod/scripting/include/)
 */

#if defined _csgo_mm_included
  #endinput
#endif
#define _csgo_mm_included

// ─────────────────────────────────────────────────────────────────────────────
// Version & database
// ─────────────────────────────────────────────────────────────────────────────

#define MM_VERSION        "1.0.0"
#define MM_DB_NAME        "csgo_matchmaking"

// ─────────────────────────────────────────────────────────────────────────────
// Chat prefixes (colour codes are CS:GO chat colour escapes)
//   \x01 = default/white   \x02 = team/green
//   \x04 = light green     \x06 = pink/magenta
//   \x07 = grey            \x09 = orange
//   \x0B = light yellow    \x0C = red
// ─────────────────────────────────────────────────────────────────────────────

#define MM_PREFIX         " \x02[MM]\x01 "      // [MM] in green, then reset to white
#define MM_PREFIX_WARN    " \x09[MM]\x01 "      // [MM] in orange
#define MM_PREFIX_ERROR   " \x07[MM]\x01 "      // [MM] in red  (\x07 = grey in many contexts; use \x0C for true red)
#define MM_PREFIX_GOOD    " \x04[MM]\x01 "      // [MM] in light green

// ─────────────────────────────────────────────────────────────────────────────
// Queue / match status strings (must exactly match DB ENUM values)
// ─────────────────────────────────────────────────────────────────────────────

#define QUEUE_STATUS_WAITING      "waiting"
#define QUEUE_STATUS_READY_CHECK  "ready_check"
#define QUEUE_STATUS_MATCHED      "matched"
#define QUEUE_STATUS_EXPIRED      "expired"
#define QUEUE_STATUS_CANCELLED    "cancelled"

#define MATCH_STATUS_CREATING     "creating"
#define MATCH_STATUS_WARMUP       "warmup"
#define MATCH_STATUS_LIVE         "live"
#define MATCH_STATUS_FINISHED     "finished"
#define MATCH_STATUS_CANCELLED    "cancelled"

// ─────────────────────────────────────────────────────────────────────────────
// Rank data — 18 tiers (0 = Silver I … 17 = The Global Elite)
// ─────────────────────────────────────────────────────────────────────────────

static const char g_sRankNames[18][] = {
    "Silver I",                     // 0
    "Silver II",                    // 1
    "Silver III",                   // 2
    "Silver IV",                    // 3
    "Silver Elite",                 // 4
    "Silver Elite Master",          // 5
    "Gold Nova I",                  // 6
    "Gold Nova II",                 // 7
    "Gold Nova III",                // 8
    "Gold Nova Master",             // 9
    "Master Guardian I",            // 10
    "Master Guardian II",           // 11
    "Master Guardian Elite",        // 12
    "Distinguished Master Guardian",// 13
    "Legendary Eagle",              // 14
    "Legendary Eagle Master",       // 15
    "Supreme Master First Class",   // 16
    "The Global Elite"              // 17
};

// Per-rank chat colour codes for decorated output
static const char g_sRankColors[18][] = {
    "\x07", "\x07", "\x07", "\x07", // 0-3  Silver I-IV     : grey
    "\x0B", "\x0B",                 // 4-5  Silver Elite(M) : light yellow
    "\x09", "\x09", "\x09", "\x09", // 6-9  Gold Nova I-M   : orange
    "\x04", "\x04", "\x04", "\x04", // 10-13 MG I–DMG       : light green
    "\x0C", "\x0C",                 // 14-15 LE / LEM        : red
    "\x06",                         // 16   SMFC             : pink
    "\x03"                          // 17   Global Elite     : green
};

// ─────────────────────────────────────────────────────────────────────────────
// Utility stocks
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Copies the display name for `tier` into `buffer`.
 * Clamps out-of-range values to tier 0.
 */
stock void MM_GetRankName(int tier, char[] buffer, int maxlen)
{
    if (tier < 0 || tier > 17)
        tier = 0;
    strcopy(buffer, maxlen, g_sRankNames[tier]);
}

/**
 * Returns the chat colour string for `tier` (never NULL).
 * Callers should not free the returned pointer.
 */
stock void MM_GetRankColor(int tier, char[] buffer, int maxlen)
{
    if (tier < 0 || tier > 17)
        tier = 0;
    strcopy(buffer, maxlen, g_sRankColors[tier]);
}

/**
 * Sends a formatted chat message to `client` prefixed with MM_PREFIX.
 * Supports the same format specifiers as Format().
 */
stock void MM_PrintToChat(int client, const char[] format, any ...)
{
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 3);
    PrintToChat(client, "%s%s", MM_PREFIX, buffer);
}

/**
 * Broadcasts a formatted chat message to all clients, prefixed with MM_PREFIX.
 */
stock void MM_PrintToChatAll(const char[] format, any ...)
{
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);
    PrintToChatAll("%s%s", MM_PREFIX, buffer);
}

/**
 * Sends a formatted chat message using the WARNING prefix (orange).
 */
stock void MM_WarnToChat(int client, const char[] format, any ...)
{
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 3);
    PrintToChat(client, "%s%s", MM_PREFIX_WARN, buffer);
}

/**
 * Sends a formatted chat message using the ERROR prefix (red/grey).
 */
stock void MM_ErrorToChat(int client, const char[] format, any ...)
{
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 3);
    PrintToChat(client, "%s%s", MM_PREFIX_ERROR, buffer);
}

/**
 * Returns true for a real, connected, non-bot client slot.
 */
stock bool MM_IsValidClient(int client)
{
    return (client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client));
}

/**
 * Fills `buffer` with the client's Steam2 auth string ("STEAM_X:Y:Z").
 */
stock void MM_GetSteamID(int client, char[] buffer, int maxlen)
{
    GetClientAuthId(client, AuthId_Steam2, buffer, maxlen);
}

/**
 * Returns the current ELO tier for a given ELO value.
 * Thresholds are approximate; adjust to taste.
 *
 *  0-799   → tier 0-1
 *  800-999 → tier 2-3
 *  …
 */
stock int MM_EloToTier(int elo)
{
    if (elo <  700)  return 0;
    if (elo <  800)  return 1;
    if (elo <  900)  return 2;
    if (elo < 1000)  return 3;
    if (elo < 1100)  return 4;
    if (elo < 1200)  return 5;
    if (elo < 1350)  return 6;
    if (elo < 1500)  return 7;
    if (elo < 1650)  return 8;
    if (elo < 1800)  return 9;
    if (elo < 1950)  return 10;
    if (elo < 2100)  return 11;
    if (elo < 2250)  return 12;
    if (elo < 2400)  return 13;
    if (elo < 2550)  return 14;
    if (elo < 2700)  return 15;
    if (elo < 2850)  return 16;
    return 17;
}
