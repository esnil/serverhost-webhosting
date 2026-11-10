#!/usr/bin/env bash
#
# health.sh — svara på frågan "kör CI-runnerna faktiskt?" (ci-runner + ci-runner-gate) i ETT kommando.
#
# "Servern är uppe" är inget bevis. Runnern kan vara offline medan VPS:en mår perfekt, och då
# KÖAR bus-analyzers pipeline tyst i stället för att bli röd — en körning som aldrig STARTAR är
# omöten, inte trasig.
#
# Själva kollarna bor i check.sh, som också körs av cron PÅ VPS:en och larmar via Uptime Kuma →
# Telegram. Här pipas den LOKALA check.sh över ssh, så en ändrad kontroll kan provas innan den
# deployas, och de två konsumenterna kan aldrig glida isär.
#
#   ./apps/ci-runner/health.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }

VPS_HOST="${VPS_HOST:-217.154.83.127}"
VPS_USER="${VPS_USER:-deploy}"

if ssh -o ConnectTimeout=15 "${VPS_USER}@${VPS_HOST}" 'bash -s' < "$SCRIPT_DIR/check.sh"; then
    echo ""; echo "Allt grönt."
else
    echo ""; echo "Något behöver tittas på — se apps/ci-runner/README.md § Felsökning."
    exit 1
fi
