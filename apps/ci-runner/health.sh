#!/usr/bin/env bash
#
# health.sh — svara på frågan "kör CI-runnern faktiskt?" i ETT kommando.
#
# "Servern är uppe" är inget bevis. Runnern kan vara offline medan VPS:en mår perfekt, och då
# KÖAR bus-analyzers pipeline tyst i stället för att bli röd — en körning som aldrig STARTAR är
# omöten, inte trasig. Tre lager kollas, i tur och ordning, därför att var och en fallerar för
# sig: containern (docker), agenten (loggen), och GitHubs egen bild av flottan (API:et).
#
#   ./apps/ci-runner/health.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }

VPS_HOST="${VPS_HOST:-217.154.83.127}"
VPS_USER="${VPS_USER:-deploy}"
GH_REPO="${GH_REPO:-esnil/bus-analyzer}"
SSH="ssh ${VPS_USER}@${VPS_HOST}"
REMOTE_DIR="/opt/hosting/apps/ci-runner"

ok=0

echo "── 1. Container ─────────────────────────────────────────────"
status="$($SSH "docker ps -a --filter name=ci-runner --format '{{.Status}}  ({{.Image}})'" || true)"
if [ -z "$status" ]; then
    echo "  SAKNAS — ingen container ci-runner. Kör ./apps/ci-runner/deploy.sh"
    ok=1
elif [[ "$status" == Up* ]]; then
    echo "  $status"
else
    echo "  $status  ← inte Up. Se 'docker logs ci-runner'."
    ok=1
fi

echo "── 2. Agenten (loggen) ──────────────────────────────────────"
if $SSH "docker logs ci-runner 2>&1 | grep -q 'Listening for Jobs'"; then
    echo "  Registrerad och lyssnar efter jobb."
else
    echo "  'Listening for Jobs' saknas i loggen — kör inte / mitt i ett jobb. Senaste rader:"
    $SSH "docker logs --tail 5 ci-runner 2>&1" | sed 's/^/    /'
    ok=1
fi

echo "── 3. GitHubs bild av flottan ───────────────────────────────"
# PAT:en läses ur .env PÅ SERVERN, inte härifrån: då fungerar skriptet från vilken maskin som
# helst som får ssh:a in, och PAT:en behöver inte finnas lokalt. Bara curl körs där borta —
# formateringen sker lokalt, så inget python-skript behöver överleva två lager skalcitering.
runners_json="$($SSH "set -a; . '$REMOTE_DIR/.env'; set +a; \
    curl -fsS -H \"Authorization: Bearer \$GH_PAT\" -H 'Accept: application/vnd.github+json' \
    'https://api.github.com/repos/${GH_REPO}/actions/runners'" 2>/dev/null)" || runners_json=""

if [ -z "$runners_json" ]; then
    echo "  KUNDE INTE FRÅGA GITHUB (PAT utgången/återkallad, eller .env saknas på servern?)"
    ok=1
else
    printf '%s' "$runners_json" | python3 -c '
import json, sys
rs = json.load(sys.stdin).get("runners", [])
if not rs:
    print("  (inga runners alls registrerade i repot)")
for r in rs:
    labels = ",".join(l["name"] for l in r.get("labels", []) if l.get("type") == "custom")
    here = " <- den här VPS:en" if r["name"].startswith("vps-") else ""
    print("  {:<26} {:<8} busy={:<5} [{}]{}".format(
        r["name"], r["status"], str(r["busy"]).lower(), labels, here))
'
    printf '%s' "$runners_json" | grep -q '"name": *"vps-' \
        || { echo "  VPS-runnern saknas i GitHubs lista."; ok=1; }
fi

echo ""
[ "$ok" = "0" ] && echo "Allt grönt." || echo "Något behöver tittas på — se apps/ci-runner/README.md § Felsökning."
exit "$ok"
