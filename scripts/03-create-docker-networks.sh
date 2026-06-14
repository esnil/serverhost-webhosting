#!/usr/bin/env bash
# Skapar Docker-nätverk som Traefik och appar delar.
# Kan köras av deploy-användaren (om denne är i docker-gruppen).

set -euo pipefail

info() { echo "[INFO]  $*"; }

NETWORKS=("proxy")

for NET in "${NETWORKS[@]}"; do
    if docker network inspect "$NET" &>/dev/null; then
        info "Nätverk '$NET' finns redan."
    else
        docker network create "$NET"
        info "Nätverk '$NET' skapat."
    fi
done

echo ""
docker network ls --filter name=proxy
