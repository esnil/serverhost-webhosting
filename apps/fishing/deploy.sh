#!/usr/bin/env bash
#
# deploy.sh — bygg och driftsätt JLSK Fishing (Öppen-driftfallet) DIREKT från
# den här datorn till VPS:en, utan GitHub/GHCR.
#
# Flöde: bygg imagen lokalt → docker save | ssh docker load (inget register) →
# scp compose.yaml → migrera (idempotent) → docker compose up -d → restart traefik.
#
# Användning (från serverhost-webhosting/):
#   JF_ADMIN_EMAIL=du@exempel.se JF_ADMIN_PASSWORD=hemligt ./apps/fishing/deploy.sh
#   ./apps/fishing/deploy.sh                 # normal deploy (admin finns redan)
#   ./apps/fishing/deploy.sh <tagg>          # rollback: driftsätt en tidigare laddad tagg
#
# Konfiguration (miljövariabler, med defaultvärden):
#   VPS_HOST=217.154.83.127   VPS_USER=deploy
#   APP_DIR=<repo>/../jlsk/jlsk-fishing
#   JF_ADMIN_EMAIL / JF_ADMIN_PASSWORD  — sätts vid första deploy (skapar admin).
# Kan även läggas i apps/fishing/.env (kopiera från .env.example).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Ladda lokala hemligheter/overrides om de finns (checkas aldrig in).
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi

VPS_HOST="${VPS_HOST:-217.154.83.127}"
VPS_USER="${VPS_USER:-deploy}"
APP_DIR="${APP_DIR:-$REPO_ROOT/../jlsk/jlsk-fishing}"
REMOTE_APP_DIR="/opt/hosting/apps/fishing"
IMAGE="jlsk-fishing"

if [ ! -f "$APP_DIR/deploy/Dockerfile" ]; then
    echo "FEL: hittar inte $APP_DIR/deploy/Dockerfile — sätt APP_DIR till jlsk-fishing-katalogen." >&2
    exit 1
fi

# Tagg: argument, annars app-repots git-beskrivning, annars 'latest'.
TAG="${1:-$(git -C "$APP_DIR" describe --always --dirty --tags 2>/dev/null || echo latest)}"
SSH="ssh ${VPS_USER}@${VPS_HOST}"

echo "==> Bygger $IMAGE:$TAG (kontext: $APP_DIR)"
docker build \
    -f "$APP_DIR/deploy/Dockerfile" \
    -t "$IMAGE:$TAG" -t "$IMAGE:latest" \
    "$APP_DIR"

echo "==> Överför imagen till $VPS_USER@$VPS_HOST (docker save | ssh docker load)"
docker save "$IMAGE:$TAG" "$IMAGE:latest" | gzip | $SSH 'gunzip | docker load'

echo "==> Säkrar katalogstruktur + compose.yaml på servern"
$SSH "mkdir -p $REMOTE_APP_DIR/data/db $REMOTE_APP_DIR/data/uploads"
scp "$SCRIPT_DIR/compose.yaml" "${VPS_USER}@${VPS_HOST}:$REMOTE_APP_DIR/compose.yaml"

echo "==> Migrerar databasen (idempotent) och startar om apparna"
# Admin-uppgifterna behövs bara första gången; skickas som env till engångs-migreringen.
$SSH "cd $REMOTE_APP_DIR && \
    IMAGE_TAG='$TAG' \
    docker compose run --rm \
        -e JF_ADMIN_EMAIL='${JF_ADMIN_EMAIL:-}' \
        -e JF_ADMIN_PASSWORD='${JF_ADMIN_PASSWORD:-}' \
        fishing php /app/bin/migrate-standalone.php && \
    IMAGE_TAG='$TAG' docker compose up -d && \
    docker image prune -f --filter 'until=168h' && \
    docker restart traefik"

echo "==> Klart. Deltagare: https://fiske.vps.encab.se  ·  Admin: https://fiske-admin.vps.encab.se"
