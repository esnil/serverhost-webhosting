#!/usr/bin/env bash
# Sätter upp Traefik-filstruktur på VPS:en och startar containern.
# Körs som deploy-användaren (som är i docker-gruppen).
# Kräver att nätverk 'proxy' finns (kör 03-create-docker-networks.sh först).

set -euo pipefail

TRAEFIK_DIR="${1:-/opt/hosting/traefik}"
ACME_EMAIL="${2:-}"

info() { echo "[INFO]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && die "Kör som deploy-användaren, inte root."
docker network inspect proxy &>/dev/null || die "Nätverket 'proxy' saknas. Kör 03-create-docker-networks.sh först."

if [ -z "$ACME_EMAIL" ]; then
    read -rp "E-post för Let's Encrypt (ACME): " ACME_EMAIL
fi
[[ "$ACME_EMAIL" == *@* ]] || die "Ogiltig e-postadress: $ACME_EMAIL"

# --- Katalogstruktur ---
mkdir -p "$TRAEFIK_DIR/letsencrypt" "$TRAEFIK_DIR/dynamic"
touch "$TRAEFIK_DIR/letsencrypt/acme.json"
chmod 600 "$TRAEFIK_DIR/letsencrypt/acme.json"
info "Katalog skapad: $TRAEFIK_DIR"

# --- traefik.yaml ---
cat > "$TRAEFIK_DIR/traefik.yaml" <<EOF
api:
  dashboard: false

log:
  level: INFO

# Backends (t.ex. Node/nginx) har ofta kort keep-alive-timeout (5s för uptime-kuma).
# Traefiks default är 90s, vilket ger stale connections och 504/hang.
# 3s säkerställer att Traefik stänger idle connections först.
serversTransport:
  forwardingTimeouts:
    idleConnTimeout: 3s

providers:
  docker:
    exposedByDefault: false
  file:
    directory: /etc/traefik/dynamic
    watch: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${ACME_EMAIL}
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
EOF
info "traefik.yaml skapad."

# --- compose.yaml ---
cat > "$TRAEFIK_DIR/compose.yaml" <<'EOF'
services:
  traefik:
    image: traefik:v3
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik.yaml:/etc/traefik/traefik.yaml:ro"
      - "./dynamic:/etc/traefik/dynamic:ro"
      - "./letsencrypt:/letsencrypt"
    networks:
      - proxy

networks:
  proxy:
    external: true
EOF
info "compose.yaml skapad."

# --- Starta Traefik ---
docker compose -f "$TRAEFIK_DIR/compose.yaml" up -d
info "Traefik startad."

echo ""
echo "=========================================="
echo "  Traefik kör!"
echo "  Loggar: docker compose -f $TRAEFIK_DIR/compose.yaml logs -f"
echo "=========================================="
