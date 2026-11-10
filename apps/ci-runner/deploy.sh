#!/usr/bin/env bash
#
# deploy.sh — bygg och driftsätt bus-analyzers self-hosted GitHub Actions-runners på VPS:en:
# den fulla (`ci-runner`, target `full`) och den lilla prose-runnern (`ci-runner-gate`, target
# `gate`, bus-analyzer RM924). Samma build-kontext, två targets ur samma Dockerfile.
#
# Flöde: pipa build-kontexten (Dockerfile + entrypoint.sh ur ../bus-analyzer/docker/runner/)
# över SSH → `docker build` PÅ VPS:en → scp compose.yaml + .env → docker compose up -d →
# vänta tills runnerna säger "Listening for Jobs".
#
# Varför bygga på VPS:en och inte pusha en image: imagen är ~5,4 GB och laddar i praktiken bara
# ner saker (apt, Node, Rust, Playwright Chromium). VPS:ens datacenterlänk gör det snabbare än
# att skeppa 4 GB hemifrån, och privat GHCR-lagring på gratisplanen räcker ändå inte.
# Build-KONTEXTEN är två filer på några kB — det är bara den som går över länken.
#
# Varför inte upstreams `docker build <url-med-PAT>`: den formen lägger PAT:en i en URL som
# syns i skalhistorik och i `ps` på VPS:en. Kontexten över stdin behöver ingen kredential alls.
#
# INGET `docker restart traefik` här. Repots regel gäller appar bakom Traefik; runnern har
# varken labels, portar eller `proxy`-nätverk — Traefik vet inte att den finns.
#
# Användning (från serverhost-webhosting/):
#   cp apps/ci-runner/.env.example apps/ci-runner/.env   # fyll i GH_PAT
#   ./apps/ci-runner/deploy.sh              # bygg båda imagen + driftsätt båda runnerna
#   ./apps/ci-runner/deploy.sh --gate       # bygg + starta BARA prose-runnern; rör inte ci-runner
#   ./apps/ci-runner/deploy.sh <tagg>       # rollback av den fulla: kör en redan byggd tagg, bygg inget
#   ./apps/ci-runner/deploy.sh --no-build   # driftsätt om nuvarande :local (t.ex. efter env-ändring)
#
# `--gate` finns därför att `up -d` återskapar ci-runner om dess env eller image ändrats, och det
# dödar ett pågående jobb. Den fulla runnern driftsätts om när den är idle; den lilla när som helst.
#
# Konfiguration (env eller apps/ci-runner/.env):
#   VPS_HOST=217.154.83.127   VPS_USER=deploy   BA_DIR=<repo>/../bus-analyzer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi

VPS_HOST="${VPS_HOST:-217.154.83.127}"
VPS_USER="${VPS_USER:-deploy}"
BA_DIR="${BA_DIR:-$REPO_ROOT/../bus-analyzer}"
# ServerAlive* är inte kosmetika: utan dem hänger klienten för evigt om SSH-strömmen dör mitt i
# ett långt bygge (mätt 2026-09-08 — bygget blev klart på VPS:en medan det lokala kommandot
# aldrig återvände). Med keepalive dör kommandot i stället med ett fel man kan agera på.
SSH_OPTS=(-o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ConnectTimeout=15)
SSH="ssh ${SSH_OPTS[*]} ${VPS_USER}@${VPS_HOST}"
REMOTE_DIR="/opt/hosting/apps/ci-runner"
IMAGE="bus-analyzer-runner"
GATE_IMAGE="bus-analyzer-runner-gate"
RUNNER_SRC="$BA_DIR/docker/runner"

die() { echo "FEL: $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }

# --- Argument -------------------------------------------------------------------------------
BUILD=1
TAG=""
GATE_ONLY=0
case "${1:-}" in
    --no-build) BUILD=0 ;;
    --gate)     GATE_ONLY=1 ;;
    "")         ;;
    -*)         die "okänd flagga: $1" ;;
    *)          BUILD=0; TAG="$1" ;;   # explicit tagg = rollback, bygg inget
esac

# --- Förutsättningar ------------------------------------------------------------------------
[ -f "$SCRIPT_DIR/.env" ] || die "$SCRIPT_DIR/.env saknas — kopiera .env.example och fyll i GH_PAT."
grep -q '^GH_PAT=g' "$SCRIPT_DIR/.env" || die "GH_PAT ser inte ifylld ut i $SCRIPT_DIR/.env."

if [ "$BUILD" = "1" ]; then
    [ -f "$RUNNER_SRC/Dockerfile" ] \
        || die "hittar inte $RUNNER_SRC/Dockerfile — sätt BA_DIR till bus-analyzer-katalogen."
    [ -f "$RUNNER_SRC/entrypoint.sh" ] || die "hittar inte $RUNNER_SRC/entrypoint.sh."
    grep -qE '^FROM .* AS gate$' "$RUNNER_SRC/Dockerfile" \
        || die "$RUNNER_SRC/Dockerfile saknar target 'gate' (bus-analyzer RM924) — fel commit i BA_DIR?"
    # Taggen bär bus-analyzers commit — utan den går det inte att svara på "vilken image kör vi?"
    # om en månad. `:local` pekar alltid på den senast byggda; datum+sha finns kvar för rollback.
    BA_SHA="$(git -C "$BA_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
    git -C "$BA_DIR" diff --quiet -- docker/runner 2>/dev/null || BA_SHA="${BA_SHA}-dirty"
    TAG="$(date +%Y%m%d)-${BA_SHA}"
fi

# --- Filer på plats -------------------------------------------------------------------------
info "Förbereder $REMOTE_DIR på $VPS_HOST"
$SSH "mkdir -p '$REMOTE_DIR'"
scp -q "${SSH_OPTS[@]}" "$SCRIPT_DIR/compose.yaml" "${VPS_USER}@${VPS_HOST}:$REMOTE_DIR/compose.yaml"
scp -q "${SSH_OPTS[@]}" "$SCRIPT_DIR/.env" "${VPS_USER}@${VPS_HOST}:$REMOTE_DIR/.env"
$SSH "chmod 600 '$REMOTE_DIR/.env'"
# Övervakningen (check.sh via cron → Uptime Kuma → Telegram). Crontab-raden skrivs om idempotent,
# så en ändrad rad här slår igenom vid nästa deploy. Push-URL:erna (monitor.env) lämnas orörda:
# de finns bara på servern.
scp -q "${SSH_OPTS[@]}" "$SCRIPT_DIR/check.sh" "${VPS_USER}@${VPS_HOST}:$REMOTE_DIR/check.sh"
$SSH "chmod 755 '$REMOTE_DIR/check.sh' && { crontab -l 2>/dev/null | grep -v 'ci-runner/check.sh'; \
      echo '*/5 * * * * $REMOTE_DIR/check.sh --push > $REMOTE_DIR/check.last 2>&1'; } | crontab -"

# --- Bygg på VPS:en -------------------------------------------------------------------------
if [ "$BUILD" = "1" ]; then
    # Kontexten skickas och byggs i TVÅ steg, inte som `tar | ssh 'docker build -'`. Med en enda
    # pipe delar överföringen och byggloggen samma SSH-kanal, och stannar strömmen går det inte
    # att skilja "bygget hänger" från "kopplingen dog" — mätt 2026-09-08: bygget blev klart på
    # VPS:en (imagen taggad) medan det lokala kommandot hängde kvar utan utdata.
    info "Skickar build-kontexten (två filer)"
    # Bara de två filerna: .env i samma katalog får ALDRIG följa med in i en build-kontext.
    tar -C "$RUNNER_SRC" -czf - Dockerfile entrypoint.sh \
        | $SSH "cat > '$REMOTE_DIR/context.tar.gz'"

    # gate först: full är byggd FROM gate, så full-bygget återanvänder dess lager.
    info "Bygger $GATE_IMAGE:$TAG (target gate) på VPS:en"
    $SSH "docker build --target gate -t '$GATE_IMAGE:$TAG' -t '$GATE_IMAGE:local' - \
          < '$REMOTE_DIR/context.tar.gz'"
    if [ "$GATE_ONLY" = "0" ]; then
        info "Bygger $IMAGE:$TAG (target full) på VPS:en (första bygget tar några minuter)"
        $SSH "docker build --target full -t '$IMAGE:$TAG' -t '$IMAGE:local' - \
              < '$REMOTE_DIR/context.tar.gz'"
    fi
    $SSH "rm -f '$REMOTE_DIR/context.tar.gz'"
else
    if [ -n "$TAG" ]; then
        info "Rollback: bygger inget, kör befintlig tagg $IMAGE:$TAG"
        $SSH "docker image inspect '$IMAGE:$TAG' >/dev/null 2>&1" \
            || die "$IMAGE:$TAG finns inte på VPS:en. Tillgängliga taggar: $($SSH "docker images '$IMAGE' --format '{{.Tag}}'" | tr '\n' ' ')"
    else
        info "--no-build: startar om på nuvarande $IMAGE:local (t.ex. efter .env-ändring)"
    fi
fi

# --- Starta ---------------------------------------------------------------------------------
if [ "$GATE_ONLY" = "1" ]; then
    CONTAINERS="ci-runner-gate"
    info "Startar bara prose-runnern med $GATE_IMAGE:local (ci-runner lämnas orörd)"
    # --no-deps + ett namngivet service: compose rör inte ci-runner ens om dess env har ändrats.
    $SSH "cd '$REMOTE_DIR' && docker compose up -d --no-deps gate-runner"
else
    CONTAINERS="ci-runner ci-runner-gate"
    RUN_TAG="${TAG:-local}"
    info "Startar runnerna med $IMAGE:$RUN_TAG och $GATE_IMAGE:local"
    $SSH "cd '$REMOTE_DIR' && RUNNER_IMAGE_TAG='$RUN_TAG' docker compose up -d --remove-orphans"
fi
# Bara dinglande lager — ALDRIG `-a`, som skulle äta andra appars vilande images.
$SSH "docker image prune -f >/dev/null"

# --- Verifiera ------------------------------------------------------------------------------
info "Väntar på registrering hos GitHub…"
# EN ssh-session som pollar på servern, inte 30 uppkopplingar på 90 s: en pollande loop över SSH
# hinner slå i sshd:s MaxStartups och gör felbilden svårläst just när man behöver den.
failed=""
for c in $CONTAINERS; do
    if $SSH "for i in \$(seq 1 30); do
                 docker logs $c 2>&1 | grep -q 'Listening for Jobs' && exit 0
                 sleep 3
             done
             exit 1"; then
        info "$c är registrerad."
    else
        failed="$failed $c"
    fi
done
$SSH "docker ps --filter name=ci-runner --format '  {{.Names}}  {{.Image}}  {{.Status}}'"
[ -z "$failed" ] && exit 0

for c in $failed; do
    echo "" >&2
    echo "VARNING: 'Listening for Jobs' dök inte upp inom 90 s för $c. Senaste loggrader:" >&2
    $SSH "docker logs --tail 30 $c" >&2
done
echo "" >&2
echo "Se felsökningsavsnittet i apps/ci-runner/README.md." >&2
exit 1
