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
    IMAGE_TAG='$TAG' docker compose up -d --remove-orphans && \
    docker image prune -f --filter 'until=168h' && \
    docker restart traefik"

# Feedback-genomgång (jlsk RM125, beslut: alt 2 — status underhålls manuellt server-side).
# Öppen-driftfallet har shell, så feedbacken surfas vid VARJE deploy i stället för att glömmas:
# ett daterat arkiv skrivs till uploads (durabelt, överlever container-bytet), och listan
# skrivs ut för åtgärd. Åtgärdade poster raderas manuellt: `docker exec fishing php
# /app/bin/feedback.php delete <id> --yes`. `|| true` — feedback får aldrig fälla en deploy.
echo "==> Feedback (RM125): arkiverar + listar öppna poster för genomgång"
$SSH "docker exec fishing php /app/bin/feedback.php export all /data/uploads/feedback-arkiv/\$(date +%F) || true"
$SSH "docker exec fishing php /app/bin/feedback.php list || true"

# --- Feedback-synk ROADMAP ↔ drift (jlsk RM144) --------------------------------------------
# Håller ROADMAP.md (git) och driftens jf_feedback i synk utan att någon behöver komma ihåg det:
# (1) applicerar köade statusövergångar (pending-status.jsonl) i driften, (2) exporterar ett
# manifest av feedback-tillståndet tillbaka till git-arbetskopian. Operatören committar sedan det
# tömda kö + uppdaterade manifestet. Best-effort — synken får ALDRIG fälla en deploy.
# Design: jlsk-fishing/docs/FEEDBACK_ROADMAP_SYNC_PLAN.md (fas 5).
JF_QUEUE="$APP_DIR/feedback/pending-status.jsonl"
JF_MANIFEST="$APP_DIR/feedback/manifest.json"

if [ -s "$JF_QUEUE" ]; then
    echo "==> Feedback-synk (RM144): applicerar köade statusövergångar"
    # Skeppa kön in i containern (lokal fil → stdin → /tmp) och applicera (idempotent, best-effort).
    $SSH "docker exec -i fishing sh -c 'cat > /tmp/jf-pending.jsonl'" < "$JF_QUEUE" || true
    if $SSH "docker exec fishing php /app/bin/feedback.php apply-pending /tmp/jf-pending.jsonl"; then
        : > "$JF_QUEUE"
        echo "    kön applicerad + tömd lokalt — COMMITTA den tömda $JF_QUEUE"
    else
        echo "    VARNING: apply-pending misslyckades — kön behålls (idempotent, tas om vid nästa deploy)"
    fi
fi

echo "==> Feedback-synk (RM144): exporterar manifestet till git-arbetskopian"
if $SSH "docker exec -e JF_MANIFEST_SOURCE=open:fiske.ostersundarn.se fishing php /app/bin/feedback.php manifest /tmp/jf-manifest.json"; then
    mkdir -p "$(dirname "$JF_MANIFEST")"
    if scp "${VPS_USER}@${VPS_HOST}:/tmp/jf-manifest.json" "$JF_MANIFEST"; then
        echo "    manifest → $JF_MANIFEST — COMMITTA det (aktiverar feedback_sync-grindarna i CI)"
    fi
fi

echo "==> Klart. Deltagare: https://fiske.ostersundarn.se  ·  Admin: https://fiske.ostersundarn.se/admin/"
