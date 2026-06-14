#!/usr/bin/env bash
# Körs som root på en ny Ubuntu Server VPS.
# Skapar deploy-användare, låser SSH och aktiverar brandvägg.

set -euo pipefail

DEPLOY_USER="${1:-deploy}"
SSH_PORT="${2:-22}"

info()  { echo "[INFO]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Kör som root: sudo bash $0"

# --- Deploy-användare ---
if id "$DEPLOY_USER" &>/dev/null; then
    info "Användare $DEPLOY_USER finns redan."
else
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
    info "Användare $DEPLOY_USER skapad."
fi

usermod -aG sudo "$DEPLOY_USER"
info "Lagt till $DEPLOY_USER i sudo-gruppen."

# --- SSH-nyckel ---
DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
SSH_DIR="$DEPLOY_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$DEPLOY_USER:$DEPLOY_USER" "$SSH_DIR"

if [ ! -f "$AUTH_KEYS" ]; then
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
    info "Skapade $AUTH_KEYS — lägg till din publika SSH-nyckel manuellt."
    echo ""
    echo "  cat ~/.ssh/id_ed25519.pub | ssh root@<VPS-IP> 'cat >> $AUTH_KEYS'"
    echo ""
else
    info "$AUTH_KEYS finns redan."
fi

# --- Härda SSH ---
SSHD_CONF="/etc/ssh/sshd_config"

cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"

set_sshd() {
    local key="$1" val="$2"
    if grep -qE "^#?${key}" "$SSHD_CONF"; then
        sed -i "s|^#\?${key}.*|${key} ${val}|" "$SSHD_CONF"
    else
        echo "${key} ${val}" >> "$SSHD_CONF"
    fi
}

set_sshd "Port"                   "$SSH_PORT"
set_sshd "PermitRootLogin"        "no"
set_sshd "PasswordAuthentication" "no"
set_sshd "PubkeyAuthentication"   "yes"
set_sshd "AuthorizedKeysFile"     ".ssh/authorized_keys"
set_sshd "X11Forwarding"          "no"
set_sshd "AllowAgentForwarding"   "no"
set_sshd "PermitEmptyPasswords"   "no"

info "SSH-konfiguration uppdaterad (port $SSH_PORT, inga lösenord, root nekad)."

# --- Brandvägg ---
if command -v ufw &>/dev/null; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT/tcp" comment "SSH"
    ufw allow 80/tcp  comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    ufw --force enable
    info "UFW aktiverad: port $SSH_PORT, 80, 443 öppna."
else
    info "ufw saknas — installera med: apt install ufw"
fi

# --- Uppdatera servern ---
info "Uppdaterar paket..."
apt-get update -q
apt-get upgrade -y -q
apt-get autoremove -y -q

# --- Starta om SSH ---
info "Startar om SSH..."
systemctl restart sshd

echo ""
echo "=========================================="
echo "  Klar!"
echo "  Verifiera SSH-åtkomst för $DEPLOY_USER"
echo "  INNAN du stänger denna session."
echo "=========================================="
