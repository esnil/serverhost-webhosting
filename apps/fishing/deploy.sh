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

# Delad env-resolver: SCRIPT_DIR, REPO_ROOT, .env, VPS_HOST, VPS_USER, APP_DIR, SSH
# (samma logik som förr inline här — nu delad med feedback-sync.sh/feedback-report.sh, RM254).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_env.sh"

REMOTE_APP_DIR="/opt/hosting/apps/fishing"
IMAGE="jlsk-fishing"

if [ ! -f "$APP_DIR/deploy/Dockerfile" ]; then
    echo "FEL: hittar inte $APP_DIR/deploy/Dockerfile — sätt APP_DIR till jlsk-fishing-katalogen." >&2
    exit 1
fi

# Rollback = explicit tagg-argument (deployar en redan laddad image); då gäller inte tag-vakten.
ROLLBACK=0; [[ -n "${1:-}" ]] && ROLLBACK=1
# Tagg: argument, annars app-repots git-beskrivning, annars 'latest'.
TAG="${1:-$(git -C "$APP_DIR" describe --always --dirty --tags 2>/dev/null || echo latest)}"
# Versionen imagen SKA vara (ur plugin-headern) — används av tag-vakten + post-deploy-asserten.
EXPECTED_VERSION="$(grep -m1 "define( *'JF_VERSION'" "$APP_DIR/jlsk-fishing.php" | sed "s/.*'JF_VERSION', *'//;s/'.*//")"
RELEASE_TAG="jlsk-fishing-v$EXPECTED_VERSION"

# --- Tag-matchvakt (RM240): bygg bara det som release-taggen pekar på ---
# Imagen byggs ur APP_DIR:s ARBETSTRÄD (Dockerfile bygger frontend ur källan). Deployar vi medan
# trädet inte matchar release-taggen skeppar vi fel kod under rätt versionsnummer — precis det
# glapp v1.13.0-röran handlade om. Kräv ett rent träd som är identiskt med taggen. Rollback
# (explicit tagg-arg) hoppar över; nödutgång SKIP_TAG_CHECK=1.
if [[ "$ROLLBACK" == "0" && "${SKIP_TAG_CHECK:-}" != "1" ]]; then
    if ! git -C "$APP_DIR" diff --quiet || ! git -C "$APP_DIR" diff --cached --quiet; then
        echo "FEL: $APP_DIR har ocommittade ändringar — deploya från ett rent träd." >&2
        exit 1
    fi
    if ! git -C "$APP_DIR" rev-parse -q --verify "refs/tags/$RELEASE_TAG" >/dev/null; then
        echo "FEL: release-taggen $RELEASE_TAG finns inte lokalt (git fetch --tags, eller kör release-finish.sh)." >&2
        exit 1
    fi
    if ! git -C "$APP_DIR" diff --quiet "$RELEASE_TAG" HEAD -- .; then
        echo "FEL: arbetsträdet skiljer sig från $RELEASE_TAG — checka ut taggen först: git -C $APP_DIR checkout $RELEASE_TAG" >&2
        exit 1
    fi
    echo "==> Tag-matchvakt OK: träd == $RELEASE_TAG"
fi

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

# --- Egress-koll (jlsk RM235) ---------------------------------------------------------------
# Väder-autofyllet (jlsk RM99/RM226) är best-effort i två lager och sväljer ALLA fel —
# blockerad utgående HTTPS syns aldrig i drift, vädret förblir bara tomt. Verifiera därför
# vid varje deploy att containern når båda väderkällorna, via exakt samma väg som appen
# (php ext-curl, samma container, samma nät — imagen saknar curl-CLI). Bara transportfel
# (DNS/TLS/brandvägg/timeout) fäller; HTTP-status ignoreras (4xx/5xx = värden är nåbar).
# Komplett utgående inventarium: jlsk-fishing/docs/DEPLOYMENT_PLAN.md §4.6.
echo "==> Egress-koll (RM235): verifierar utgående HTTPS till väderkällorna"
if $SSH "docker exec -i fishing php" <<'PHP'
<?php
$urls = [
    'https://opendata-download-metfcst.smhi.se/api/category/pmp3g/version/2/',
    'https://api.open-meteo.com/v1/forecast?latitude=63&longitude=14',
];
foreach ($urls as $url) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_NOBODY => true,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT => 10,
    ]);
    curl_exec($ch);
    if (curl_errno($ch) !== 0) {
        fwrite(STDERR, "EGRESS BLOCKERAD: {$url} — " . curl_error($ch) . "\n");
        exit(1);
    }
}
echo "    egress OK: båda väderkällorna nåbara\n";
PHP
then
    :
else
    echo "FEL: utgående HTTPS från fishing-containern når inte väderkällorna —" >&2
    echo "     väder-autofyllet (jlsk RM99) är då TYST trasigt i drift." >&2
    echo "     Kontrollera VPS:ens brandvägg: utgående 443 måste vara öppen från containern." >&2
    echo "     Allowlista inte per IP — SMHI/Open-Meteo roterar adresser." >&2
    exit 1
fi

# --- Post-deploy: verifiera att rätt version faktiskt kör (RM240) ---
# Traefik startar om ovan; vänta in att API:et svarar med den förväntade x-jf-version innan vi
# säger "klart". Fångar en tyst deploy som inte slog igenom (fel image/cache). Rollback + explicit
# SKIP_VERSION_ASSERT=1 hoppar över; JF_LIVE_URL overridar värden.
if [[ "$ROLLBACK" == "0" && "${SKIP_VERSION_ASSERT:-}" != "1" ]]; then
    echo "==> Verifierar driftsatt version (x-jf-version == $EXPECTED_VERSION)"
    LIVE_URL="${JF_LIVE_URL:-https://fiske.ostersundarn.se}/jf/v1/seasons/active"
    live_ver=""
    for _ in 1 2 3 4 5 6; do
        live_ver="$(curl -fsS -m 10 -D - -o /dev/null "$LIVE_URL" 2>/dev/null \
            | tr -d '\r' | awk -F': ' 'tolower($1)=="x-jf-version"{print $2}')"
        [[ "$live_ver" == "$EXPECTED_VERSION" ]] && break
        sleep 5
    done
    if [[ "$live_ver" != "$EXPECTED_VERSION" ]]; then
        echo "FEL: live x-jf-version='$live_ver', förväntade '$EXPECTED_VERSION' — deployen slog inte igenom." >&2
        exit 1
    fi
    echo "  Live-version OK: $live_ver"
fi

# Feedback-genomgång (jlsk RM125, beslut: alt 2 — status underhålls manuellt server-side).
# Öppen-driftfallet har shell, så feedbacken surfas vid VARJE deploy i stället för att glömmas:
# ett daterat arkiv skrivs till uploads (durabelt, överlever container-bytet), och listan
# skrivs ut för åtgärd. Åtgärdade poster raderas manuellt: `docker exec fishing php
# /app/bin/feedback.php delete <id> --yes`. `|| true` — feedback får aldrig fälla en deploy.
echo "==> Feedback (RM125): arkiverar + listar öppna poster för genomgång"
$SSH "docker exec fishing php /app/bin/feedback.php export all /data/uploads/feedback-arkiv/\$(date +%F) || true"
$SSH "docker exec fishing php /app/bin/feedback.php list || true"

# --- Feedback-synk ROADMAP ↔ drift (jlsk RM144/RM254) --------------------------------------
# Håller ROADMAP.md (git) och driftens jf_feedback i synk utan att någon behöver komma ihåg det:
# den delade kärnan feedback-sync.sh (1) applicerar köade statusövergångar (pending-status.jsonl)
# i driften och (2) re-exporterar manifestet av feedback-tillståndet tillbaka till git-arbetskopian.
# Vid deploy appliceras HELA kön (inkl. `done` — den här deployen skeppar fixen, så resolved_version
# blir rätt); vid lyckad apply töms kön lokalt. Operatören committar sedan det tömda kö +
# uppdaterade manifestet. Best-effort — synken får ALDRIG fälla en deploy.
# Design: jlsk-fishing/docs/FEEDBACK_ROADMAP_SYNC_PLAN.md (fas 5).
JF_QUEUE="$APP_DIR/feedback/pending-status.jsonl"

if "$SCRIPT_DIR/feedback-sync.sh" "$JF_QUEUE"; then
    if [ -s "$JF_QUEUE" ]; then
        : > "$JF_QUEUE"
        echo "    kön applicerad + tömd lokalt — COMMITTA den tömda $JF_QUEUE + manifestet"
    fi
else
    echo "    VARNING: feedback-synk misslyckades — kön behålls (idempotent, tas om vid nästa deploy)"
fi

echo "==> Klart. Deltagare: https://fiske.ostersundarn.se  ·  Admin: https://fiske.ostersundarn.se/admin/"
