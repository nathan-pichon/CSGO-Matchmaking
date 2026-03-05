# Guide d'utilisation — CS:GO Matchmaking

Ce document explique comment utiliser le système de matchmaking en tant que joueur, ainsi que les outils disponibles pour les administrateurs de serveur.

---

## Table des matières

1. [Rejoindre le lobby](#rejoindre-le-lobby)
2. [Commandes joueur](#commandes-joueur)
3. [Flux de matchmaking](#flux-de-matchmaking)
4. [Phase de vérification (Ready Check)](#phase-de-vérification-ready-check)
5. [Système de ranking ELO](#système-de-ranking-elo)
6. [Commandes administrateur](#commandes-administrateur)
7. [Panneau web](#panneau-web)
8. [Gestion du lobby](#gestion-du-lobby)

---

## Rejoindre le lobby

Le lobby est le point d'entrée de toutes les parties. Connectez-vous via la console CS:GO :

```
connect IP:27015
```

Remplacez `IP` par l'adresse IP publique du serveur communiquée par votre administrateur.

Une fois connecté au lobby, vous pouvez rejoindre la file d'attente et accéder à toutes les commandes de matchmaking depuis le chat en jeu.

---

## Commandes joueur

Toutes les commandes sont saisies dans le **chat en jeu** (touche `Y` par défaut). Un délai de **5 secondes** est appliqué entre chaque commande pour éviter les abus.

### File d'attente

| Commande                 | Description |
|--------------------------|-------------|
| `!queue` ou `!q`         | Rejoindre la file d'attente sans préférence de carte. Le matchmaker choisira la carte automatiquement parmi les cartes disponibles. |
| `!queue <carte>`         | Rejoindre la file d'attente en exprimant une préférence pour une carte spécifique. Le système tentera de regrouper des joueurs ayant la même préférence. |
| `!leave` ou `!unqueue`   | Quitter la file d'attente. Utilisez cette commande avant de vous déconnecter pour libérer votre place. |
| `!status`                | Afficher votre statut actuel dans la file d'attente : position, temps d'attente écoulé et préférence de carte. |

**Cartes disponibles :**

| Identifiant      | Carte       |
|------------------|-------------|
| `de_dust2`       | Dust II     |
| `de_mirage`      | Mirage      |
| `de_inferno`     | Inferno     |
| `de_ancient`     | Ancient     |
| `de_nuke`        | Nuke        |
| `de_overpass`    | Overpass    |
| `de_vertigo`     | Vertigo     |

**Exemples :**

```
!queue de_mirage
!queue de_dust2
!q
!leave
```

### Statistiques et classement

| Commande  | Description |
|-----------|-------------|
| `!rank`   | Afficher votre rang actuel, votre score ELO, votre ratio victoires/défaites (W/L) et votre ratio kills/morts (K/D). |
| `!top`    | Afficher le classement des 10 meilleurs joueurs du serveur, triés par ELO décroissant. |
| `!stats`  | Afficher vos statistiques détaillées : kills totaux, morts, assistances, headshots, série de victoires en cours, meilleure série, taux de victoire et pourcentage de headshots. |

**Exemple de sortie `!rank` :**

```
[MM] VotreNom | Rang : Master Guardian I | ELO : 1042 | W/L : 18/12 | K/D : 1.24
```

**Exemple de sortie `!stats` :**

```
[MM] VotreNom | Kills : 412 | Morts : 332 | Assistances : 87
     Headshots : 198 (48%) | Série actuelle : 3W | Meilleure série : 7W
     Taux de victoire : 60% | Parties jouées : 30
```

---

## Flux de matchmaking

Voici le déroulement complet d'une partie, de l'entrée en file d'attente à la fin du match.

```
Joueur → connect IP:27015
         ↓
    Lobby CS:GO
         ↓
    !queue [carte]
         ↓
    File d'attente (mm_queue)
         ↓
    Matchmaker trouve 10 joueurs compatibles en ELO
         ↓
    Phase de vérification — Ready Check (30 secondes)
         ↓
    Tous acceptent
         ↓
    Lancement d'un conteneur Docker (serveur de match dédié)
         ↓
    Connexion automatique des 10 joueurs au serveur de match
         ↓
    Partie compétitive 5v5 (MR30, overtime activé)
         ↓
    Fin de partie → Sauvegarde des stats et calcul ELO
         ↓
    Compte à rebours 15 secondes
         ↓
    Redirection automatique vers le lobby
```

**Détails de la formation des équipes :**

Les équipes sont composées via un **snake draft** basé sur l'ELO :
- Les 10 joueurs sont triés par ELO décroissant.
- Le joueur 1 va en équipe A, le 2 en B, le 3 en B, le 4 en A, le 5 en A, et ainsi de suite.
- Ce système assure une répartition équilibrée des niveaux entre les deux équipes.

---

## Phase de vérification (Ready Check)

Lorsque le matchmaker a trouvé 10 joueurs compatibles, une **fenêtre de confirmation** apparaît sur l'écran de chaque joueur.

- La fenêtre indique : la carte sélectionnée et un compte à rebours de **30 secondes**.
- Cliquez sur **ACCEPTER** pour confirmer votre participation.
- Si vous cliquez sur **REFUSER** ou si le délai expire sans réponse :
  - Vous recevez un **ban temporaire de 5 minutes** de la file d'attente.
  - Les autres joueurs qui avaient accepté sont renvoyés en file d'attente automatiquement.

> Si vous devez vous absenter brièvement, utilisez `!leave` avant que le ready check se déclenche pour éviter le ban.

---

## Système de ranking ELO

### Démarrage

Tout nouveau joueur commence avec un ELO de **1000** (Master Guardian I).

### Paliers

| Palier | Rang                          | Plage ELO   |
|--------|-------------------------------|-------------|
| 1      | Silver I                      | 0 – 99      |
| 2      | Silver II                     | 100 – 199   |
| 3      | Silver III                    | 200 – 299   |
| 4      | Silver IV                     | 300 – 399   |
| 5      | Silver Elite                  | 400 – 499   |
| 6      | Silver Elite Master           | 500 – 599   |
| 7      | Gold Nova I                   | 600 – 699   |
| 8      | Gold Nova II                  | 700 – 799   |
| 9      | Gold Nova III                 | 800 – 899   |
| 10     | Gold Nova Master              | 900 – 999   |
| 11     | Master Guardian I             | 1000 – 1099 |
| 12     | Master Guardian II            | 1100 – 1199 |
| 13     | Master Guardian Elite         | 1200 – 1299 |
| 14     | Distinguished Master Guardian | 1300 – 1499 |
| 15     | Legendary Eagle               | 1500 – 1699 |
| 16     | Legendary Eagle Master        | 1700 – 1899 |
| 17     | Supreme Master First Class    | 1900 – 2099 |
| 18     | Global Elite                  | 2100 +      |

### Facteur K

Le gain ou la perte d'ELO par partie dépend du **facteur K** appliqué à votre profil :

| Situation                                        | Facteur K | Effet |
|--------------------------------------------------|-----------|-------|
| Parties de placement (< 10 parties jouées)       | **64**    | Variations importantes pour un positionnement rapide |
| Joueur établi (10 à 30 parties)                  | **32**    | Variations standard |
| Joueur vétéran (> 30 parties)                    | **24**    | Variations réduites pour une plus grande stabilité |

### Progression

- La **victoire** rapporte des points ELO, la **défaite** en retire.
- Le nombre de points gagnés ou perdus dépend de l'écart d'ELO entre les deux équipes : battre une équipe plus forte rapporte davantage.
- Les performances individuelles (kills, headshots) n'influencent pas directement l'ELO — seul le résultat de la partie compte.

---

## Commandes administrateur

Les commandes administrateur nécessitent le drapeau **ADMFLAG_ROOT** (accès root SourceMod). Elles sont saisies dans le chat en jeu avec le préfixe `!`.

| Commande                                          | Description |
|---------------------------------------------------|-------------|
| `!mm_forcestart`                                  | Forcer le lancement d'une partie avec les joueurs actuellement en file d'attente. Requiert un minimum de **2 joueurs**. Utile pour les tests. |
| `!mm_cancelqueue`                                 | Annuler toutes les entrées en attente dans la file d'attente et renvoyer les joueurs à l'état disponible. |
| `!mm_ban <#userid\|nom> <minutes> <raison>`       | Bannir un joueur de la file de matchmaking pour une durée définie en minutes. Utilisez `#userid` (ex. `#42`) ou le nom du joueur. |
| `!mm_unban <STEAM_X:Y:Z>`                         | Lever le ban d'un joueur identifié par son SteamID (format `STEAM_0:1:12345678`). |
| `!mm_setelo <#userid\|nom> <elo>`                 | Définir manuellement l'ELO d'un joueur. La valeur doit être comprise entre **0 et 9999**. |
| `!mm_resetrank <#userid\|nom>`                    | Remettre l'ELO d'un joueur à la valeur par défaut (**1000**) et réinitialiser son compteur de parties de placement. |
| `!mm_status`                                      | Afficher un résumé en temps réel : nombre de parties actives, nombre de joueurs en file d'attente par statut, et liste des serveurs de match en cours. |

**Exemples d'utilisation :**

```
!mm_ban #42 30 Comportement toxique
!mm_unban STEAM_0:1:12345678
!mm_setelo TopFragger 1800
!mm_resetrank #7
!mm_forcestart
!mm_status
```

> Les commandes admin sont enregistrées dans les logs SourceMod avec l'identité de l'administrateur ayant agi.

---

## Panneau web

Le panneau web est accessible à l'adresse `http://IP:5000` (remplacez `IP` par l'adresse du serveur).

### Pages disponibles

| URL                        | Description |
|----------------------------|-------------|
| `/leaderboard`             | Classement paginé de tous les joueurs, trié par ELO décroissant. Filtrable par saison. |
| `/player/<steam_id>`       | Profil complet d'un joueur : graphique d'évolution de l'ELO dans le temps, historique des parties récentes, statistiques détaillées. |
| `/matches`                 | Liste des parties récentes avec date, carte, scores et durée. |
| `/match/<id>`              | Tableau de bord complet d'une partie : K/D/A, headshots, MVP, variation d'ELO pour chaque joueur. |

### API REST

Des endpoints JSON sont disponibles pour intégrer les données dans des outils externes (bots Discord, sites web, dashboards) :

| Endpoint                   | Description |
|----------------------------|-------------|
| `GET /api/queue/count`     | Retourne le nombre de joueurs actuellement en file d'attente. |
| `GET /api/player/<id>`     | Retourne le profil JSON d'un joueur (ELO, rang, statistiques). |
| `GET /api/leaderboard`     | Retourne le classement complet au format JSON. Paramètre optionnel : `?season=N`. |
| `GET /api/matches`         | Retourne la liste des parties récentes au format JSON. |

**Exemple de réponse `/api/queue/count` :**

```json
{
  "count": 7,
  "updated_at": "2026-03-05T14:32:11Z"
}
```

**Exemple de réponse `/api/player/<id>` :**

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

## Gestion du lobby

Cette section s'adresse aux opérateurs de serveur.

### Détection AFK

- Un joueur resté en **spectateur pendant 5 minutes consécutives** est automatiquement retiré de la file d'attente.
- Il reçoit un message de notification dans le chat lui indiquant qu'il a été sorti de la queue.
- Il peut se remettre en file d'attente en tapant `!queue` dès qu'il rejoint une équipe ou interagit avec le serveur.

### Expiration de la file d'attente

- Une entrée en file d'attente expire automatiquement après **15 minutes** sans qu'une partie ait pu être formée.
- Le joueur est notifié par un message chat et doit taper `!queue` pour se remettre en attente.
- Ce mécanisme évite les entrées orphelines en base de données lors de déconnexions silencieuses.

### Messages de broadcast automatiques

- Toutes les **2 minutes**, le serveur de lobby envoie un message broadcast à tous les joueurs connectés indiquant le nombre de joueurs actuellement en file d'attente.

Exemple :

```
[MM] 6 joueur(s) en file d'attente. Tapez !queue pour rejoindre !
```

### Bonnes pratiques pour les opérateurs

- Surveillez régulièrement les logs du matchmaker (`matchmaker/logs/`) pour détecter les erreurs de lancement de conteneurs.
- Utilisez `!mm_status` en jeu pour vérifier l'état général du système sans accéder au serveur.
- En cas de partie bloquée (serveur de match inaccessible), annulez manuellement la partie via l'interface Docker (`docker ps` / `docker stop <container>`) puis videz la queue avec `!mm_cancelqueue`.
- Planifiez les redémarrages du lobby en dehors des heures de pointe pour éviter d'interrompre des parties en cours.
