#!/usr/bin/env bash
# Körs som root på Ubuntu Server.
# Installerar Docker Engine, Compose-plugin och sätter loggrotation.

set -euo pipefail

DEPLOY_USER="${1:-deploy}"

info() { echo "[INFO]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Kör som root: sudo bash $0"
id "$DEPLOY_USER" &>/dev/null || die "Användaren $DEPLOY_USER finns inte. Kör 01-create-deploy-user.sh först."

# --- Docker Engine (officiell metod) ---
if command -v docker &>/dev/null; then
    info "Docker är redan installerat: $(docker --version)"
else
    info "Installerar Docker Engine..."

    apt-get update -q
    apt-get install -y -q ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    info "Docker installerat: $(docker --version)"
fi

# --- Deploy-användare i docker-gruppen ---
if groups "$DEPLOY_USER" | grep -q docker; then
    info "$DEPLOY_USER är redan i docker-gruppen."
else
    usermod -aG docker "$DEPLOY_USER"
    info "Lagt till $DEPLOY_USER i docker-gruppen (gäller vid nästa inloggning)."
fi

# --- Loggrotation ---
DAEMON_CONF="/etc/docker/daemon.json"

if [ -f "$DAEMON_CONF" ]; then
    info "$DAEMON_CONF finns redan — kontrollera loggrotation manuellt."
else
    cat > "$DAEMON_CONF" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    info "Loggrotation satt (10 MB × 3 filer per container)."
fi

# --- Starta och aktivera Docker ---
systemctl enable --now docker
info "Docker-tjänst aktiverad och igång."

# --- Verifiera ---
docker run --rm hello-world | grep -q "Hello from Docker" && info "Docker fungerar korrekt." || die "Docker-test misslyckades."

echo ""
echo "=========================================="
echo "  Docker klart!"
echo "  Kör: newgrp docker  (eller logga ut/in)"
echo "  för att $DEPLOY_USER ska kunna köra docker utan sudo."
echo "=========================================="
