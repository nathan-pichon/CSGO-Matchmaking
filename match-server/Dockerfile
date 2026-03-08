FROM cm2network/csgo:sourcemod

LABEL maintainer="CSGO-Matchmaking Community"
LABEL description="CS:GO Competitive Match Server with Matchmaking Integration"
LABEL version="1.0.0"

# Copy our SourceMod plugins: compiled .smx binaries (required to load),
# source .sp files (for reference / in-server recompilation), and configs.
# The .smx files in sourcemod/plugins/ are compiled by install.sh before
# this Docker image is built.
COPY --chown=steam:steam sourcemod/plugins/ \
    /home/steam/csgo-dedicated/csgo/addons/sourcemod/plugins/
COPY --chown=steam:steam sourcemod/scripting/ \
    /home/steam/csgo-dedicated/csgo/addons/sourcemod/scripting/
COPY --chown=steam:steam sourcemod/configs/ \
    /home/steam/csgo-dedicated/csgo/addons/sourcemod/configs/

# Copy competitive server configs
COPY --chown=steam:steam cfg/ \
    /home/steam/csgo-dedicated/csgo/cfg/

# Custom entrypoint that generates databases.cfg and match config from env vars
COPY --chown=steam:steam entrypoint.sh /home/steam/entrypoint.sh
RUN chmod +x /home/steam/entrypoint.sh

ENTRYPOINT ["/home/steam/entrypoint.sh"]
