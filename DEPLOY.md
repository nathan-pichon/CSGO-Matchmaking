# Guide de Déploiement

Deux modes de déploiement sont disponibles selon votre infrastructure.

---

## Mode 1 : Serveur Linux bare-metal (recommandé en production)

**Pour un VPS ou serveur dédié Ubuntu/Debian/CentOS/Fedora/Arch.**

### Prérequis

- Linux 64-bit (Ubuntu 22.04 LTS recommandé)
- 4 Go RAM minimum (8 Go recommandé)
- 2 vCPU minimum
- 60 Go disque libre (CS:GO ≈ 25 Go)
- Accès root ou sudo
- Compte Steam avec tokens GSLT ([créer ici](https://steamcommunity.com/dev/managegameservers), AppID 730)

### Installation

```bash
# 1. Cloner le repo
git clone https://github.com/nathan-pichon/CSGO-Matchmaking.git
cd CSGO-Matchmaking

# 2. Lancer le wizard (interactif, ~30-60 min selon connexion)
chmod +x install.sh
sudo ./install.sh
```

Le wizard va :
- Détecter votre OS et installer les dépendances
- Vous guider pour obtenir vos tokens GSLT
- Télécharger CS:GO (~25 Go via SteamCMD)
- Installer SourceMod, MetaMod, Levels Ranks, ServerRedirect
- Copier et installer les plugins compilés (`.smx`)
- Configurer MySQL, créer la base de données
- Générer `config.env` avec vos valeurs
- Builder l'image Docker des serveurs match
- Créer et activer les services systemd

### Démarrage des services

```bash
# Démarrer tout
sudo systemctl start csgo-lobby csgo-matchmaker csgo-webpanel

# Vérifier le statut
sudo systemctl status csgo-matchmaker

# Suivre les logs en direct
sudo journalctl -u csgo-matchmaker -f
sudo journalctl -u csgo-lobby -f
```

### Auto-démarrage au boot

**Oui, automatique.** `install.sh` exécute `systemctl enable` sur les 3 services :

```
csgo-lobby.service      → Serveur lobby CS:GO (srcds)
csgo-matchmaker.service → Daemon Python de matchmaking
csgo-webpanel.service   → Interface web Flask
```

Ils redémarrent automatiquement en cas de crash (`Restart=always`).

### Ports à ouvrir (firewall)

```bash
# UFW (Ubuntu)
sudo ufw allow 27015/udp   # Lobby CS:GO
sudo ufw allow 27020:27029/udp  # Serveurs match
sudo ufw allow 5000/tcp    # Web panel
# MySQL (3306) : NE PAS exposer publiquement

# iptables / firewalld selon votre distro
```

### Mise à jour

```bash
git pull
sudo ./install.sh --update   # Relance uniquement les étapes nécessaires
```

---

## Mode 2 : Docker Compose (développement / infrastructure cloud)

**Idéal pour tester localement ou sur un serveur avec Docker.**

> ⚠️ **Limitation importante** : Le serveur lobby CS:GO ne peut pas tourner dans Docker en mode bridge (contraintes réseau UDP des Source Engine). Il doit tourner sur l'hôte ou en mode `--network=host`.

### Architecture Docker

```
docker-compose.yml gère :
  ✅ MySQL 8.0              (csgo-mm-mysql)
  ✅ Matchmaker Python      (csgo-mm-matchmaker)
  ✅ Web panel Flask        (csgo-mm-webpanel)

Hors Docker-Compose :
  ⚠️  Lobby CS:GO           → Systemd sur l'hôte (ou conteneur --network=host)
  ✅  Serveurs match        → Créés dynamiquement par le matchmaker
```

### Démarrage rapide Docker

```bash
# 1. Cloner
git clone https://github.com/nathan-pichon/CSGO-Matchmaking.git
cd CSGO-Matchmaking

# 2. Configurer
cp config.example.env config.env
# Éditer config.env : DB_PASS, RCON_PASSWORD, SERVER_IP, GSLT tokens, etc.

# 3. Appliquer le schema DB (au premier démarrage, automatique via healthcheck)
# Le fichier database/schema.sql est monté dans MySQL init directory

# 4. Démarrer les services backend
docker compose up -d

# 5. Vérifier
docker compose logs -f matchmaker
docker compose ps
```

### Pour le serveur lobby (hors Docker Compose)

Option A — **Systemd sur l'hôte** (après avoir lancé `sudo ./install.sh`) :
```bash
sudo systemctl start csgo-lobby
```

Option B — **Conteneur Docker standalone** avec réseau host :
```bash
docker run -d \
  --name csgo-lobby \
  --network=host \
  -e SRCDS_TOKEN=VOTRE_GSLT_LOBBY \
  -e SRCDS_PORT=27015 \
  -e SRCDS_MAXPLAYERS=32 \
  -e SRCDS_STARTMAP=de_dust2 \
  -e SRCDS_GAMETYPE=0 \
  -e SRCDS_GAMEMODE=0 \
  -v ./lobby-server/cfg/server.cfg:/home/steam/csgo-dedicated/csgo/cfg/server.cfg:ro \
  -v ./lobby-server/sourcemod:/home/steam/csgo-dedicated/csgo/addons/sourcemod:ro \
  cm2network/csgo:sourcemod
```

### Commandes utiles Docker

```bash
# Logs en direct
docker compose logs -f

# Redémarrer un service
docker compose restart matchmaker

# Arrêt complet
docker compose down

# Arrêt + suppression des données MySQL (ATTENTION: destructif)
docker compose down -v

# Rebuild après changements de code
docker compose build matchmaker webpanel
docker compose up -d matchmaker webpanel
```

---

## Connexion au serveur lobby

Une fois les services démarrés, connectez-vous depuis CS:GO :

```
# Dans la console CS:GO (touche ~)
connect VOTRE_IP:27015
```

Puis dans le chat :
```
!queue          → Rejoindre la file d'attente
!rank           → Voir son rang et ELO
!top            → Top 10 joueurs
!stats          → Statistiques détaillées
```

---

## Monitoring

```bash
# Health check complet
./scripts/health_check.sh

# Format JSON (pour Prometheus/Grafana/etc.)
./scripts/health_check.sh --json

# Backup base de données
./scripts/backup.sh

# Logs matchmaker (systemd)
journalctl -u csgo-matchmaker --since "1 hour ago"

# Conteneurs match actifs
docker ps --filter "name=csgo-match-"
```

---

## Dépannage

| Symptôme | Diagnostic | Solution |
|----------|-----------|----------|
| Plugins ne chargent pas | Pas de `.smx` dans `plugins/` | Attendre le CI GitHub Actions ou compiler manuellement |
| Matchmaker plante au démarrage | DB pas prête | `systemctl status mysql` puis `systemctl restart csgo-matchmaker` |
| Joueurs non redirigés | Plugin `csgo_mm_queue.smx` absent | Vérifier `addons/sourcemod/plugins/` |
| Docker container crash | Vérifier logs | `docker logs csgo-match-ID` |
| Web panel inaccessible | Port 5000 bloqué | Vérifier firewall + `systemctl status csgo-webpanel` |
| GSLT invalide | Token expiré ou mauvais AppID | Regénérer sur [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers) avec AppID **730** |

---

## Compilation manuelle des plugins (si CI non disponible)

```bash
# Télécharger spcomp
SM_URL=$(curl -s "https://www.sourcemod.net/downloads.php?branch=stable" \
  | grep -oP 'https://sm\.alliedmods\.net/smdrop/[^"]+linux\.tar\.gz' | head -1)
curl -L "$SM_URL" -o sm.tar.gz && tar xzf sm.tar.gz

SPCOMP="./addons/sourcemod/scripting/spcomp"
chmod +x "$SPCOMP"

# Compiler plugins lobby
for SP in lobby-server/sourcemod/scripting/*.sp; do
  NAME=$(basename "${SP%.sp}")
  "$SPCOMP" "$SP" \
    -i lobby-server/sourcemod/scripting/include \
    -i ./addons/sourcemod/scripting/include \
    -o lobby-server/sourcemod/plugins/${NAME}.smx
done

# Compiler plugin match
for SP in match-server/sourcemod/scripting/*.sp; do
  NAME=$(basename "${SP%.sp}")
  "$SPCOMP" "$SP" \
    -i match-server/sourcemod/scripting/include \
    -i ./addons/sourcemod/scripting/include \
    -o match-server/sourcemod/plugins/${NAME}.smx
done
```
