# Guide de Maintenance — CS:GO Matchmaking

Ce document couvre les opérations courantes de maintenance, surveillance et administration du système CS:GO Matchmaking.

---

## Table des matières

1. [Gestion des services](#1-gestion-des-services)
2. [Surveillance des conteneurs match](#2-surveillance-des-conteneurs-match)
3. [Health check](#3-health-check)
4. [Backup et restauration](#4-backup-et-restauration)
5. [Mise à jour](#5-mise-à-jour)
6. [Gestion des tokens GSLT](#6-gestion-des-tokens-gslt)
7. [Gestion du pool de ports](#7-gestion-du-pool-de-ports)
8. [Administration base de données](#8-administration-base-de-données)
9. [Gestion des saisons](#9-gestion-des-saisons)
10. [Logs et debugging](#10-logs-et-debugging)

---

## 1. Gestion des services

Les services systemd sont configurés pour démarrer automatiquement au boot (activés par `install.sh`, avec `Restart=always`). Toute interruption inattendue entraîne un redémarrage automatique du service concerné.

### Démarrer tous les services

```bash
sudo systemctl start csgo-lobby csgo-matchmaker csgo-webpanel
```

### Arrêter tous les services

```bash
sudo systemctl stop csgo-lobby csgo-matchmaker csgo-webpanel
```

### Redémarrer un service spécifique

```bash
sudo systemctl restart csgo-matchmaker
```

> Remplacer `csgo-matchmaker` par `csgo-lobby` ou `csgo-webpanel` selon le service concerné.

### Vérifier le statut d'un service

```bash
sudo systemctl status csgo-matchmaker
```

### Consulter les logs en temps réel

```bash
sudo journalctl -u csgo-matchmaker -f
```

### Consulter les logs récents

```bash
sudo journalctl -u csgo-matchmaker --since "1 hour ago"
```

---

## 2. Surveillance des conteneurs match

Chaque partie active est exécutée dans un conteneur Docker dédié, nommé selon le schéma `csgo-match-<ID>`.

### Lister les conteneurs actifs

```bash
docker ps --filter "name=csgo-match-"
```

### Afficher les logs d'un conteneur

```bash
docker logs csgo-match-<ID>
```

### Lister tous les conteneurs match (y compris arrêtés)

```bash
docker ps -a --filter "name=csgo-match-"
```

### Arrêter un conteneur bloqué

```bash
docker stop csgo-match-<ID>
```

> Remplacer `<ID>` par l'identifiant de la partie correspondante (visible dans la colonne `NAMES` de `docker ps`).

---

## 3. Health check

Le script `health_check.sh` effectue une vérification complète en 10 points de l'état du système.

### Vérification complète

```bash
./scripts/health_check.sh
```

Points vérifiés :
- Connexion MySQL
- Daemon Docker
- Service matchmaker
- Service lobby
- Service webpanel
- Espace disque disponible
- Pool de tokens GSLT
- Pool de ports
- Partis bloqués (stale matches)

### Sortie JSON (pour Prometheus / Grafana)

```bash
./scripts/health_check.sh --json
```

---

## 4. Backup et restauration

### Backup manuel

```bash
./scripts/backup.sh
```

Génère un dump MySQL horodaté dans le répertoire `./backups/`. Les 30 dernières sauvegardes sont conservées, les plus anciennes sont supprimées automatiquement.

### Restauration interactive

```bash
./scripts/restore.sh
```

Le script est interactif : il arrête le matchmaker, restaure la base de données sélectionnée, puis redémarre le service.

### Backup automatique via cron

Ajouter la ligne suivante dans la crontab (`crontab -e`) pour déclencher un backup chaque nuit à 3h00 :

```
0 3 * * * /path/to/CSGO-Matchmaking/scripts/backup.sh
```

> Remplacer `/path/to/CSGO-Matchmaking` par le chemin absolu du projet sur le serveur.

---

## 5. Mise à jour

### Mettre à jour le code et réinstaller

```bash
git pull && sudo ./install.sh --update
```

### Mettre à jour uniquement les fichiers du jeu CS:GO

```bash
./scripts/update_server.sh
```

### Reconstruire l'image Docker après modification du match-server

```bash
docker build -t csgo-match-server:latest -f match-server/Dockerfile match-server/
```

### Redéployer les services Docker

```bash
docker compose up -d --build matchmaker webpanel
```

---

## 6. Gestion des tokens GSLT

Les tokens GSLT (Game Server Login Token) sont nécessaires pour héberger des serveurs CS:GO officiels. Ils sont gérés via la table `mm_gslt_tokens`.

### Vérifier l'état du pool

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "SELECT * FROM mm_gslt_tokens;"
```

### Ajouter un nouveau token

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "INSERT INTO mm_gslt_tokens (token) VALUES ('TOKEN');"
```

> Remplacer `TOKEN` par le token GSLT obtenu sur [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers) (AppID 730).

### Token expiré

1. Régénérer le token sur [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers) (AppID 730).
2. Mettre à jour le token en base de données.

### Libérer un token bloqué

Si un token est marqué `in_use` alors qu'aucun conteneur correspondant n'existe :

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "UPDATE mm_gslt_tokens SET in_use=0, assigned_match_id=NULL WHERE token='TOKEN';"
```

---

## 7. Gestion du pool de ports

Chaque serveur de match utilise un port UDP dédié. Le pool est géré dans la table `mm_server_ports`.

### Vérifier l'état du pool

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "SELECT * FROM mm_server_ports;"
```

### Libérer un port bloqué

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "UPDATE mm_server_ports SET in_use=0 WHERE port=27020;"
```

### Ajouter des ports supplémentaires

```bash
mysql -u csgo_mm -p csgo_matchmaking -e "INSERT INTO mm_server_ports (port, tv_port) VALUES (27030, 27130);"
```

---

## 8. Administration base de données

### Connexion à la base de données

```bash
mysql -u csgo_mm -p csgo_matchmaking
```

### Requêtes utiles

**Statut de la file d'attente :**

```sql
SELECT status, COUNT(*) FROM mm_queue GROUP BY status;
```

**Parties actives :**

```sql
SELECT id, map_name, status, server_ip, server_port
FROM mm_matches
WHERE status IN ('creating', 'warmup', 'live');
```

**Classement des meilleurs joueurs :**

```sql
SELECT name, elo, rank_tier, matches_played
FROM mm_players
ORDER BY elo DESC
LIMIT 10;
```

**Bans actifs récents :**

```sql
SELECT steam_id, reason, expires_at
FROM mm_bans
WHERE is_active = 1;
```

**Nettoyage des anciennes entrées de file d'attente :**

```sql
DELETE FROM mm_queue
WHERE status IN ('matched', 'expired', 'cancelled')
  AND queued_at < DATE_SUB(NOW(), INTERVAL 7 DAY);
```

---

## 9. Gestion des saisons

### Démarrer une nouvelle saison (reset ELO partiel)

Le script suivant clôture la saison en cours, crée une nouvelle saison et applique un reset ELO progressif (moyenne entre l'ELO actuel et 1000) avant de recalculer les rangs.

```sql
-- Clôturer la saison actuelle
UPDATE mm_seasons SET is_active = 0 WHERE is_active = 1;

-- Créer la nouvelle saison
INSERT INTO mm_seasons (name, started_at, is_active) VALUES ('Saison 2', NOW(), 1);

-- Reset ELO partiel (moyenne entre ELO actuel et 1000)
UPDATE mm_players SET elo = FLOOR((elo + 1000) / 2);

-- Recalculer les rangs en fonction du nouvel ELO
UPDATE mm_players SET rank_tier = CASE
    WHEN elo >= 2100 THEN 17
    WHEN elo >= 1900 THEN 16
    WHEN elo >= 1700 THEN 15
    WHEN elo >= 1500 THEN 14
    WHEN elo >= 1300 THEN 13
    WHEN elo >= 1200 THEN 12
    WHEN elo >= 1100 THEN 11
    WHEN elo >= 1000 THEN 10
    WHEN elo >= 900  THEN 9
    WHEN elo >= 800  THEN 8
    WHEN elo >= 700  THEN 7
    WHEN elo >= 600  THEN 6
    WHEN elo >= 500  THEN 5
    WHEN elo >= 400  THEN 4
    WHEN elo >= 300  THEN 3
    WHEN elo >= 200  THEN 2
    WHEN elo >= 100  THEN 1
    ELSE 0
END;
```

> Il est recommandé d'effectuer cette opération pendant une période de faible activité et de réaliser un backup préalable via `./scripts/backup.sh`.

---

## 10. Logs et debugging

### Filtrer les erreurs du matchmaker (dernière journée)

```bash
sudo journalctl -u csgo-matchmaker --since "1 day ago" | grep ERROR
```

### Vérifier l'état du pare-feu

```bash
sudo ufw status
```

ou, avec iptables :

```bash
sudo iptables -L
```

### Vérifier qu'un port est en écoute

```bash
ss -ulnp | grep 27015
```

### Identifier les requêtes MySQL lentes ou bloquées

```bash
mysql -u root -p -e "SHOW PROCESSLIST;"
```

---

*Documentation générée le 2026-03-05. Pour toute modification de l'infrastructure, mettre ce document à jour en conséquence.*
