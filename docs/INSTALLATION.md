# Guide d'Installation

Ce guide couvre l'installation complète du système de matchmaking CS:GO Legacy de zéro, jusqu'à un serveur fonctionnel prêt à accueillir des joueurs.

---

## Sommaire

1. [Prérequis](#1-prérequis)
2. [Obtenir les tokens GSLT](#2-obtenir-les-tokens-gslt)
3. [Installation automatique (recommandée)](#3-installation-automatique-recommandée)
4. [Vérification post-installation](#4-vérification-post-installation)
5. [Premiers tests](#5-premiers-tests)
6. [Dépannage](#6-dépannage)

---

## 1. Prérequis

### Matériel minimum

| Ressource | Minimum | Recommandé |
|-----------|---------|------------|
| RAM | 4 Go | 8 Go+ |
| CPU | 2 cœurs | 4 cœurs |
| Disque | 50 Go | 100 Go |
| OS | Linux 64-bit | Ubuntu 22.04 LTS |
| Réseau | 100 Mbit/s | 1 Gbit/s dédié |

> **Conseil** : CS:GO seul occupe ~25 Go. Chaque serveur match actif consomme ~500 Mo RAM et ~200 Mo disque supplémentaires.

### Distributions supportées

- **Ubuntu** 20.04, 22.04, 24.04 (LTS, recommandées)
- **Debian** 11 (Bullseye), 12 (Bookworm)
- **CentOS** 7, Stream 8/9
- **Rocky Linux / AlmaLinux** 8, 9
- **Fedora** 36+
- **Arch Linux** (rolling)

### Compte Steam requis

- Un compte Steam **avec jeu CS:GO** (nécessaire pour obtenir des GSLT)
- Accès internet pendant l'installation (téléchargement ~25 Go)
- Accès `root` ou `sudo` sur le serveur

---

## 2. Obtenir les tokens GSLT

Les **Game Server Login Tokens (GSLT)** sont obligatoires pour faire tourner des serveurs CS:GO visibles sur internet. Chaque instance de serveur (lobby + chaque serveur match) nécessite un token unique.

> **Important** : L'AppID pour CS:GO Legacy est **730** (et non 730 pour CS2). Utiliser le mauvais AppID invalide les tokens.

### Procédure

1. Aller sur [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers)
2. Se connecter avec votre compte Steam
3. Dans le champ **App ID**, entrer : `730`
4. Dans **Memo**, entrer un nom descriptif (ex: `csgo-lobby`, `csgo-match-01`)
5. Cliquer **Create**
6. Copier le token généré (format : `XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX`, 32 caractères)
7. **Répéter** pour chaque serveur :
   - 1 token pour le serveur lobby
   - 1 token par slot match (le système supporte 10 matchs simultanés par défaut, donc 10 tokens)

**Total recommandé : 11 tokens** (1 lobby + 10 matchs)

> **Note** : Un compte Steam peut créer jusqu'à 1000 tokens. Les tokens expirés ou révoqués peuvent être regénérés depuis la même page.

### Vérifier un token

Un token valide ressemble à : `A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4`

L'installateur validera automatiquement le format de chaque token saisi.

---

## 3. Installation automatique (recommandée)

### Étape 1 : Cloner le dépôt

```bash
git clone https://github.com/nathan-pichon/CSGO-Matchmaking.git
cd CSGO-Matchmaking
```

### Étape 2 : Lancer le wizard

```bash
chmod +x install.sh
sudo ./install.sh
```

> **Durée estimée** : 30 à 60 minutes (dépend de la vitesse de connexion pour le téléchargement de CS:GO ~25 Go)

### Ce que fait le wizard

Le wizard est interactif et vous guide à travers chaque étape :

#### Détection de l'environnement
- Identifie automatiquement votre distribution Linux et son gestionnaire de paquets
- Vérifie que les ressources système sont suffisantes (RAM, CPU, disque)
- Détecte l'adresse IP publique de votre serveur (avec possibilité de confirmer ou corriger)

#### Installation des dépendances
Installe automatiquement selon votre distro :
- **Docker CE** et **docker-compose** (ou Docker Compose V2)
- **MySQL 8.0** ou **MariaDB**
- **Python 3.10+** et `pip`
- **SteamCMD** (client Steam en ligne de commande)
- Outils système requis (curl, wget, git, etc.)

#### Configuration interactive

Le wizard vous pose les questions suivantes :

| Question | Valeur par défaut | Description |
|----------|-------------------|-------------|
| Adresse IP publique | Auto-détectée | IP que les joueurs utilisent pour se connecter |
| Port du lobby | `27015` | Port UDP du serveur lobby |
| Mot de passe MySQL | Généré aléatoirement | Mot de passe pour l'utilisateur `csgo_mm` |
| Mot de passe RCON | Généré aléatoirement | Pour la communication entre le daemon et les serveurs |
| Token GSLT lobby | — | Token pour le serveur lobby (obligatoire) |
| Tokens GSLT matchs | — | Un token par slot match (10 slots, saisie guidée) |
| URL Discord webhook | Vide (désactivé) | Optionnel pour les notifications Discord |
| Pool de maps | `de_mirage,de_dust2,de_inferno,de_ancient,de_nuke,de_overpass,de_vertigo` | Maps actives en rotation |

#### Téléchargements et installation
- Télécharge CS:GO Legacy via SteamCMD (~25 Go)
- Télécharge et installe SourceMod + MetaMod:Source
- Installe les plugins additionnels : **Levels Ranks** et **ServerRedirect** (GAMMACASE)
- Copie les plugins compilés (`.smx`) depuis le dépôt vers les dossiers SourceMod
- Configure les fichiers `databases.cfg` pour la connexion MySQL

#### Base de données
- Crée la base de données `csgo_matchmaking`
- Crée l'utilisateur MySQL `csgo_mm` avec les permissions appropriées
- Applique le schéma complet (`database/schema.sql`) — idempotent, peut être relancé
- Seed les données initiales : Saison 1, pool de maps, pool de ports (27020–27029)

#### Génération des fichiers de config
- Génère `config.env` avec toutes vos valeurs
- Génère les fichiers de config SourceMod (`databases.cfg`, `csgo_matchmaking.cfg`)

#### Construction Docker
- Construit l'image Docker des serveurs match : `csgo-match-server:latest`
- Vérifie que l'image est accessible

#### Services systemd
Crée et active 3 services qui démarrent automatiquement au boot :

```
csgo-lobby.service      # Serveur lobby CS:GO (srcds)
csgo-matchmaker.service # Daemon Python de matchmaking
csgo-webpanel.service   # Interface web Flask
```

#### Validation finale
Teste automatiquement :
- Connexion à MySQL
- Accès à l'API Docker
- Disponibilité des ports (27015, 5000)
- Démarrage des services

### Rejouer le wizard (mise à jour)

```bash
sudo ./install.sh --update
```

Le mode `--update` relance uniquement les étapes nécessaires sans écraser votre `config.env` existant.

---

## 4. Vérification post-installation

### Vérifier les services

```bash
# Statut de tous les services
sudo systemctl status csgo-lobby csgo-matchmaker csgo-webpanel

# Voir les logs en direct
sudo journalctl -u csgo-matchmaker -f
sudo journalctl -u csgo-lobby -f
sudo journalctl -u csgo-webpanel -f
```

### Vérifier la base de données

```bash
mysql -u csgo_mm -p csgo_matchmaking

# Dans MySQL :
SHOW TABLES;
SELECT * FROM mm_seasons;
SELECT * FROM mm_server_ports;
SELECT COUNT(*) FROM mm_gslt_tokens;
```

### Vérifier Docker

```bash
# L'image doit être présente
docker images | grep csgo-match-server

# Aucun conteneur match ne devrait tourner pour l'instant
docker ps --filter "name=csgo-match-"
```

### Vérifier les ports ouverts

```bash
# Vérifier que les ports écoutent
ss -ulnp | grep 27015   # Lobby UDP
ss -tlnp | grep 5000    # Web panel TCP

# Vérifier le firewall (UFW)
sudo ufw status
```

### Script de santé complet

```bash
./scripts/health_check.sh
```

Ce script vérifie les 10 points critiques et affiche un rapport coloré. Tous les indicateurs doivent être verts avant d'inviter des joueurs.

---

## 5. Premiers tests

### 1. Se connecter au serveur lobby

Depuis CS:GO Legacy (console, touche `~`) :
```
connect VOTRE_IP:27015
```

Vous devriez voir le serveur charger et le message de bienvenue du plugin s'afficher dans le chat.

### 2. Tester les commandes de base

Dans le chat du serveur lobby :
```
!rank          # Doit afficher votre rang (ELO 1000 initial)
!status        # Doit afficher "0 joueurs en file d'attente"
!queue         # Vous ajoute à la file
!leave         # Vous retire de la file
!top           # Affiche le leaderboard (vide au départ)
```

### 3. Forcer un match (test avec un seul joueur)

En tant qu'admin (voir [commandes admin](USAGE.md#commandes-admin)) :
```
!mm_forcestart
```

Ceci démarre un match avec les joueurs actuellement en file, même si moins de 10. Utile pour tester le flux complet.

### 4. Vérifier le web panel

Ouvrir dans un navigateur : `http://VOTRE_IP:5000`

Le leaderboard doit s'afficher (vide au début). Après quelques matchs, les statistiques apparaîtront.

---

## 6. Dépannage

### Les plugins ne se chargent pas

**Symptôme** : Les commandes `!queue` etc. ne fonctionnent pas, pas de message de bienvenue.

**Cause** : Les fichiers `.smx` (plugins compilés) ne sont pas dans le bon dossier.

**Solution** :
```bash
# Vérifier la présence des plugins
ls -la /home/steam/csgo-dedicated/csgo/addons/sourcemod/plugins/
# Doit contenir : csgo_mm_queue.smx, csgo_mm_notify.smx, etc.

# Si vide, forcer la compilation via CI (push sur GitHub)
# ou compiler manuellement (voir DEPLOY.md)
```

### Le matchmaker ne démarre pas

**Symptôme** : `systemctl status csgo-matchmaker` indique `failed`.

**Causes courantes** :

```bash
# 1. Vérifier que MySQL est prêt
sudo systemctl status mysql

# 2. Vérifier config.env
cat config.env | grep DB_

# 3. Tester la connexion manuellement
python3 -c "import mysql.connector; mysql.connector.connect(host='localhost', user='csgo_mm', password='VOTRE_MOT_DE_PASSE', database='csgo_matchmaking')"

# 4. Relancer après correction
sudo systemctl restart csgo-matchmaker
```

### Les joueurs ne sont pas redirigés vers le serveur match

**Symptôme** : Le ready check passe, mais les joueurs restent sur le lobby.

**Causes** :
1. Le plugin `csgo_mm_queue.smx` n'est pas chargé → vérifier les plugins
2. Docker n'a pas pu créer le conteneur match → `docker logs csgo-match-XXX`
3. Le token GSLT du match est invalide → vérifier `mm_gslt_tokens` en DB

```bash
# Voir les logs du matchmaker
sudo journalctl -u csgo-matchmaker -n 100

# Voir les conteneurs match
docker ps -a --filter "name=csgo-match-"
docker logs csgo-match-<ID>
```

### Le web panel est inaccessible

```bash
# Vérifier le service
sudo systemctl status csgo-webpanel

# Vérifier le port
ss -tlnp | grep 5000

# Vérifier le firewall
sudo ufw allow 5000/tcp
sudo ufw reload
```

### Token GSLT invalide

**Symptôme** : Le serveur lobby démarre mais est invisible dans le navigateur de serveurs, ou les logs indiquent "Invalid GSLT".

**Solution** :
1. Aller sur [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers)
2. Révoquer et regénérer le token concerné avec AppID **730**
3. Mettre à jour `config.env` :
   ```bash
   nano config.env  # Modifier GSLT_LOBBY ou les tokens match
   sudo systemctl restart csgo-lobby
   ```

### Réinitialiser complètement

Si besoin de tout recommencer depuis zéro :

```bash
# Arrêter les services
sudo systemctl stop csgo-lobby csgo-matchmaker csgo-webpanel

# Supprimer la DB (DESTRUCTIF)
mysql -u root -e "DROP DATABASE csgo_matchmaking;"

# Relancer le wizard
sudo ./install.sh
```

---

## Étapes suivantes

- [Configuration avancée](CONFIGURATION.md) — tous les paramètres `config.env`
- [Utilisation en jeu](USAGE.md) — commandes joueurs et admin
- [Maintenance](MAINTENANCE.md) — backups, mises à jour, monitoring
