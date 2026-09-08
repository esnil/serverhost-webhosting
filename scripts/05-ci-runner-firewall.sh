#!/usr/bin/env bash
#
# Nätverksisolerar CI-runnern (apps/ci-runner) från resten av VPS:en.
#
# VARFÖR: runnern kör godtycklig kod ur bus-analyzers CI på samma maskin som produktion
# (ostersundarn.se, fiske.ostersundarn.se, hello./uptime.vps.encab.se). Containern har varken
# docker-socket eller privilegier, så den kan inte styra dockerdaemonen — men utan de här
# reglerna kan den nå de andra Docker-nätverken (`proxy`, `status_monitoring`, default-bridgen)
# på IP, och värdens sshd. Reglerna stänger den vägen och lämnar internet öppet (runnern MÅSTE
# nå api.github.com, apt, npm, crates.io, PyPI och Playwrights nedladdningar).
#
# `172.30.0.0/24` är CI-nätverkets FASTA subnät, pinnat i apps/ci-runner/compose.yaml. Ändras det
# där måste det ändras här — därför är det pinnat.
#
# Reglerna lever i DOCKER-USER (container→container går genom FORWARD) plus en INPUT-regel för
# värdens ssh (container→värd är INPUT, inte FORWARD, och syns därför inte i DOCKER-USER).
# Publicerade portar behöver ingen egen regel: de DNAT:as till en container-IP i 172.16/12 och
# fastnar i regel 1.
#
# iptables-regler överlever inte en omstart, och `netfilter-persistent` finns inte på den här
# värden. Därför läggs de i en systemd-oneshot som är PartOf=docker.service: den kör vid boot,
# efter dockerd, och igen varje gång dockerd startas om.
#
# Körs som root PÅ VPS:EN:  sudo ./05-ci-runner-firewall.sh
set -euo pipefail

CI_SUBNET="${CI_SUBNET:-172.30.0.0/24}"
UNIT=/etc/systemd/system/ci-runner-firewall.service

[ "$(id -u)" -eq 0 ] || { echo "FEL: kör som root (sudo)." >&2; exit 1; }

cat > "$UNIT" <<UNITEOF
[Unit]
Description=Nätverksisolering för CI-runnern (serverhost-webhosting scripts/05)
Documentation=https://github.com/esnil/serverhost-webhosting apps/ci-runner/README.md
After=docker.service
Requires=docker.service
# Docker återskapar sina kedjor vid omstart; PartOf gör att reglerna läggs tillbaka då.
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Idempotent: -C testar, -I lägger till bara om regeln saknas.
ExecStart=/bin/sh -c 'iptables -C DOCKER-USER -s ${CI_SUBNET} -d 172.16.0.0/12 -j REJECT 2>/dev/null || iptables -I DOCKER-USER -s ${CI_SUBNET} -d 172.16.0.0/12 -j REJECT'
ExecStart=/bin/sh -c 'iptables -C DOCKER-USER -s ${CI_SUBNET} -d 10.0.0.0/8 -j REJECT 2>/dev/null || iptables -I DOCKER-USER -s ${CI_SUBNET} -d 10.0.0.0/8 -j REJECT'
ExecStart=/bin/sh -c 'iptables -C DOCKER-USER -s ${CI_SUBNET} -d 192.168.0.0/16 -j REJECT 2>/dev/null || iptables -I DOCKER-USER -s ${CI_SUBNET} -d 192.168.0.0/16 -j REJECT'
ExecStart=/bin/sh -c 'iptables -C INPUT -s ${CI_SUBNET} -p tcp --dport 22 -j REJECT 2>/dev/null || iptables -I INPUT -s ${CI_SUBNET} -p tcp --dport 22 -j REJECT'

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now ci-runner-firewall.service

echo ""
echo "[INFO]  Aktiva regler för $CI_SUBNET:"
iptables -S DOCKER-USER | grep -F "$CI_SUBNET" || echo "  (inga i DOCKER-USER — fel?)"
iptables -S INPUT       | grep -F "$CI_SUBNET" || echo "  (ingen i INPUT — fel?)"
echo ""
echo "[INFO]  Verifiera från runnern (ska ge timeout/refused på 1, svar på 2):"
echo "  docker exec ci-runner curl -m 5 -s -o /dev/null -w '%{http_code}\\n' http://172.18.0.1/"
echo "  docker exec ci-runner curl -m 5 -s -o /dev/null -w '%{http_code}\\n' https://api.github.com/"
