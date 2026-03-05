# Référence de configuration — `config.env`

Ce document décrit l'ensemble des variables de configuration disponibles dans le fichier `config.env`.
Copiez `config.example.env` en `config.env` et adaptez chaque valeur à votre environnement avant le premier démarrage.

> **Important :** Ne commitez jamais votre fichier `config.env` dans un dépôt public. Il contient des secrets (mots de passe, clés, webhooks).

---

## Table des matières

1. [Base de données](#base-de-données)
2. [Serveur de lobby](#serveur-de-lobby)
3. [Matchmaking](#matchmaking)
4. [Système ELO](#système-elo)
5. [Backends](#backends)
6. [Docker](#docker)
7. [Panneau web](#panneau-web)
8. [Discord](#discord)
9. [Levels Ranks (LR)](#levels-ranks-lr)
10. [Système de ranking ELO — Paliers](#système-de-ranking-elo--paliers)

---

## Base de données

Ces variables configurent la connexion à la base de données MariaDB/MySQL utilisée par tous les composants.

| Variable  | Valeur par défaut  | Description |
|-----------|--------------------|-------------|
| `DB_HOST` | `localhost`        | Adresse IP ou nom d'hôte du serveur de base de données. Utilisez `db` si vous passez par le réseau Docker Compose. |
| `DB_PORT` | `3306`             | Port TCP du serveur MySQL/MariaDB. Modifier uniquement si votre instance écoute sur un port non standard. |
| `DB_USER` | `csgo_mm`          | Nom d'utilisateur MySQL. Doit correspondre à l'utilisateur créé lors de l'installation. |
| `DB_PASS` | `CHANGE_ME`        | Mot de passe de l'utilisateur MySQL. **Obligatoire à modifier** avant la mise en production. |
| `DB_NAME` | `csgo_matchmaking` | Nom de la base de données. La base doit exister et l'utilisateur doit disposer de tous les privilèges sur celle-ci. |

**Remarques :**
- En environnement Docker Compose, `DB_HOST` doit correspondre au nom du service (ex. `db`) plutôt qu'à `localhost`.
- Assurez-vous que le port `DB_PORT` est accessible depuis le serveur de lobby, le matchmaker et le panneau web.

---

## Serveur de lobby

Ces variables contrôlent les adresses d'écoute du serveur de jeu SourceMod et du composant lobby.

| Variable      | Valeur par défaut | Description |
|---------------|-------------------|-------------|
| `SERVER_IP`   | `0.0.0.0`         | Adresse IP publique ou interface d'écoute principale du serveur de jeu. Utilisez `0.0.0.0` pour écouter sur toutes les interfaces, ou spécifiez une IP précise pour restreindre l'accès. |
| `LOBBY_IP`    | `0.0.0.0`         | Adresse d'écoute du serveur de lobby CS:GO. Généralement identique à `SERVER_IP`. |
| `LOBBY_PORT`  | `27015`           | Port UDP/TCP du serveur de lobby. C'est le port auquel les joueurs se connectent via `connect IP:27015`. |
| `RCON_PASSWORD` | `CHANGE_ME`     | Mot de passe RCON du serveur de lobby. Utilisé par le matchmaker pour envoyer des commandes à distance (déplacement des joueurs, messages, etc.). **Obligatoire à modifier.** |

**Remarques :**
- Si vous déployez derrière un pare-feu ou un NAT, `SERVER_IP` doit contenir l'IP publique réelle du serveur.
- Le port `LOBBY_PORT` doit être ouvert en UDP dans votre pare-feu.
- Un `RCON_PASSWORD` faible expose votre serveur à des prises de contrôle malveillantes.

---

## Matchmaking

Ces variables pilotent le comportement du matchmaker : fréquence de vérification, composition des équipes et délais.

| Variable                        | Valeur par défaut | Description |
|---------------------------------|-------------------|-------------|
| `POLL_INTERVAL`                 | `2.0`             | Intervalle en secondes entre chaque cycle de vérification de la file d'attente par le matchmaker. Une valeur plus faible réduit la latence de formation des parties, mais augmente la charge sur la base de données. Valeur recommandée : `1.0` à `5.0`. |
| `PLAYERS_PER_TEAM`              | `5`               | Nombre de joueurs par équipe. Valeur standard CS:GO : `5`. Pour des modes de test ou des parties personnalisées, vous pouvez réduire à `1` ou `2`. |
| `MAX_ELO_SPREAD`                | `200`             | Écart ELO maximum autorisé entre les joueurs au moment de la formation initiale d'une partie. Un écart plus faible garantit des parties équilibrées mais allonge les temps d'attente. |
| `ELO_SPREAD_INCREASE_INTERVAL`  | `60`              | Durée en secondes après laquelle la tolérance d'écart ELO est élargie si aucune partie n'a pu être formée. Permet de réduire les temps d'attente en cas de faible population. |
| `ELO_SPREAD_INCREASE_AMOUNT`    | `50`              | Valeur d'ELO ajoutée à la tolérance d'écart à chaque intervalle défini par `ELO_SPREAD_INCREASE_INTERVAL`. |
| `READY_CHECK_TIMEOUT`           | `30`              | Délai en secondes accordé aux joueurs pour accepter ou refuser la partie lors de la phase de vérification. Passé ce délai, les joueurs n'ayant pas répondu reçoivent un ban temporaire. |
| `WARMUP_TIMEOUT`                | `180`             | Durée maximale en secondes de la phase de warm-up sur le serveur de match, dans l'attente que tous les joueurs se connectent. Au-delà, la partie est annulée et les joueurs sont renvoyés vers le lobby. |
| `MIN_PLACEMENT_MATCHES`         | `10`              | Nombre de parties de placement obligatoires avant qu'un joueur soit considéré comme « classé ». Pendant cette période, le facteur K ELO est plus élevé (`ELO_K_FACTOR_NEW`). |

**Remarques :**
- `PLAYERS_PER_TEAM` modifie le nombre total de joueurs requis pour lancer une partie : `PLAYERS_PER_TEAM × 2`.
- L'algorithme d'élargissement progressif (`ELO_SPREAD_INCREASE_INTERVAL` + `ELO_SPREAD_INCREASE_AMOUNT`) s'applique individuellement à chaque joueur en file d'attente, en fonction de son temps d'attente personnel.

---

## Système ELO

Ces variables configurent le moteur de calcul ELO utilisé pour les gains et pertes de points après chaque partie.

| Variable           | Valeur par défaut | Description |
|--------------------|-------------------|-------------|
| `ELO_K_FACTOR`     | `32`              | Facteur K standard appliqué aux joueurs ayant terminé leur période de placement (≥ `MIN_PLACEMENT_MATCHES` parties). Détermine la variation maximale d'ELO par partie. |
| `ELO_K_FACTOR_NEW` | `64`              | Facteur K utilisé pendant la période de placement (< `MIN_PLACEMENT_MATCHES` parties). Plus élevé pour permettre un positionnement rapide dans le classement. |
| `ELO_DEFAULT`      | `1000`            | Score ELO attribué à tout nouveau joueur n'ayant pas encore de score enregistré. Correspond au rang Master Guardian I. |

**Remarques :**
- Plus le facteur K est élevé, plus les gains et pertes d'ELO sont importants après chaque partie.
- Un facteur K de `32` correspond à la valeur classique utilisée aux échecs pour les joueurs établis.
- Il est possible d'implémenter un troisième palier (ex. K=24 pour les joueurs vétérans avec plus de 30 parties) directement dans le code du matchmaker.

---

## Backends

Ces variables sélectionnent les implémentations modulaires utilisées pour chaque sous-système. Chaque backend correspond à un pilote interchangeable.

| Variable                | Valeur par défaut | Valeurs possibles              | Description |
|-------------------------|-------------------|--------------------------------|-------------|
| `QUEUE_BACKEND`         | `mysql`           | `mysql`                        | Pilote de gestion de la file d'attente. Actuellement seul `mysql` est supporté. |
| `SERVER_BACKEND`        | `docker`          | `docker`                       | Pilote de provisionnement des serveurs de match. `docker` lance un conteneur par partie. |
| `NOTIFICATION_BACKEND`  | `discord`         | `discord`, `none`              | Pilote de notification externe. `discord` envoie des messages via webhook. `none` désactive les notifications. |
| `RANKING_BACKEND`       | `elo`             | `elo`                          | Algorithme de classement utilisé pour le calcul des scores. Actuellement seul `elo` est supporté. |

---

## Docker

Ces variables contrôlent le comportement du backend Docker, responsable du lancement des conteneurs de serveurs de match.

| Variable         | Valeur par défaut          | Description |
|------------------|----------------------------|-------------|
| `DOCKER_IMAGE`   | `csgo-match-server:latest` | Nom et tag de l'image Docker utilisée pour lancer chaque serveur de match. L'image doit être construite ou disponible localement avant le premier démarrage du matchmaker. |
| `DOCKER_NETWORK` | `host`                     | Réseau Docker auquel les conteneurs de match sont rattachés. `host` donne un accès direct aux interfaces réseau de l'hôte, ce qui est recommandé pour les serveurs de jeu (performances réseau optimales). Utilisez un réseau nommé si vous souhaitez isoler les conteneurs. |

**Remarques :**
- Le mode réseau `host` n'est disponible que sous Linux. Sur macOS ou Windows, utilisez un réseau Docker nommé.
- Assurez-vous que le démon Docker est accessible par le processus matchmaker (appartenance au groupe `docker` ou accès root).

---

## Panneau web

Ces variables configurent le serveur HTTP du panneau d'administration et de statistiques.

| Variable     | Valeur par défaut | Description |
|--------------|-------------------|-------------|
| `WEB_HOST`   | `0.0.0.0`         | Interface d'écoute du serveur web Flask. `0.0.0.0` expose le panneau sur toutes les interfaces. Spécifiez `127.0.0.1` pour le restreindre à un accès local (recommandé si un reverse proxy est utilisé). |
| `WEB_PORT`   | `5000`            | Port TCP sur lequel le panneau web est accessible. Par défaut : `http://IP:5000`. |
| `SECRET_KEY` | `CHANGE_ME`       | Clé secrète Flask utilisée pour signer les cookies de session. **Doit être une chaîne aléatoire longue et unique en production.** Générez-en une avec : `python3 -c "import secrets; print(secrets.token_hex(32))"` |

**Remarques :**
- En production, placez le panneau web derrière un reverse proxy (nginx, Caddy) avec HTTPS.
- Ne laissez jamais `SECRET_KEY` à sa valeur par défaut `CHANGE_ME` en production.

---

## Discord

| Variable              | Valeur par défaut | Description |
|-----------------------|-------------------|-------------|
| `DISCORD_WEBHOOK_URL` | *(vide)*          | URL du webhook Discord vers lequel les notifications de match (début de partie, résultat, erreurs) sont envoyées. Laissez vide pour désactiver, ou positionnez `NOTIFICATION_BACKEND=none`. |

**Remarques :**
- Pour créer un webhook : paramètres du salon Discord → Intégrations → Webhooks → Nouveau webhook.
- Le webhook reçoit un message à chaque début et fin de partie, ainsi qu'en cas d'erreur critique du matchmaker.

---

## Levels Ranks (LR)

| Variable        | Valeur par défaut | Description |
|-----------------|-------------------|-------------|
| `LR_TABLE_NAME` | `lvl_base`        | Nom de la table MySQL utilisée par le plugin SourceMod Levels Ranks. Modifiez cette valeur uniquement si votre installation LR utilise un nom de table personnalisé. |

---

## Système de ranking ELO — Paliers

Le classement est découpé en **18 paliers** inspirés du système de rangs de CS:GO. Le palier affiché est déterminé automatiquement à partir du score ELO courant du joueur.

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

**Fonctionnement du calcul ELO :**

Après chaque partie, le gain ou la perte d'ELO est calculé selon la formule ELO classique :

```
ELO_nouveau = ELO_ancien + K × (Score_réel - Score_attendu)
```

- `Score_réel` vaut `1` en cas de victoire, `0` en cas de défaite.
- `Score_attendu` est calculé à partir des ELO respectifs des deux équipes (moyennés).
- `K` vaut `ELO_K_FACTOR_NEW` (64) pendant les parties de placement, et `ELO_K_FACTOR` (32) ensuite.

**Exemple :**

Un joueur à 1050 ELO (Master Guardian I) affronte une équipe moyenne à 1200 ELO.
- Score attendu ≈ 0.32 (l'équipe adverse est favorite)
- En cas de **victoire** : +22 ELO environ → 1072
- En cas de **défaite** : -10 ELO environ → 1040

Les paliers **Distinguished Master Guardian** (1300–1499) et au-delà ont des plages plus larges, ce qui rend la progression plus difficile et récompense la régularité.
