# CSGO-Matchmaking — Mémoire projet

## Architecture résumée
- **Lobby server** : SourceMod plugins dans `lobby-server/sourcemod/scripting/`
- **Match server** : SourceMod plugin dans `match-server/sourcemod/scripting/csgo_mm_match.sp`
- **Matchmaker** : Python daemon dans `matchmaker/` (backends ABC swappables)
- **Web panel** : Flask dans `web-panel/` (routes séparées par blueprint)
- **DB** : MySQL 8.0, schéma dans `database/schema.sql`

## Conventions
- Toutes les communications in-game aux joueurs sont **en anglais**
- Pas de ban pour refus de ready check — uniquement pour abandon live
- Surrender = défaite inconditionnelle de l'équipe qui surrendre (ignorer le score)
- SourcePawn compilé par CI (0 warning imposé)

## Roadmap UX approuvée — **COMPLÈTE**
Plan complet dans `/Users/npichon/.claude/plans/tidy-doodling-sedgewick.md`

Toutes les phases implémentées :
- Phases 1-2 : DB migrations, fix warmup, abandon penalties, ELO notif, !lastmatch, wait time/position
- Phase 3 : Party system (csgo_mm_party.sp, mysql_queue.py, queue.sp)
- Phase 4 : Surrender vote + report system (match.sp + web admin)
- Phase 5 : Map vote, knife round, end-of-match stats, tactical pause (match.sp)
- Phase 6 : Avoid player, !recent, seasons (SeasonManager), home page (index.html), Discord enrichi
- Phase 7 : Persistent HUD (Timer_UpdateHUD, HUD_INTERVAL=2s, PrintHintText)
- Phase 8 : Admin panel (login.html + admins.html)

## Fichiers importants créés/modifiés
- `lobby-server/sourcemod/scripting/csgo_mm_party.sp` — nouveau plugin party
- `matchmaker/season_manager.py` — SeasonManager (soft ELO reset)
- `web-panel/routes/home.py` + `templates/index.html` — page d'accueil
- `web-panel/routes/admin.py` — reports, seasons, admins routes
- `matchmaker/backends/discord_notifier.py` — scoreboards + rank-up profile URL

## Fichiers clés
- `matchmaker/config.py` — WARMUP_TIMEOUT à changer 300→180
- `matchmaker/backends/elo_ranking.py` — calculate_match_results
- `matchmaker/backends/mysql_queue.py` — find_balanced_match (avoid check ici)
- `matchmaker/matchmaker.py` — _process_match_result, _step_cancel_timed_out_warmups
- `lobby-server/sourcemod/scripting/csgo_mm_queue.sp` — queue commands
- `match-server/sourcemod/scripting/csgo_mm_match.sp` — match lifecycle
- `database/schema.sql` — schéma DB

## DB — colonnes à ajouter (migrations phase 1)
- `mm_match_players.elo_notified TINYINT(1) DEFAULT 0`
- `mm_players.abandon_count INT DEFAULT 0`
- `mm_players.last_abandon_at DATETIME NULL`
- `mm_matches.surrendered TINYINT(1) DEFAULT 0`
- Nouvelles tables : mm_parties, mm_party_members, mm_party_invites, mm_avoid_list, mm_reports

## Barème abandon
1→30min, 2→2h, 3→24h, 4→7j, 5+→30j
Décroissance : si last_abandon_at > 14 jours, effective_count = max(0, abandon_count-1)
No-show warmup : 5 min max, pas d'abandon_count incrémenté
